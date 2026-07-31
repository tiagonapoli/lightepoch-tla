using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using LightEpoch.Core;

namespace LightEpoch.TidLitmus
{
    /// <summary>
    /// Hardware answer to one question: after moving the slot-claim CAS off <c>Entry.threadId</c>
    /// and onto <c>Entry.localCurrentEpoch</c>, does <c>ThisInstanceProtected()</c> still tell the
    /// truth?
    ///
    /// <para>
    /// <c>threadId</c> is now derived state — a plain store trailing the claim rather than the
    /// claim itself — so the tag is written by the arriving owner while the departing owner's
    /// clear of the same field may still be in flight. Roughly 25 load-bearing Garnet call sites
    /// branch on the answer, and both directions of a wrong answer are expensive: a false negative
    /// at a suspend-around-blocking-wait site blocks while still announcing an epoch and pins
    /// <c>SafeToReclaimEpoch</c>, and at an acquire-if-needed site it double-acquires and orphans
    /// the first slot.
    /// </para>
    ///
    /// <para>
    /// The harness drives many threads around <c>Resume</c>/<c>Suspend</c> over a deliberately tiny
    /// slot table, so every slot is handed between cores continuously, and cross-checks the query
    /// against ground truth (the thread's own entry index and announced epoch, both thread-private
    /// and immune to the race). It is an A/B, not a single run: the <c>upstream</c> release order
    /// is the forced-failure control, and a run whose control stays silent is INCONCLUSIVE rather
    /// than PASS, because a detector that cannot fire proves nothing.
    /// </para>
    /// </summary>
    internal static unsafe class Program
    {
        private const int ExitPass = 0;
        private const int ExitViolation = 1;
        private const int ExitUsage = 2;
        private const int ExitInconclusive = 3;

        private static int Main(string[] args)
        {
            var cfg = new Config();
            if (!cfg.Parse(args, out var error))
            {
                if (error is not null)
                    Console.Error.WriteLine("error: " + error);
                Usage();
                return error is null ? ExitPass : ExitUsage;
            }

            Console.WriteLine("LightEpoch ThisInstanceProtected() torture harness");
            Console.WriteLine($"  implementation : {cfg.Impl}");
            Console.WriteLine($"  release order  : {FixedLightEpochWithCasAnnounce.ReleaseOrderName} (LE_RELEASE_ORDER)");
            Console.WriteLine($"  threads        : {cfg.Threads}");
            Console.WriteLine($"  slot space     : {cfg.Slots}");
            Console.WriteLine($"  duration       : {cfg.Seconds}s");
            Console.WriteLine($"  mode           : {(cfg.Idiom ? "production call-site idioms" : $"direct query, {cfg.Samples} samples/region")}");
            Console.WriteLine($"  expectation    : {(cfg.ExpectViolation ? "VIOLATION (forced-failure control)" : "clean")}");
            Console.WriteLine();

            var result = cfg.Impl switch
            {
                "baseline" => Run<BaselineOps>(cfg),
                "barrier" => Run<FullBarrierOps>(cfg),
                _ => Run<CasAnnounceOps>(cfg),
            };

            return Report(cfg, result);
        }

        private static void Usage()
        {
            Console.WriteLine("usage: LightEpoch.TidLitmus [options]");
            Console.WriteLine("  --impl <cas|baseline|barrier>  epoch implementation (default cas)");
            Console.WriteLine("  --threads <n>                  worker threads (default 2x processor count)");
            Console.WriteLine("  --slots <n>                    slot-table size forced via TestSlotSpace (default 2)");
            Console.WriteLine("  --seconds <n>                  wall-clock duration (default 30)");
            Console.WriteLine("  --samples <n>                  ThisInstanceProtected() samples per protected region (default 8)");
            Console.WriteLine("  --idiom                        exercise the two production call-site idioms instead");
            Console.WriteLine("  --expect-violation             control arm: exit PASS only if violations are seen");
            Console.WriteLine("  --json <path>                  write a machine-readable report");
            Console.WriteLine();
            Console.WriteLine("The release order is selected with the LE_RELEASE_ORDER environment variable");
            Console.WriteLine("(volatile | exchange | plain | upstream). 'upstream' is the forced-failure control.");
            Console.WriteLine();
            Console.WriteLine("exit codes: 0 pass, 1 violation, 2 usage, 3 inconclusive");
        }

