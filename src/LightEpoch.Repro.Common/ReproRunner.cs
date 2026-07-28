// CLI, core selection and pair orchestration for the LightEpoch repro.
//
// Each pair runs a reader and a reclaimer on two distinct physical cores. The
// reader publishes its epoch and then loads a shared page pointer; the reclaimer
// unlinks that pointer and then asks the real LightEpoch implementation to retire
// the page. If both loads miss the other core's store, LightEpoch frees a page
// while the protected reader is dereferencing it. Litmus makes that observable by
// unmapping (a hardware access violation, used on ARM64) and QuarantineLitmus by
// poisoning (a logical check, required on x86-64).

using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using LightEpoch.Core;

namespace LightEpoch.Repro.Common
{
    public interface IReproPattern
    {
        public string Name { get; }
        public string EpochSequence { get; }

        public void Enter<TOps>(ref TOps ops) where TOps : struct, IEpochOps;
    }

    /// <summary>
    /// Minimal LightEpoch usage: acquire protection immediately before the
    /// shared access and release it immediately afterward.
    /// </summary>
    public readonly struct BareReproPattern : IReproPattern
    {
        public string Name => "bare LightEpoch";
        public string EpochSequence => "Resume() -> access -> Suspend()";

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Enter<TOps>(ref TOps ops) where TOps : struct, IEpochOps => ops.Resume();
    }

    /// <summary>
    /// Resume-then-Refresh epoch sequence, mirroring a normal Tsavorite BasicContext operation.
    /// ClientSession.UnsafeResumeThread calls Resume and then InternalRefresh;
    /// InternalRefresh begins with ProtectAndDrain, represented by Refresh here.
    /// </summary>
    public readonly struct ResumeAndRefreshReproPattern : IReproPattern
    {
        public string Name => "Resume + Refresh";
        public string EpochSequence => "Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()";

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Enter<TOps>(ref TOps ops) where TOps : struct, IEpochOps
        {
            ops.Resume();
            ops.Refresh();
        }
    }

    public static class ReproRunner
    {
        public static int Run(string[] args)
        {
            string pattern = "bare";
            var forwarded = new List<string>(args.Length);
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] != "--pattern")
                {
                    forwarded.Add(args[i]);
                    continue;
                }

                if (i + 1 >= args.Length)
                    return MissingValue("--pattern");

