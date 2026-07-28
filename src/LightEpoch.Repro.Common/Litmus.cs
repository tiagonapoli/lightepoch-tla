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
        private readonly int reclaimerDelay;
        private readonly bool jitter;
        private readonly int[] disturberCores;
        private ulong rngState = 0x9E3779B97F4A7C15;

        public Litmus(long rounds, int deref, int readerCore, int reclaimerCore, int reclaimerDelay = 0, bool jitter = false, int[] disturberCores = null)
        {
            this.rounds = rounds;
            this.deref = deref;
            this.readerCore = readerCore;
            this.reclaimerCore = reclaimerCore;
            this.reclaimerDelay = reclaimerDelay;
            this.jitter = jitter;
            this.disturberCores = disturberCores ?? Array.Empty<int>();
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

            // Disturber threads only read the epoch table, so they cannot influence any
            // epoch decision. Their job is to keep the table's cache lines shared rather
            // than exclusively owned by the announcing thread: Acquire() runs a CAS on
            // threadId, which shares a cache line with localCurrentEpoch, so without
            // disturbance that CAS leaves the line owned and the announce becomes
            // visible almost immediately, closing the window. Under disturbance the
            // announce must first win the line back, so it stays pending long enough for
            // the missing StoreLoad fence to be observable.
            // Pin these to distinct physical cores: SMT siblings share L1 and generate
            // no coherence traffic, which silently defeats the whole technique.
            var disturbers = new Thread[disturberCores.Length];
            for (int i = 0; i < disturberCores.Length; i++)
            {
                int core = disturberCores[i];
                disturbers[i] = new Thread(() => DisturberLoop(core)) { IsBackground = true, Name = $"disturber{core}" };
                disturbers[i].Start();
            }

            WindowsNative.Pin(reclaimerCore);

            var stopwatch = Stopwatch.StartNew();
            ReclaimerLoop();
            stopwatch.Stop();

            stop = true;
            reader.Join(2000);
            Console.WriteLine($"Completed {rounds:N0} rounds in {stopwatch.Elapsed.TotalSeconds:F1}s with NO fault. sink={Volatile.Read(ref sink)}");
            return 0;
        }

        private void DisturberLoop(int core)
        {
            WindowsNative.Pin(core);

            long local = 0;
            while (!stop)
            {
                for (int i = 0; i < 64; i++)
                    local += ops.ReadAllEntries();
            }

            Interlocked.Add(ref sink, local);
        }

        // Per-round spin length. Jitter sweeps the whole alignment space instead of
        // betting on one offset, since the resonant delay differs per core pair.
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private int NextDelay()
        {
            if (!jitter)
                return reclaimerDelay;

            rngState ^= rngState << 13;
            rngState ^= rngState >> 7;
            rngState ^= rngState << 17;
            return (int)(rngState % (ulong)(reclaimerDelay + 1));
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

        // BumpCurrentEpoch asserts ThisInstanceProtected(), so the retiring thread holds
        // an epoch and refreshes it every round, the way Tsavorite drives the epoch in
        // production. Retiring from an unprotected thread would leave it out of the
        // safe-epoch scan and widen the race window past anything real code can produce.
        private void ReclaimerLoop()
        {
            ops.Resume();

            for (long round = 0; round < rounds; round++)
            {
                byte* page = WindowsNative.Alloc(PageSize);
                for (int index = 0; index < 512; index++)
                    ((long*)page)[index] = index;
                Volatile.Write(ref curPage, (long)page);

                StartBarrier();

                // Align the unlink with the reader's announce. Leaving the barrier, the
                // reclaimer reaches this store in one instruction while the reader must
                // first run the slot-reservation CAS inside Acquire(), so without a delay
                // the unlink is already visible by the time the reader loads curPage and
                // the race window never opens. Spinning here is the litmus-test "delay"
                // knob; it shifts only when the reclaimer acts, never what it does.
                if (reclaimerDelay > 0)
                    Thread.SpinWait(NextDelay());

                curPage = 0;
                long pageAddress = (long)page;
                ops.BumpCurrentEpoch(() => WindowsNative.Free((byte*)pageAddress));
                ops.Refresh();

                EndBarrier();
            }

            ops.Suspend();
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
