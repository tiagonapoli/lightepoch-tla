using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading;
using LightEpoch.Core;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// Two-sided Store-Buffer litmus over one epoch instance, detecting the race by
    /// unmapping the reclaimed page so a use-after-free becomes a hardware access
    /// violation. This is the mode to use on ARM64; on x86-64 the unmap itself
    /// serializes the reader and hides the race, so use
    /// <see cref="QuarantineLitmus{TOps,TPattern}"/> there instead.
    ///
    /// The reader publishes its epoch and then loads the shared page pointer; the
    /// reclaimer unlinks that pointer and then asks the real LightEpoch implementation
    /// to retire the page. If both loads miss the other core's store, LightEpoch frees
    /// a page while the protected reader is dereferencing it.
    ///
    /// Both the epoch implementation and the operation pattern are structs, so the JIT
    /// specializes and devirtualizes their calls instead of adding synchronization to
    /// the race window being measured.
    /// </summary>
    internal sealed unsafe class Litmus<TOps, TPattern>
        where TOps : struct, IEpochOps
        where TPattern : struct, IReproPattern
    {
        private const nuint PageSize = 4096;

        private TOps ops;
        private TPattern pattern;
        private long curPage;
        private int startCount;
        private int startSense;
        private int endCount;
        private int endSense;
        private long sink;
        private volatile bool stop;

        private readonly long rounds;
        private readonly int deref;
        private readonly int readerCore;
        private readonly int reclaimerCore;

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
            WindowsNative.Pin(reclaimerCore);

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

        private void ReaderLoop()
        {
            WindowsNative.Pin(readerCore);

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
        private void ReadAndDeref()
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

        private void ReclaimerLoop()
        {
            for (long round = 0; round < rounds; round++)
            {
                byte* page = WindowsNative.Alloc(PageSize);
                for (int index = 0; index < 512; index++)
                    ((long*)page)[index] = index;
                Volatile.Write(ref curPage, (long)page);

                StartBarrier();

                curPage = 0;
                long pageAddress = (long)page;
                ops.BumpCurrentEpoch(() => WindowsNative.Free((byte*)pageAddress, PageSize));

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void StartBarrier()
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
        private void EndBarrier()
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