                pattern = args[++i].ToLowerInvariant();
            }

            return pattern switch
            {
                "bare" => Guarded(() => Run<BareReproPattern>(forwarded.ToArray())),
                "resume-and-refresh" => Guarded(() => Run<ResumeAndRefreshReproPattern>(forwarded.ToArray())),
                _ => UnknownPattern(pattern),
            };
        }

        // An unhandled exception exits with 0xE0434352, and in unmap mode any nonzero
        // exit is the signal for "fault observed". A misused switch must not be
        // mistaken for a reproduction, so argument errors surface as exit code 2.
        private static int Guarded(Func<int> run)
        {
            try
            {
                return run();
            }
            catch (ArgumentException ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 2;
            }
        }

        private static int Run<TPattern>(string[] args)
            where TPattern : struct, IReproPattern
        {
            string impl = "baseline";
            long rounds = 200_000_000;
            int deref = 20_000;
            int readerCore = -1;
            int reclaimerCore = -1;
            int pairs = -1;
            int? seed = null;
            bool crossNuma = false;
            bool quarantine = false;
            bool selfTest = false;
            int reclaimerDelay = 0;
            bool jitter = false;
            int[] disturberCores = Array.Empty<int>();

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                switch (arg)
                {
                    case "--impl":
                        if (!TryRead(args, ref i, out impl))
                            return MissingValue(arg);
                        impl = impl.ToLowerInvariant();
                        break;
                    case "--rounds":
                        if (!TryReadLong(args, ref i, out rounds))
                            return InvalidValue(arg);
                        break;
                    case "--deref":
                        if (!TryReadInt(args, ref i, out deref))
                            return InvalidValue(arg);
                        break;
                    case "--reader-core":
                        if (!TryReadInt(args, ref i, out readerCore))
                            return InvalidValue(arg);
                        break;
                    case "--reclaimer-core":
                        if (!TryReadInt(args, ref i, out reclaimerCore))
                            return InvalidValue(arg);
                        break;
                    case "--pairs":
                        if (!TryReadInt(args, ref i, out pairs))
                            return InvalidValue(arg);
                        break;
                    case "--seed":
                        if (!TryReadInt(args, ref i, out int seedValue))
                            return InvalidValue(arg);
                        seed = seedValue;
                        break;
                    case "--cross-numa":
                        crossNuma = true;
                        break;
                    case "--quarantine":
                        quarantine = true;
                        break;
                    case "--reclaimer-delay":
                        if (!TryReadInt(args, ref i, out reclaimerDelay))
                            return InvalidValue(arg);
                        break;
                    case "--jitter":
                        jitter = true;
                        break;
                    case "--disturber-cores":
                        if (!TryRead(args, ref i, out string coreList))
                            return MissingValue(arg);
                        disturberCores = ParseCoreList(coreList);
                        if (disturberCores == null)
                            return InvalidValue(arg);
                        break;
                    case "--self-test":
                        quarantine = true;
                        selfTest = true;
                        break;
                    case "-h":
                    case "--help":
                        Usage<TPattern>();
                        return 0;
                    default:
                        Console.Error.WriteLine($"unknown argument '{arg}'");
                        Usage<TPattern>();
                        return 2;
                }
            }

            if (rounds <= 0 || deref <= 0)
            {
                Console.Error.WriteLine("rounds and deref must both be positive");
                return 2;
            }

            // Disturbers only widen the window on x86-64, where the store buffer commits
            // in order: holding the announce's line shared keeps that store, and every
            // store behind it, pending. ARM64 store buffers have no such ordering, so
            // the disturbers add coherence traffic without pinning the announce.
            if (disturberCores.Length > 0 && !quarantine)
                throw new ArgumentException("--disturber-cores requires --quarantine; it does nothing in unmap mode. See the ARM64 measurements in the README.");

            var physicalCores = CoreTopology.Enumerate();

            // Two concurrent pairs reproduce the race far more reliably than one:
            // a single pair can run for minutes on Neoverse-N1 without faulting.
            if (pairs < 0)
                pairs = physicalCores.Count >= 4 ? 2 : 1;

            if (pairs < 1)
            {
                Console.Error.WriteLine("--pairs must be >= 1");
                return 2;
            }

            var pattern = new TPattern();
            Console.WriteLine($"{pattern.Name} repro  impl={impl}  rounds={rounds:N0}  deref={deref}  pairs={pairs}  reclaimerDelay={reclaimerDelay}{(jitter ? " (jittered)" : string.Empty)}");
            Console.WriteLine($"epoch sequence: {pattern.EpochSequence}");
            Console.WriteLine($"OS={RuntimeInformation.OSDescription.Trim()}  Arch={RuntimeInformation.ProcessArchitecture}  {CoreTopology.Describe()}");
            Console.WriteLine(quarantine
                ? "detection: quarantine (page pool + poison sentinel; no syscall in the race loop)"
                : "detection: unmap (VirtualFree MEM_RELEASE; a fault is a hardware access violation)");
            Console.WriteLine("reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production");

            if (readerCore >= 0 || reclaimerCore >= 0)
            {
                if (readerCore < 0 || reclaimerCore < 0)
                {
                    Console.Error.WriteLine("--reader-core and --reclaimer-core must be given together");
                    return 2;
                }

                if (pairs != 1)
                {
                    Console.Error.WriteLine("--reader-core/--reclaimer-core apply only with --pairs 1");
                    return 2;
                }

                WarnIfSamePhysicalCore(physicalCores, reclaimerCore, readerCore);
                Console.WriteLine($"pair 0: cores(reclaimer={reclaimerCore},reader={readerCore})");
                return RunSingle<TPattern>(impl, rounds, deref, readerCore, reclaimerCore, quarantine, selfTest, reclaimerDelay, jitter, disturberCores);
            }

            int[] selected;
            try
            {
                selected = crossNuma
                    ? CoreTopology.SelectCrossNumaPairs(pairs, seed)
                    : CoreTopology.SelectDistinctPhysicalCores(2 * pairs, seed);
            }
            catch (InvalidOperationException ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 2;
            }

            Console.WriteLine($"core selection: one logical processor per physical core" + (crossNuma ? ", pairs straddle NUMA nodes" : string.Empty) + (seed.HasValue ? $" (shuffled, seed={seed.Value})" : " (in enumeration order)"));

            return RunPairs<TPattern>(impl, rounds, deref, pairs, selected, quarantine, selfTest, reclaimerDelay, jitter, disturberCores);
        }

        private static void WarnIfSamePhysicalCore(IReadOnlyList<CoreTopology.PhysicalCore> physicalCores, int reclaimerCore, int readerCore)
        {
            foreach (var core in physicalCores)
            {
                if (Array.IndexOf(core.LogicalProcessors, reclaimerCore) >= 0 &&
                    Array.IndexOf(core.LogicalProcessors, readerCore) >= 0)
                {
                    Console.Error.WriteLine($"WARNING: logical processors {reclaimerCore} and {readerCore} are SMT siblings of one physical core. They share a store buffer, so the Store-Buffer window this repro depends on cannot open and a non-fault proves nothing.");
                    return;
                }
            }
        }

        // Runs several independent Store-Buffer litmus pairs concurrently, one
        // reader+reclaimer per pair, each thread on its own physical core. In unmap
        // mode a real fault is an access violation that terminates the whole process;
        // in quarantine mode each pair returns its own verdict, so they are combined.
        private static int RunPairs<TPattern>(string impl, long rounds, int deref, int pairs, int[] cores, bool quarantine, bool selfTest, int reclaimerDelay, bool jitter, int[] disturberCores)
            where TPattern : struct, IReproPattern
        {
            var numaByLogicalProcessor = new Dictionary<int, int>();
            foreach (var core in CoreTopology.Enumerate())
            {
                foreach (int lp in core.LogicalProcessors)
                    numaByLogicalProcessor[lp] = core.NumaNode;
            }

            var threads = new Thread[pairs];
            var exitCodes = new int[pairs];
            for (int p = 0; p < pairs; p++)
            {
                int pairIndex = p;
                int reclaimerCore = cores[2 * p];
                int readerCore = cores[(2 * p) + 1];
                numaByLogicalProcessor.TryGetValue(reclaimerCore, out int reclaimerNode);
                numaByLogicalProcessor.TryGetValue(readerCore, out int readerNode);
                Console.WriteLine($"pair {p}: cores(reclaimer={reclaimerCore}[numa{reclaimerNode}],reader={readerCore}[numa{readerNode}])");
                var t = new Thread(() => exitCodes[pairIndex] = RunSingle<TPattern>(impl, rounds, deref, readerCore, reclaimerCore, quarantine, selfTest, reclaimerDelay, jitter, disturberCores))
                {
                    IsBackground = false,
                    Name = $"pair{p}"
                };
                threads[p] = t;
                t.Start();
            }

            foreach (var t in threads)
                t.Join();

            foreach (int code in exitCodes)
            {
                if (code != 0)
                    return code;
            }

            return 0;
        }

        private static int RunSingle<TPattern>(string impl, long rounds, int deref, int readerCore, int reclaimerCore, bool quarantine, bool selfTest, int reclaimerDelay, bool jitter, int[] disturberCores)
            where TPattern : struct, IReproPattern
        {
            if (quarantine)
            {
                return impl switch
                {
                    "baseline" => new QuarantineLitmus<BaselineOps, TPattern>(rounds, deref, readerCore, reclaimerCore, selfTest, reclaimerDelay, jitter, disturberCores).Run(),
                    "fullbarrier" => new QuarantineLitmus<FullBarrierOps, TPattern>(rounds, deref, readerCore, reclaimerCore, selfTest, reclaimerDelay, jitter, disturberCores).Run(),
                    _ => UnknownImplementation(impl),
                };
            }

            return impl switch
            {
                "baseline" => new Litmus<BaselineOps, TPattern>(rounds, deref, readerCore, reclaimerCore, reclaimerDelay, jitter).Run(),
                "fullbarrier" => new Litmus<FullBarrierOps, TPattern>(rounds, deref, readerCore, reclaimerCore, reclaimerDelay, jitter).Run(),
                _ => UnknownImplementation(impl),
            };
        }

        private static bool TryRead(string[] args, ref int index, out string value)
        {
            if (index + 1 >= args.Length)
            {
                value = null;
                return false;
            }

            value = args[++index];
            return true;
        }

        private static bool TryReadLong(string[] args, ref int index, out long value)
        {
            value = 0;
            return TryRead(args, ref index, out string text) && long.TryParse(text, out value);
        }

        private static int[] ParseCoreList(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
                return Array.Empty<int>();

            var parts = text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var result = new int[parts.Length];
            for (int i = 0; i < parts.Length; i++)
            {
                if (!int.TryParse(parts[i], out result[i]) || result[i] < 0)
                    return null;
            }

            return result;
        }

        private static bool TryReadInt(string[] args, ref int index, out int value)
        {
            value = 0;
            return TryRead(args, ref index, out string text) && int.TryParse(text, out value);
        }

        private static int MissingValue(string arg)
        {
            Console.Error.WriteLine($"missing value for '{arg}'");
            return 2;
        }

        private static int InvalidValue(string arg)
        {
            Console.Error.WriteLine($"invalid or missing numeric value for '{arg}'");
            return 2;
        }

        private static int UnknownImplementation(string impl)
        {
            Console.Error.WriteLine($"unknown --impl '{impl}' (want: baseline|fullbarrier)");
            return 2;
        }

        private static int UnknownPattern(string pattern)
        {
            Console.Error.WriteLine($"unknown --pattern '{pattern}' (want: bare|resume-and-refresh)");
            return 2;
        }

        private static void Usage<TPattern>() where TPattern : struct, IReproPattern
        {
            var pattern = new TPattern();
            Console.WriteLine(
                "usage: LightEpoch.Repro [--pattern <bare|resume-and-refresh>]\n" +
                "       --impl <baseline|fullbarrier>\n" +
                "       [--rounds N] [--deref N] [--pairs N] [--seed N] [--cross-numa]\n" +
                "       [--quarantine] [--self-test] [--reclaimer-delay N] [--jitter]\n" +
                "       [--disturber-cores a,b,...]\n" +
                "       [--reader-core N --reclaimer-core N]   (single pair, manual pinning)\n" +
                "--pattern selects the epoch sequence the reader runs per operation:\n" +
                "  bare              Resume() -> access -> Suspend()   (isolates the Acquire announce)\n" +
                "  resume-and-refresh  Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()\n" +
                "                    (the epoch portion of a Tsavorite BasicContext operation)\n" +
                $"selected: {pattern.Name} — {pattern.EpochSequence}\n" +
                "Each pair runs a reader and a reclaimer, one per physical core (SMT siblings are\n" +
                "never paired: they share a store buffer and the race window cannot open).\n" +
                "--pairs defaults to 2 when at least 4 physical cores are available.\n" +
                "--quarantine selects the x86 detection mode: a pooled page + poison sentinel\n" +
                "  instead of VirtualFree, so no TLB-shootdown IPI serializes the reader. The\n" +
                "  default unmap mode is the right one on ARM64, where the fault is a genuine\n" +
                "  access violation and no IPI is involved.\n" +
                "--self-test implies --quarantine and poisons every round, proving the detector\n" +
                "  can fire. It must report violations; if it does not, no clean --quarantine\n" +
                "  result means anything.\n" +
                "--reclaimer-delay spins the reclaimer that many iterations after the round\n" +
                "  barrier and before the unlink, aligning it with the reader's announce. The\n" +
                "  reader leaves the barrier and still has to run the slot-reservation CAS in\n" +
                "  Acquire(), so at delay 0 the unlink lands far too early and the window\n" +
                "  rarely opens. This shifts only the reclaimer's timing, never the epoch\n" +
                "  algorithm under test.\n" +
                "--jitter picks a fresh delay in [0,N] each round, sweeping the alignment space\n" +
                "  instead of betting on a single offset.\n" +
                "--disturber-cores <a,b,...> pins one thread per listed logical processor that\n" +
                "  does nothing but READ the epoch table. Reads cannot change an epoch decision;\n" +
                "  they keep the table's lines shared instead of exclusively owned by the\n" +
                "  announcing thread. Acquire() runs a CAS on threadId, which shares a cache\n" +
                "  line with localCurrentEpoch, so without disturbers that CAS leaves the line\n" +
                "  owned and the announce retires immediately, closing the window. Under\n" +
                "  disturbance the announce must win an RFO, and x86 store buffers commit in\n" +
                "  order, so it stays pending and the race becomes observable. That ordering\n" +
                "  argument is x86-only, so this requires --quarantine and is rejected in unmap\n" +
                "  mode.\n" +
                "The retiring thread always holds an epoch and refreshes it each round, the way\n" +
                "  Tsavorite drives the epoch in production; BumpCurrentEpoch asserts that.\n" +
                "exit 0 = survived; nonzero/aborted = fault observed.");
        }
    }
}