        private sealed class Config
        {
            public string Impl = "cas";
            public int Threads = Math.Max(2, Environment.ProcessorCount * 2);
            public ushort Slots = 2;
            public int Seconds = 30;
            public int Samples = 8;
            public bool Idiom;
            public bool ExpectViolation;
            public string Json;

            public bool Parse(string[] args, out string error)
            {
                error = null;
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    string Next() => ++i < args.Length ? args[i] : null;
                    switch (a)
                    {
                        case "-h":
                        case "--help": return false;
                        case "--impl": Impl = Next(); break;
                        case "--threads": Threads = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--slots": Slots = ushort.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--seconds": Seconds = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--samples": Samples = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--idiom": Idiom = true; break;
                        case "--expect-violation": ExpectViolation = true; break;
                        case "--json": Json = Next(); break;
                        default: error = $"unrecognised argument '{a}'"; return false;
                    }
                }

                if (Impl is not ("cas" or "baseline" or "barrier")) { error = $"--impl '{Impl}' is not one of cas, baseline, barrier"; return false; }
                if (Threads < 2) { error = "--threads must be at least 2"; return false; }
                if (Slots < 1) { error = "--slots must be at least 1"; return false; }
                if (Seconds < 1) { error = "--seconds must be at least 1"; return false; }
                if (Samples < 1) { error = "--samples must be at least 1"; return false; }

                return true;
            }
        }

        private sealed class Result
        {
            public long Rounds;
            public long FalseNegatives;
            public long FalsePositives;
            public long LostOwnership;
            public double ElapsedSeconds;
            public string EpochName;
            public List<string> Samples = [];
        }

        /// <summary>
        /// One worker's counters, padded to its own cache line. The harness contends hard on a
        /// handful of epoch slots, so counters sharing a line with a neighbour's would add cache
        /// traffic on exactly the lines whose timing the test is trying to observe.
        /// </summary>
        private struct Counters
        {
            public long Rounds;
            public long FalseNegatives;
            public long FalsePositives;
            public long LostOwnership;
#pragma warning disable CS0169 // padding to a full cache line
            private long p0, p1, p2, p3;
#pragma warning restore CS0169
        }

        private static int Report(Config cfg, Result r)
        {
            long violations = r.FalseNegatives + r.FalsePositives + r.LostOwnership;

            Console.WriteLine();
            Console.WriteLine($"  rounds          : {r.Rounds:N0} in {r.ElapsedSeconds:F1}s ({r.Rounds / Math.Max(r.ElapsedSeconds, 0.001) / 1e6:F2} M/s)");
            Console.WriteLine($"  false negatives : {r.FalseNegatives:N0}   (owned the slot, query said 'not protected')");
            Console.WriteLine($"  false positives : {r.FalsePositives:N0}   (owned nothing, query said 'protected')");
            Console.WriteLine($"  lost ownership  : {r.LostOwnership:N0}   (Resume() returned without a slot or an epoch)");

            if (r.Samples.Count > 0)
            {
                Console.WriteLine();
                Console.WriteLine("  first violations:");
                foreach (var s in r.Samples)
                    Console.WriteLine("    " + s);
            }

            if (cfg.Json is not null)
                WriteJson(cfg, r, violations);

            Console.WriteLine();
            if (cfg.ExpectViolation)
            {
                if (violations == 0)
                {
                    Console.WriteLine("INCONCLUSIVE: the forced-failure control reported no violations, so the");
                    Console.WriteLine("detector is not known to be live and a clean run of the fix proves nothing.");
                    return ExitInconclusive;
                }

                Console.WriteLine($"PASS (control): the detector is live — {violations:N0} violations under the upstream release order.");
                return ExitPass;
            }

            if (violations != 0)
            {
                Console.WriteLine($"VIOLATION: ThisInstanceProtected() disagreed with ground truth {violations:N0} times.");
                return ExitViolation;
            }

            Console.WriteLine("PASS: ThisInstanceProtected() agreed with ground truth on every sample.");
            return ExitPass;
        }

