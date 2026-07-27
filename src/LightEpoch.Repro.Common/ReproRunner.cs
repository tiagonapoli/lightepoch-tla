// Shared, self-judging Store-Buffer litmus used by the two repro executables.
//
// The reader first publishes its epoch and then loads a shared page pointer.
// The reclaimer first unlinks that pointer and then asks the real LightEpoch
// implementation to retire the page. If both loads miss the other core's store,
// LightEpoch unmaps a page while the protected reader is dereferencing it.

using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using Tsavorite.core;

namespace LightEpoch.Repro.Common
{
    public interface IReproPattern
    {
        string Name { get; }
        string EpochSequence { get; }

        void Enter<TOps>(ref TOps ops) where TOps : struct, IEpochOps;
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
        public void Enter<TOps>(ref TOps ops) where TOps : struct, IEpochOps
            => ops.Resume();
    }

    /// <summary>
    /// Epoch portion of Garnet's normal Tsavorite BasicContext operation.
    /// ClientSession.UnsafeResumeThread calls Resume and then InternalRefresh;
    /// InternalRefresh begins with ProtectAndDrain, represented by Refresh here.
    /// </summary>
    public readonly struct GarnetBasicContextReproPattern : IReproPattern
    {
        public string Name => "Garnet Tsavorite BasicContext";
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
        public static int Run<TPattern>(string[] args)
            where TPattern : struct, IReproPattern
        {
            string impl = "baseline";
            long rounds = 200_000_000;
            int deref = 20_000;
            int readerCore = 1;
            int reclaimerCore = 0;

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

            if (rounds <= 0 || deref < 0 || readerCore < 0 || reclaimerCore < 0)
            {
                Console.Error.WriteLine("rounds must be positive; deref and core IDs must be non-negative");
                return 2;
            }

            var pattern = new TPattern();
            Console.WriteLine($"{pattern.Name} repro  impl={impl}  rounds={rounds:N0}  deref={deref}");
            Console.WriteLine($"epoch sequence: {pattern.EpochSequence}");
            Console.WriteLine(
                $"OS={RuntimeInformation.OSDescription.Trim()}  " +
                $"Arch={RuntimeInformation.ProcessArchitecture}  " +
                $"cores(reclaimer={reclaimerCore},reader={readerCore})");

            return impl switch
            {
                "baseline" => new Litmus<BaselineOps, TPattern>(rounds, deref, readerCore, reclaimerCore).Run(),
                "fullbarrier" => new Litmus<FullBarrierOps, TPattern>(rounds, deref, readerCore, reclaimerCore).Run(),
                "interlocked" => new Litmus<InterlockedExchangeOps, TPattern>(rounds, deref, readerCore, reclaimerCore).Run(),
                "asymmetric" => new Litmus<AsymmetricOps, TPattern>(rounds, deref, readerCore, reclaimerCore).Run(),
                _ => UnknownImplementation(impl),
            };
        }

        static bool TryRead(string[] args, ref int index, out string value)
        {
            if (index + 1 >= args.Length)
            {
                value = null;
                return false;
            }

            value = args[++index];
            return true;
        }

        static bool TryReadLong(string[] args, ref int index, out long value)
        {
            value = 0;
            return TryRead(args, ref index, out string text) && long.TryParse(text, out value);
        }

        static bool TryReadInt(string[] args, ref int index, out int value)
        {
            value = 0;
            return TryRead(args, ref index, out string text) && int.TryParse(text, out value);
        }

        static int MissingValue(string arg)
        {
            Console.Error.WriteLine($"missing value for '{arg}'");
            return 2;
        }

        static int InvalidValue(string arg)
        {
            Console.Error.WriteLine($"invalid or missing numeric value for '{arg}'");
            return 2;
        }

        static int UnknownImplementation(string impl)
        {
            Console.Error.WriteLine(
                $"unknown --impl '{impl}' (want: baseline|fullbarrier|interlocked|asymmetric)");
            return 2;
        }

        static void Usage<TPattern>() where TPattern : struct, IReproPattern
        {
            var pattern = new TPattern();
            Console.WriteLine(
                $"usage: {pattern.Name} --impl <baseline|fullbarrier|interlocked|asymmetric> " +
                "[--rounds N] [--deref N] [--reader-core N] [--reclaimer-core N]\n" +
                $"epoch sequence: {pattern.EpochSequence}\n" +
                "exit 0 = survived; nonzero/aborted = fault observed.");
        }
    }

