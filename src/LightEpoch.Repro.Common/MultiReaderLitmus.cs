using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading;
using LightEpoch.Core;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// N reader threads and one reclaimer sharing a SINGLE epoch instance.
    ///
    /// <para><see cref="Litmus{TOps,TPattern}"/> gives every pair its own <c>LightEpoch</c>, so
    /// each reader only ever recycles a slot it released itself. That covers the plain
    /// <c>0 -> E</c> announce, but never the case the TLA+ models flag: one thread claiming a
    /// slot a DIFFERENT thread just released.</para>
    ///
    /// <para>That case matters because <c>Release()</c> writes two plain, unordered stores
    /// (<c>localCurrentEpoch = 0</c> then <c>threadId = 0</c>) in both the baseline and the
    /// full-barrier build. On a machine that may drain them out of order, the releasing
    /// thread's stale <c>localCurrentEpoch = 0</c> can land AFTER the next owner has claimed
    /// the slot and announced into it, wiping a live announce. The CAS build is immune by
    /// construction: the claim word is the announce word, so a successful claim proves the
    /// previous owner's clearing store is already globally visible.</para>
    ///
    /// <para>Slot reuse does not arise on its own -- production hashes threads over 128 entries,
    /// so distinct threads essentially never share one. <c>TestSlotSpace</c> clamps that hash to a
    /// few slots to force the collision. <see cref="ReuseReport"/> then reports how many distinct
    /// threads were actually observed per slot, so the run can prove it created the condition
    /// rather than assuming it.</para>
    /// </summary>
    internal sealed unsafe class MultiReaderLitmus<TOps, TPattern>
        where TOps : struct, IEpochOps
        where TPattern : struct, IReproPattern
    {
        private const nuint PageSize = 4096;

        private TOps ops;
        private TPattern pattern;
        private readonly long rounds;
        private readonly int deref;
        private readonly int readerCount;
        private readonly int[] readerCores;
        private readonly int reclaimerCore;
        private readonly int reclaimerDelay;

        private long curPage;
        private long sink;
        private long frees;
        private volatile bool stop;

        private int startCount, endCount, startSense, endSense;
        private readonly int barrierParties;

        private readonly Dictionary<int, HashSet<int>> slotOwners = new();
        private readonly object slotLock = new();

        public MultiReaderLitmus(long rounds, int deref, int[] readerCores, int reclaimerCore, int reclaimerDelay, ushort slotSpace)
        {
            this.rounds = rounds;
            this.deref = deref;
            this.readerCores = readerCores;
            this.readerCount = readerCores.Length;
            this.reclaimerCore = reclaimerCore;
            this.reclaimerDelay = reclaimerDelay;
            this.barrierParties = readerCores.Length + 1;
            ops = new TOps();
            pattern = new TPattern();
            ops.SetTestSlotSpace(slotSpace);
        }

        public int Run()
        {
            Console.WriteLine($"ops = {ops.Name}");

            var readers = new Thread[readerCount];
            for (int i = 0; i < readerCount; i++)
            {
                int core = readerCores[i];
                readers[i] = new Thread(() => ReaderLoop(core)) { IsBackground = true, Name = $"reader{i}", Priority = ThreadPriority.Highest };
                readers[i].Start();
            }

            PlatformNative.Pin(reclaimerCore);

            var stopwatch = Stopwatch.StartNew();
            ReclaimerLoop();
            stopwatch.Stop();

            stop = true;
            // Readers may be parked on the barrier waiting for a reclaimer that has finished,
            // so release them rather than joining indefinitely.
            for (int i = 0; i < readerCount; i++)
                readers[i].Join(2000);

            Console.WriteLine($"Completed {rounds:N0} rounds in {stopwatch.Elapsed.TotalSeconds:F1}s with NO fault. freedPages={Volatile.Read(ref frees):N0} sink={Volatile.Read(ref sink)}");
            if (Volatile.Read(ref frees) == 0)
                Console.WriteLine("WARNING: nothing was ever reclaimed, so this run could not have faulted regardless of the epoch's correctness - the verdict is void");

            Console.WriteLine(ReuseReport());
            return 0;
        }

        /// <summary>
        /// Distinct threads observed holding each slot. A slot with more than one owner proves
        /// cross-thread reuse actually happened; if every slot reports exactly one, the run
        /// never exercised the scenario and its verdict says nothing about it.
        /// </summary>
        public string ReuseReport()
        {
            lock (slotLock)
            {
                int shared = 0, total = 0, maxOwners = 0;
                foreach (var kv in slotOwners)
                {
                    total++;
                    if (kv.Value.Count > 1)
                        shared++;
                    if (kv.Value.Count > maxOwners)
                        maxOwners = kv.Value.Count;
                }

                return $"slot reuse: {shared}/{total} slots held by >1 thread, max {maxOwners} distinct threads on one slot";
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void RecordSlot(int slot)
        {
            int tid = Environment.CurrentManagedThreadId;
            lock (slotLock)
            {
                if (!slotOwners.TryGetValue(slot, out var owners))
                {
                    owners = new HashSet<int>();
                    slotOwners[slot] = owners;
                }

                owners.Add(tid);
            }
        }

        private void ReaderLoop(int core)
        {
            PlatformNative.Pin(core);

            // Sampling the slot on every round would serialize the readers on slotLock and
            // close the very window under test, so only the first rounds are recorded.
            const long SampledRounds = 200;

            for (long round = 0; round < rounds && !stop; round++)
            {
                StartBarrier();

                pattern.Enter(ref ops);
                if (round < SampledRounds)
                    RecordSlot(ops.EntryIndex);
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
            ops.Resume();

            for (long round = 0; round < rounds && !stop; round++)
            {
                byte* page = PlatformNative.Alloc(PageSize);
                for (int index = 0; index < 512; index++)
                    ((long*)page)[index] = index;
                Volatile.Write(ref curPage, (long)page);

                StartBarrier();

                if (reclaimerDelay > 0)
                    Thread.SpinWait(reclaimerDelay);

                curPage = 0;
                long pageAddress = (long)page;
                ops.BumpCurrentEpoch(() => { PlatformNative.Free((byte*)pageAddress, PageSize); frees++; });
                ops.Refresh();

                EndBarrier();

                // A "survived" verdict is vacuous if the fix stopped reclaiming, and these runs
                // are usually killed at a time cap so the end-of-run summary never prints.
                if ((round & 0xFFFF) == 0)
                    MaybeReportProgress(round);
            }

            ops.Suspend();
        }

        private long lastProgressMs = Environment.TickCount64;

        private void MaybeReportProgress(long round)
        {
            long now = Environment.TickCount64;
            if (now - lastProgressMs < 10_000)
                return;

            lastProgressMs = now;
            Console.WriteLine($"progress: rounds={round:N0} freedPages={frees:N0}  {ReuseReport()}");
            Console.Out.Flush();
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void StartBarrier()
        {
            int sense = Volatile.Read(ref startSense);
            if (Interlocked.Increment(ref startCount) == barrierParties)
            {
                startCount = 0;
                Volatile.Write(ref startSense, sense ^ 1);
                return;
            }

            var spinner = new SpinWait();
            while (Volatile.Read(ref startSense) == sense && !stop)
                spinner.SpinOnce(-1);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void EndBarrier()
        {
            int sense = Volatile.Read(ref endSense);
            if (Interlocked.Increment(ref endCount) == barrierParties)
            {
                endCount = 0;
                Volatile.Write(ref endSense, sense ^ 1);
                return;
            }

            var spinner = new SpinWait();
            while (Volatile.Read(ref endSense) == sense && !stop)
                spinner.SpinOnce(-1);
        }
    }
}
