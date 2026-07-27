using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading;
using LightEpoch.Core;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// Store-Buffer litmus for x86-64, where the unmap-based <see cref="Litmus{TOps,TPattern}"/>
    /// cannot observe the race.
    ///
    /// On x86 there is no architectural broadcast TLB invalidation, so unmapping a page makes
    /// the kernel send a TLB-shootdown IPI to every core holding the mapping. Taking an
    /// interrupt on x86 is a serializing event: it drains the interrupted core's store buffer.
    /// The reader is therefore fenced by the OS on every round and the announce store can never
    /// stay buffered long enough for the reclaimer's scan to miss it. ARM64 broadcasts TLB
    /// maintenance in hardware (TLBI ... IS), no core is interrupted, and the unmap mode works.
    ///
    /// This variant keeps the race identical but removes the kernel from the loop: pages come
    /// from a pool allocated once, "freeing" writes a poison sentinel over the page, and the
    /// drain callbacks are pre-built so no allocation (and therefore no GC suspension, which
    /// would call FlushProcessWriteBuffers) happens per round. Detection is logical rather
    /// than by hardware fault: a reader that observes poison in a page it was protecting is a
    /// use-after-free by the algorithm's own definition.
    /// </summary>
    internal sealed unsafe class QuarantineLitmus<TOps, TPattern>
        where TOps : struct, IEpochOps
        where TPattern : struct, IReproPattern
    {
        private const nuint PageSize = 4096;
        private const int PoolPages = 1024;
        private const long Poison = unchecked((long)0xDEAD_BEEF_DEAD_BEEFUL);

        private TOps ops;
        private TPattern pattern;
        private byte* pool;
        private long curPage;
        private int startCount;
        private int startSense;
        private int endCount;
        private int endSense;
        private long sink;
        private long violations;
        private long observedPages;
        private long drains;
        private long quarantines;
        private long firstViolationRound;
        private volatile bool stop;

        // One cached delegate per pool slot. BumpCurrentEpoch defers the drain callback
        // until the epoch decides the retired epoch is safe, which can be several rounds
        // later, so the callback must be bound to the page that was actually retired.
        // Building them once keeps that binding without allocating inside the race loop.
        private readonly Action[] drainCallbacks;

        private readonly long rounds;
        private readonly int deref;
        private readonly int readerCore;
        private readonly int reclaimerCore;
        private readonly bool selfTest;
        private readonly bool protectedReclaimer;

        public QuarantineLitmus(long rounds, int deref, int readerCore, int reclaimerCore, bool selfTest = false, bool protectedReclaimer = false)
        {
            this.rounds = rounds;
            this.deref = deref;
            this.readerCore = readerCore;
            this.reclaimerCore = reclaimerCore;
            this.selfTest = selfTest;
            this.protectedReclaimer = protectedReclaimer;
            ops = new TOps();
            pattern = new TPattern();
            firstViolationRound = -1;
            drainCallbacks = new Action[PoolPages];
        }

        public int Run()
        {
            Console.WriteLine($"ops = {ops.Name}");

            pool = WindowsNative.Alloc(PageSize * PoolPages);
            for (int slot = 0; slot < PoolPages; slot++)
            {
                long page = (long)(pool + ((nuint)slot * PageSize));
                drainCallbacks[slot] = () => Quarantine(page);
            }

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

            long observed = Volatile.Read(ref violations);
            long sampled = Volatile.Read(ref observedPages);
            if (observed > 0)
            {
                Console.Error.WriteLine($"USE-AFTER-FREE: reader read a quarantined page while protected. violations={observed:N0} firstRound={Volatile.Read(ref firstViolationRound):N0} elapsed={stopwatch.Elapsed.TotalSeconds:F1}s");
                return 1;
            }

            // Rounds where the reader captured a live pointer before the reclaimer
            // unlinked it. If this is ~0 the race window was never sampled and a clean
            // result says nothing about the memory model.
            Console.WriteLine($"Completed {rounds:N0} rounds in {stopwatch.Elapsed.TotalSeconds:F1}s with NO violation. sampledRounds={sampled:N0} drains={Volatile.Read(ref drains):N0} quarantined={Volatile.Read(ref quarantines):N0} sink={Volatile.Read(ref sink)}");
            return 0;
        }

        private void ReaderLoop()
        {
            WindowsNative.Pin(readerCore);

            for (long round = 0; round < rounds && !stop; round++)
            {
                StartBarrier();

                pattern.Enter(ref ops);
                ReadAndCheck(round);
                ops.Suspend();

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void ReadAndCheck(long round)
        {
            long pageAddress = curPage;
            if (pageAddress == 0)
                return;

            observedPages++;

            long* page = (long*)pageAddress;
            long accumulator = 0;
            bool poisoned = false;
            for (int index = 0; index < deref; index++)
            {
                long value = page[index & 511];
                poisoned |= value == Poison;
                accumulator += value;
            }

            sink += accumulator;

            if (poisoned)
            {
                Interlocked.Increment(ref violations);
                Interlocked.CompareExchange(ref firstViolationRound, round, -1);
            }
        }

        private void ReclaimerLoop()
        {
            if (protectedReclaimer)
                ops.Resume();

            for (long round = 0; round < rounds; round++)
            {
                byte* page = pool + ((nuint)(round % PoolPages) * PageSize);
                long* words = (long*)page;
                for (int index = 0; index < 512; index++)
                    words[index] = index;
                Volatile.Write(ref curPage, (long)page);

                StartBarrier();

                curPage = 0;

                // Self-test: poison unconditionally, as if the epoch had wrongly decided the
                // page was reclaimable on every round. Any reader that captured the pointer
                // must then observe poison, so this proves the detection path can fire.
                if (selfTest)
                    Quarantine((long)page);

                ops.BumpCurrentEpoch(drainCallbacks[round % PoolPages]);
                if (protectedReclaimer)
                    ops.Refresh();
                drains++;

                EndBarrier();
            }

            if (protectedReclaimer)
                ops.Suspend();
        }

        // Stands in for the unmap: the epoch has decided this page is safe to recycle, so
        // stamping it destroys any value a still-protected reader could legitimately see.
        private void Quarantine(long page)
        {
            quarantines++;
            long* words = (long*)page;
            for (int index = 0; index < 512; index++)
                words[index] = Poison;
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