    /// <summary>
    /// Two-sided Store-Buffer litmus over one epoch instance. Both the epoch
    /// implementation and operation pattern are structs, so the JIT specializes
    /// and devirtualizes their calls instead of adding synchronization to the
    /// race window being measured.
    /// </summary>
    internal sealed unsafe class Litmus<TOps, TPattern>
        where TOps : struct, IEpochOps
        where TPattern : struct, IReproPattern
    {
        const nuint PageSize = 4096;

        TOps ops;
        TPattern pattern;
        long curPage;
        int startCount;
        int startSense;
        int endCount;
        int endSense;
        long sink;
        volatile bool stop;

        readonly long rounds;
        readonly int deref;
        readonly int readerCore;
        readonly int reclaimerCore;

        public Litmus(long rounds, int deref, int readerCore, int reclaimerCore)
        {
            this.rounds = rounds;
            this.deref = deref;
            this.readerCore = readerCore;
            this.reclaimerCore = reclaimerCore;
            ops = new TOps();
            pattern = new TPattern();
        }

        public int Run()
        {
            Console.WriteLine($"ops = {ops.Name}");

            var reader = new Thread(ReaderLoop)
            {
                IsBackground = true,
                Name = "reader",
                Priority = ThreadPriority.Highest
            };
            reader.Start();
            Plat.Pin(reclaimerCore);

            var stopwatch = Stopwatch.StartNew();
            ReclaimerLoop();
            stopwatch.Stop();

            stop = true;
            reader.Join(2000);
            Console.WriteLine(
                $"Completed {rounds:N0} rounds in {stopwatch.Elapsed.TotalSeconds:F1}s " +
                $"with NO fault. sink={Volatile.Read(ref sink)}");
            return 0;
        }

        void ReaderLoop()
        {
            Plat.Pin(readerCore);

            for (long round = 0; round < rounds && !stop; round++)
            {
                StartBarrier();

                pattern.Enter(ref ops);
                ReadAndDeref();
                ops.Suspend();

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void ReadAndDeref()
        {
            long pageAddress = curPage;
            if (pageAddress == 0)
                return;

            long* page = (long*)pageAddress;
            long accumulator = 0;
            for (int index = 0; index < deref; index++)
                accumulator += page[index & 511];
            sink += accumulator;
        }

        void ReclaimerLoop()
        {
            for (long round = 0; round < rounds; round++)
            {
                byte* page = Plat.Alloc(PageSize);
                for (int index = 0; index < 512; index++)
                    ((long*)page)[index] = index;
                Volatile.Write(ref curPage, (long)page);

                StartBarrier();

                curPage = 0;
                long pageAddress = (long)page;
                ops.BumpCurrentEpoch(() => Plat.Free((byte*)pageAddress, PageSize));

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void StartBarrier()
        {
            int sense = Volatile.Read(ref startSense);
            if (Interlocked.Increment(ref startCount) == 2)
            {
                startCount = 0;
                Volatile.Write(ref startSense, sense ^ 1);
                return;
            }

            var spinner = new SpinWait();
            while (Volatile.Read(ref startSense) == sense)
                spinner.SpinOnce(-1);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void EndBarrier()
        {
            int sense = Volatile.Read(ref endSense);
            if (Interlocked.Increment(ref endCount) == 2)
            {
                endCount = 0;
                Volatile.Write(ref endSense, sense ^ 1);
                return;
            }

            var spinner = new SpinWait();
            while (Volatile.Read(ref endSense) == sense)
                spinner.SpinOnce(-1);
        }
    }
}