        private static void WriteJson(Config cfg, Result r, long violations)
        {
            var sb = new StringBuilder();
            sb.Append("{\n");
            sb.Append($"  \"impl\": \"{cfg.Impl}\",\n");
            sb.Append($"  \"epoch\": \"{r.EpochName}\",\n");
            sb.Append($"  \"releaseOrder\": \"{FixedLightEpochWithCasAnnounce.ReleaseOrderName}\",\n");
            sb.Append($"  \"threads\": {cfg.Threads},\n");
            sb.Append($"  \"slots\": {cfg.Slots},\n");
            sb.Append($"  \"samplesPerRegion\": {cfg.Samples},\n");
            sb.Append($"  \"expectViolation\": {(cfg.ExpectViolation ? "true" : "false")},\n");
            sb.Append($"  \"elapsedSeconds\": {r.ElapsedSeconds.ToString("F3", CultureInfo.InvariantCulture)},\n");
            sb.Append($"  \"rounds\": {r.Rounds},\n");
            sb.Append($"  \"falseNegatives\": {r.FalseNegatives},\n");
            sb.Append($"  \"falsePositives\": {r.FalsePositives},\n");
            sb.Append($"  \"lostOwnership\": {r.LostOwnership},\n");
            sb.Append($"  \"violations\": {violations}\n");
            sb.Append("}\n");

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(cfg.Json)));
            File.WriteAllText(cfg.Json, sb.ToString());
            Console.WriteLine($"  report          : {cfg.Json}");
        }

        private static Result Run<TOps>(Config cfg) where TOps : struct, IEpochOps
        {
            var ops = new TOps();
            ops.SetTestSlotSpace(cfg.Slots);

            var counters = new Counters[cfg.Threads];
            var samples = new List<string>();
            var samplesLock = new object();
            var start = new ManualResetEventSlim(false);
            var stop = new int[1];
            var threads = new Thread[cfg.Threads];

            for (int t = 0; t < cfg.Threads; t++)
            {
                int id = t;
                threads[t] = new Thread(() =>
                {
                    start.Wait();
                    Worker(ops, cfg, id, counters, stop, samples, samplesLock);
                }, 512 * 1024)
                { IsBackground = true, Name = $"tid-litmus-{t}" };
                threads[t].Start();
            }

            var sw = Stopwatch.StartNew();
            start.Set();
            Thread.Sleep(cfg.Seconds * 1000);
            Volatile.Write(ref stop[0], 1);
            foreach (var th in threads)
                th.Join();
            sw.Stop();

            var r = new Result { ElapsedSeconds = sw.Elapsed.TotalSeconds, EpochName = ops.Name, Samples = samples };
            for (int t = 0; t < cfg.Threads; t++)
            {
                r.Rounds += counters[t].Rounds;
                r.FalseNegatives += counters[t].FalseNegatives;
                r.FalsePositives += counters[t].FalsePositives;
                r.LostOwnership += counters[t].LostOwnership;
            }

            return r;
        }

        private static void Worker<TOps>(TOps ops, Config cfg, int id, Counters[] counters, int[] stop, List<string> samples, object samplesLock)
            where TOps : struct, IEpochOps
        {
            ref var c = ref counters[id];
            int samplesPerRegion = cfg.Samples;

            while (Volatile.Read(ref stop[0]) == 0)
            {
                if (cfg.Idiom)
                {
                    Idioms(ops, id, ref c, samples, samplesLock);
                    c.Rounds++;
                    continue;
                }

                ops.Resume();

                // Ground truth. Both are thread-private: the entry index lives in this thread's
                // own metadata, and the announced epoch is read through it. Neither can be
                // clobbered by the departing owner's trailing threadId clear, which is precisely
                // what makes them a usable oracle for the query.
                int entry = ops.EntryIndex;
                long announced = ops.ThisThreadAnnouncedEpoch;
                bool owned = entry != 0 && announced != 0;

                if (!owned)
                    c.LostOwnership++;

                // Sample across the region rather than once. The losing interleaving leaves a
                // stale zero in threadId, and nothing rewrites the field until the slot changes
                // hands again, so a violation that lands after the first sample stays visible —
                // but the first sample can also be served out of this thread's own store buffer
                // and hide it.
                for (int k = 0; k < samplesPerRegion; k++)
                {
                    bool answer = ops.ThisInstanceProtected;
                    if (owned && !answer)
                    {
                        c.FalseNegatives++;
                        Record(samples, samplesLock, $"thread {id}: false negative at sample {k}, entry={entry}, announced={announced}");
                        break;
                    }

                    Thread.SpinWait(1 << k);
                }

                ops.Suspend();

                // After Suspend() this thread owns no slot, so the query must say so. The entry
                // index is reset last in Release(), which is what makes this direction structurally
                // safe; the check is here to keep that structural claim under test rather than
                // assumed.
                if (ops.ThisInstanceProtected)
                {
                    c.FalsePositives++;
                    Record(samples, samplesLock, $"thread {id}: false positive after Suspend(), entry={ops.EntryIndex}");
                }

                c.Rounds++;
            }
        }

        /// <summary>
        /// The two idioms the ~25 load-bearing Garnet call sites are written in, reproduced against
        /// the same query and scored by what each would actually cost in production rather than by
        /// whether the query returned the expected bit.
        /// </summary>
        private static void Idioms<TOps>(TOps ops, int id, ref Counters c, List<string> samples, object samplesLock)
            where TOps : struct, IEpochOps
        {
            // Idiom A: suspend around a blocking wait.
            //   StorageDeviceBase.cs:224-235, 295-306, 339-350; AllocatorBase.cs:355
            // A false negative here means the thread blocks on I/O while still announcing an
            // epoch, pinning SafeToReclaimEpoch for the duration of the wait.
            ops.Resume();
            bool isProtected = ops.ThisInstanceProtected;
            if (!isProtected)
            {
                c.FalseNegatives++;
                Record(samples, samplesLock, $"thread {id}: idiom A would block on I/O while announcing epoch {ops.ThisThreadAnnouncedEpoch} in slot {ops.EntryIndex}");
            }

            if (isProtected)
                ops.Suspend();

            Thread.SpinWait(64);      // stands in for the blocking wait

            if (ops.ThisInstanceProtected)
            {
                c.FalsePositives++;
                Record(samples, samplesLock, $"thread {id}: idiom A still reads as protected after Suspend()");
            }

            if (isProtected)
                ops.Resume();

            ops.Suspend();

            // Idiom B: acquire if not already held.
            //   AllocatorBase.cs:981, 1018, 2382; StorageDeviceBase.cs:261;
            //   ObjectAllocatorImpl.cs:652; LogAccessor.cs:131
            // A false negative here means ResumeIfNotProtected() acquires a second slot while the
            // first is still held, orphaning it to announce a stale epoch forever.
            ops.Resume();
            int held = ops.EntryIndex;
            if (!ops.ThisInstanceProtected)
            {
                c.FalseNegatives++;
                Record(samples, samplesLock, $"thread {id}: idiom B would double-acquire and orphan slot {held}");
            }

            ops.Suspend();
        }

        private static void Record(List<string> samples, object samplesLock, string message)
        {
            lock (samplesLock)
            {
                if (samples.Count < 16)
                    samples.Add(message);
            }
        }
    }
}
