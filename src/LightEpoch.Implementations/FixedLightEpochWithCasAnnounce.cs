using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace LightEpoch.Core
{
    /// <summary>
    /// Epoch protection
    /// </summary>
    public sealed unsafe class FixedLightEpochWithCasAnnounce
    {
        /// <summary>
        /// Buffer to track information for LightEpoch instances. This is used:
        /// (1) in AssignInstance, to assign a unique instanceId to each LightEpoch instance, and
        /// (2) in Metadata, to track per-thread epoch table entries for each LightEpoch instance.
        /// </summary>
        [InlineArray(MaxInstances)]
        private struct InstanceIndexBuffer
        {
            /// <summary>
            /// Maximum number of concurrent instances of LightEpoch supported.
            /// </summary>
            internal const int MaxInstances = 1024;

            /// <summary>
            /// Anchor field for the buffer.
            /// </summary>
            int field0;

            /// <summary>
            /// Reference to the entry for the given instance ID.
            /// </summary>
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            [UnscopedRef]
            internal ref int GetRef(int instanceId)
            {
                Debug.Assert(instanceId >= 0 && instanceId < MaxInstances);
                return ref Unsafe.Add(ref field0, instanceId);
            }
        }

        /// <summary>
        /// Store for thread-static metadata.
        /// </summary>
        private class Metadata
        {
            /// <summary>
            /// Managed thread id of this thread
            /// </summary>
            [ThreadStatic]
            internal static int threadId;

            /// <summary>
            /// Start offset to reserve entry in the epoch table
            /// </summary>
            [ThreadStatic]
            internal static ushort startOffset1;

            /// <summary>
            /// Alternate start offset to reserve entry in the epoch table (to reduce probing if <see cref="startOffset1"/> slot is already filled)
            /// </summary>
            [ThreadStatic]
            internal static ushort startOffset2;

            /// <summary>
            /// This is the thread-static index for fast access to the tableAligned index 
            /// that is obtained when each LightEpoch instance calls ReserveEntry.
            /// The instanceId of the LightEpoch instance (assigned to the instance 
            /// at constructor time using InstanceTracker) is the lookup offset into 
            /// Entries.
            /// 
            /// Note that Entries effectively gives us ThreadLocal{T} semantics of 
            /// (instance, thread)-specific metadata, without the overhead of 
            /// ThreadLocal{T}.
            /// </summary>
            [ThreadStatic]
            internal static InstanceIndexBuffer Entries;
        }

        /// <summary>
        /// Size of cache line in bytes
        /// </summary>
        const int kCacheLineBytes = 64;

        /// <summary>
        /// Default invalid index entry.
        /// </summary>
        const int kInvalidIndex = 0;

        /// <summary>
        /// Default number of entries in the entries table
        /// </summary>
        static readonly ushort kTableSize = Math.Max((ushort)128, (ushort)(Environment.ProcessorCount * 2));

        /// <summary>
        /// Ordering of the refresh announce in <see cref="ProtectAndDrain"/>:
        /// 0 = plain store, 1 = release store, 2 = plain store followed by a full StoreLoad fence,
        /// 3 = plain store of an acquire-loaded CurrentEpoch.
        /// The acquire announce is carried by a CAS and is always ordered; this isolates whether the
        /// separate epoch-advancing store needs ordering of its own, and on which side.
        /// <para>
        /// DEFAULTS TO 3 (acquire load), which is the fix. Modes 0 and 1 are known-broken and exist
        /// only as A/B controls. On Neoverse-N2, resume-and-refresh with 8 pairs, quarantine mode,
        /// 3 runs per arm: mode 0 registered 2,475-435,814 violations and mode 1 (release) 235,051-848,621,
        /// against an unfixed baseline of 115,601-1,035,797 — while mode 3 registered 0, 0, 0 across
        /// roughly 30 million sampled opportunities, with the detector's self-test converting at 0.99998.
        /// A release store is therefore no better than no fix at all: it orders the wrong side.
        /// Mode 2 is also safe but strictly more expensive than mode 3 for no benefit.
        /// Selecting a mode other than 3 deliberately reintroduces the use-after-free.
        /// </para>
        /// </summary>
        static readonly string[] RefreshOrderNames = ["plain", "release", "fence", "acqload"];

        internal static readonly int TestRefreshOrder = ParseRefreshOrder(Environment.GetEnvironmentVariable("LE_REFRESH_ORDER"));

        /// <summary>
        /// Resolved name of <see cref="TestRefreshOrder"/>, for the harness banner. The banner is the
        /// record of which arm a run actually exercised, so it must report the resolved mode rather
        /// than echo the raw environment string.
        /// </summary>
        public static string RefreshOrderName => RefreshOrderNames[TestRefreshOrder] + (Environment.GetEnvironmentVariable("LE_REFRESH_ORDER") is null ? " (default)" : string.Empty);

        /// <summary>
        /// An unrecognised value throws rather than falling back. A silent fallback lands on the fixed
        /// mode, so a mistyped control would survive and be misread as evidence that a broken mode is safe.
        /// </summary>
        static int ParseRefreshOrder(string value)
        {
            if (value is null)
                return 3;

            int index = Array.IndexOf(RefreshOrderNames, value);
            if (index < 0)
                throw new ArgumentException($"LE_REFRESH_ORDER='{value}' is not recognised; expected one of {string.Join(", ", RefreshOrderNames)}");

            return index;
        }

        /// <summary>
        /// Test-only. Selects how the ACQUIRE announce (the slot-claiming CAS in
        /// <see cref="TryAcquireEntry"/>) is ordered. 0 = bare CAS, 1 = CAS followed by a full barrier.
        /// <para>
        /// The CAS cannot be demoted to a plain store: it claims slot ownership, so two threads racing
        /// for the same slot need it to be atomic. The open question is its ORDERING, which on AArch64
        /// depends on codegen. Checked against ARM's official aarch64.cat with herd7:
        /// </para>
        /// <list type="bullet">
        /// <item>LSE <c>CASAL</c> — FORBIDDEN (safe).</item>
        /// <item>armv8.0 <c>LDAXR</c>/<c>STLXR</c> loop — ALLOWED (unsafe): an acquire load composed
        /// with a release store does not produce a StoreLoad edge.</item>
        /// <item>either form followed by <c>DMB ISH</c> — FORBIDDEN (safe).</item>
        /// </list>
        /// <para>
        /// .NET picks LSE versus the exclusive loop at runtime from the CPU's features. RESOLVED: both
        /// forms are safe, so mode 1 is redundant on .NET and exists only to A/B the cost. RyuJIT's
        /// <c>genCodeForCmpXchg</c> (src/coreclr/jit/codegenarm64.cpp) emits <c>casal</c> when
        /// <c>InstructionSet_Atomics</c> is available, and otherwise an <c>ldaxr</c>/<c>stlxr</c> loop
        /// followed by an unconditional <c>instGen_MemoryBarrier()</c> — a <c>dmb ish</c> placed at the
        /// join label, so it is reached on both the success and compare-fail paths. That trailing barrier
        /// is exactly the mitigation herd7 found sufficient, so the bare CAS is sound on both paths.
        /// Mode 1 measured +49% to +64% on the hot path, so it is not free insurance and is not enabled.
        /// </para>
        /// </summary>
        static readonly string[] AcquireOrderNames = ["cas", "fence"];

        internal static readonly int TestAcquireOrder = ParseAcquireOrder(Environment.GetEnvironmentVariable("LE_ACQUIRE_ORDER"));

        /// <summary>
        /// Resolved name of <see cref="TestAcquireOrder"/>, for the harness banner.
        /// </summary>
        public static string AcquireOrderName => AcquireOrderNames[TestAcquireOrder] + (Environment.GetEnvironmentVariable("LE_ACQUIRE_ORDER") is null ? " (default)" : string.Empty);

        static int ParseAcquireOrder(string value)
        {
            if (value is null)
                return 0;

            int index = Array.IndexOf(AcquireOrderNames, value);
            if (index < 0)
                throw new ArgumentException($"LE_ACQUIRE_ORDER='{value}' is not recognised; expected one of {string.Join(", ", AcquireOrderNames)}");

            return index;
        }

        /// <summary>
        /// Ordering of the slot-free publish in <see cref="Release"/>:
        /// 0 = release store (<c>Volatile.Write</c>, emits <c>stlr</c>), 1 = full-fence RMW
        /// (<c>Interlocked.Exchange</c>, emits <c>swpal</c>).
        /// <para>
        /// This selects between the two candidate fixes for the lost-wakeup store-buffering pair
        /// between <see cref="Release"/> and <see cref="ReserveEntryWait"/>. <see cref="Release"/>
        /// publishes the slot as free and then probes <c>waiterCount</c> to decide whether to
        /// signal the semaphore; a waiter registers with <c>Interlocked.Increment</c> and re-probes
        /// the slot before sleeping. If both loads return stale values the waiter sleeps forever
        /// on a slot that is free.
        /// </para>
        /// <para>
        /// Mode 0 relies on AArch64 release/acquire being RCsc, so that the <c>stlr</c> here and the
        /// <c>ldar</c> for the <c>waiterCount</c> probe supply StoreLoad ordering as a pair. That
        /// holds only if the JIT emits <c>ldar</c> rather than the RCpc <c>ldapr</c>. Mode 1 does not
        /// depend on that choice: a full-fence RMW forbids the hang under every reading, at the cost
        /// of a locked operation on the per-operation release path. This knob exists to price that.
        /// </para>
        /// <para>
        /// Mode 2 (<c>plain</c>) reproduces the production spelling — an ordinary store — and exists
        /// purely as the measurement baseline that modes 0 and 1 are priced against.
        /// </para>
        /// </summary>
        static readonly string[] ReleaseOrderNames = ["volatile", "exchange", "plain"];

        internal static readonly int TestReleaseOrder = ParseReleaseOrder(Environment.GetEnvironmentVariable("LE_RELEASE_ORDER"));

        /// <summary>
        /// Resolved name of <see cref="TestReleaseOrder"/>, for the harness banner.
        /// </summary>
        public static string ReleaseOrderName => ReleaseOrderNames[TestReleaseOrder] + (Environment.GetEnvironmentVariable("LE_RELEASE_ORDER") is null ? " (default)" : string.Empty);

        static int ParseReleaseOrder(string value)
        {
            if (value is null)
                return 0;

            int index = Array.IndexOf(ReleaseOrderNames, value);
            if (index < 0)
                throw new ArgumentException($"LE_RELEASE_ORDER='{value}' is not recognised; expected one of {string.Join(", ", ReleaseOrderNames)}");

            return index;
        }

        /// <summary>
        /// Ordering of the drain-list publish store (the <c>epoch</c> field that makes a slot's
        /// <c>action</c> visible to a concurrent <see cref="Drain"/>):
        /// 0 = release store (<c>Volatile.Write</c>), 1 = ordinary store (the production spelling).
        /// <para>
        /// Production writes <c>action</c> then <c>epoch</c> with two ordinary stores, so a concurrent
        /// <see cref="Drain"/> — which scans every slot and is not gated on <c>drainCount</c> — may
        /// observe the new epoch without the matching action and invoke <c>null</c> or the stale
        /// previous delegate. The trailing <c>Interlocked</c> on two of the three sites does not help:
        /// it constrains both stores jointly against later accesses and says nothing about their
        /// order relative to each other, and the reclaim-and-replace branch has no interlocked
        /// operation after the stores at all.
        /// </para>
        /// <para>
        /// All three sites fire at hybrid-log page or checkpoint granularity, so this knob is
        /// expected to be unmeasurable on the per-operation benchmark. It exists to demonstrate that.
        /// </para>
        /// </summary>
        static readonly string[] DrainPublishOrderNames = ["volatile", "plain"];

        internal static readonly int TestDrainPublishOrder = ParseDrainPublishOrder(Environment.GetEnvironmentVariable("LE_DRAIN_PUBLISH_ORDER"));

        /// <summary>
        /// Resolved name of <see cref="TestDrainPublishOrder"/>, for the harness banner.
        /// </summary>
        public static string DrainPublishOrderName => DrainPublishOrderNames[TestDrainPublishOrder] + (Environment.GetEnvironmentVariable("LE_DRAIN_PUBLISH_ORDER") is null ? " (default)" : string.Empty);

        static int ParseDrainPublishOrder(string value)
        {
            if (value is null)
                return 0;

            int index = Array.IndexOf(DrainPublishOrderNames, value);
            if (index < 0)
                throw new ArgumentException($"LE_DRAIN_PUBLISH_ORDER='{value}' is not recognised; expected one of {string.Join(", ", DrainPublishOrderNames)}");

            return index;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static void PublishDrainEpoch(ref long slot, long value)
        {
            if (TestDrainPublishOrder == 0)
                Volatile.Write(ref slot, value);
            else
                slot = value;
        }

        /// <summary>
        /// Test-only. When non-zero, every thread's home offsets are hashed into just this
        /// many slots instead of the whole table, so distinct threads repeatedly claim the
        /// slot another thread just released. Production hashing spreads threads over 128
        /// entries, making cross-thread slot reuse too rare to exercise on hardware.
        /// </summary>
        internal static ushort TestSlotSpace;

        /// <summary>
        /// Default drainlist size
        /// </summary>
        const int kDrainListSize = 16;

        /// <summary>
        /// Thread protection status entries.
        /// </summary>
        readonly Entry[] tableRaw;
        readonly Entry* tableAligned;

        /// <summary>
        /// Semaphore for threads waiting for an epoch table entry
        /// </summary>
        readonly SemaphoreSlim waiterSemaphore = new(0);

        /// <summary>
        /// Cancellation token source used to cancel threads waiting on the semaphore during Dispose.
        /// </summary>
        readonly CancellationTokenSource cts = new();

        /// <summary>
        /// Number of threads waiting for an epoch table entry (lower 31 bits).
        /// MSB is set during Dispose to prevent new waiters from entering.
        /// </summary>
        volatile int waiterCount = 0;

        /// <summary>
        /// Flag (MSB) used to mark the epoch as disposed in <see cref="waiterCount"/>.
        /// </summary>
        const int kDisposedFlag = unchecked((int)0x80000000);

        /// <summary>
        /// List of action, epoch pairs containing actions to be performed when an epoch becomes safe to reclaim.
        /// Marked volatile to ensure latest value is seen by the last suspended thread.
        /// </summary>
        volatile int drainCount = 0;
        readonly EpochActionPair[] drainList = new EpochActionPair[kDrainListSize];

        /// <summary>
        /// Global current epoch value
        /// </summary>
        internal long CurrentEpoch;

        /// <summary>
        /// Cached value of latest epoch that is safe to reclaim
        /// </summary>
        internal long SafeToReclaimEpoch;

        /// <summary>
        /// ID of this LightEpoch instance
        /// </summary>
        readonly int instanceId;

        /// <summary>
        /// Maximum number of general-purpose per-thread <see cref="long"/> user-word slots that subsystems
        /// can claim via <see cref="AllocateUserWord(long)"/>. Bounded by the free space in <see cref="Entry"/>'s
        /// cache line (48 bytes = 6 longs).
        /// </summary>
        public const int MaxUserWords = 6;

        /// <summary>
        /// Bitmask of claimed user-word slots. Each set bit means that word index is in use by some
        /// subsystem. Managed exclusively via CAS in <see cref="AllocateUserWord"/> and
        /// <see cref="ReleaseUserWord"/>. Not read on the epoch Acquire/Release hot path.
        /// </summary>
        int userWordMask;

        /// <summary>
        /// This is the LightEpoch-level static buffer (array) of available instance slots.
        /// On LightEpoch instance creation, it is used by SelectInstance() to find an
        /// available slot in this array; this becomes the LightEpoch instance's instanceId,
        /// which is the lookup index into the thread-static Metadata.Entries.
        /// </summary>
        static InstanceIndexBuffer InstanceTracker;

        /// <summary>
        /// Instantiate the epoch table
        /// </summary>
        public FixedLightEpochWithCasAnnounce()
        {
            instanceId = SelectInstance();

            long p;

            tableRaw = GC.AllocateArray<Entry>(kTableSize + 2, true);
            p = (long)Unsafe.AsPointer(ref tableRaw[0]);

            // Force the pointer to align to 64-byte boundaries
            long p2 = (p + (kCacheLineBytes - 1)) & ~(kCacheLineBytes - 1);
            tableAligned = (Entry*)p2;

            CurrentEpoch = 1;
            SafeToReclaimEpoch = 0;

            // Mark all epoch table entries as "available"
            for (int i = 0; i < kDrainListSize; i++)
                drainList[i].epoch = long.MaxValue;
            drainCount = 0;
        }

        int SelectInstance()
        {
            for (var i = 0; i < InstanceIndexBuffer.MaxInstances; i++)
            {
                ref var entry = ref InstanceTracker.GetRef(i);
                // Try to claim this instance ID (indicated as 1 in the entry)
                if (kInvalidIndex == Interlocked.CompareExchange(ref entry, 1, kInvalidIndex))
                    return i;
            }
            throw new InvalidOperationException($"Exceeded maximum number of active LightEpoch instances {ActiveInstanceCount()} {InstanceIndexBuffer.MaxInstances}");
        }

        /// <summary>
        /// Number of active LightEpoch instances. Used for testing and diagnostics.
        /// </summary>
        /// <returns></returns>
        public static int ActiveInstanceCount()
        {
            int count = 0;
            for (var i = 0; i < InstanceIndexBuffer.MaxInstances; i++)
            {
                if (kInvalidIndex != InstanceTracker.GetRef(i))
                    count++;
            }
            return count;
        }

        /// <summary>
        /// Reset all instances. Used for testing to reset static LightEpoch state for all instances.
        /// </summary>
        public static void ResetAllInstances()
        {
            for (var i = 0; i < InstanceIndexBuffer.MaxInstances; i++)
            {
                InstanceTracker.GetRef(i) = kInvalidIndex;
            }
        }

        /// <summary>
        /// Clean up epoch table
        /// </summary>
        public void Dispose()
        {
            // Cancel any threads currently waiting on the semaphore so they
            // unwind and decrement waiterCount.
            cts.Cancel();

            // Atomically set the disposed flag after all waiters are done.
            while (true)
            {
                if (Interlocked.CompareExchange(ref waiterCount, kDisposedFlag, 0) == 0)
                    break;
                Thread.Yield();
            }

            CurrentEpoch = 1;
            SafeToReclaimEpoch = 0;
            // Mark this instance ID as available
            InstanceTracker.GetRef(instanceId) = kInvalidIndex;

            cts.Dispose();
            waiterSemaphore.Dispose();
        }

        /// <summary>
        /// Check whether current epoch instance is protected on this thread
        /// </summary>
        /// <returns>Result of the check</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool ThisInstanceProtected()
        {
            ref var entry = ref Metadata.Entries.GetRef(instanceId);
            return kInvalidIndex != entry && (*(tableAligned + entry)).threadId == Metadata.threadId;
        }

        /// <summary>
        /// Test-only. The table index this thread currently holds, so a harness can verify
        /// that distinct threads really do recycle the same slot.
        /// </summary>
        internal int ThisThreadEntry() => Metadata.Entries.GetRef(instanceId);

        /// <summary>Tripwire diagnostic: the epoch this thread currently announces, or 0 if unprotected.</summary>
        internal long ThisThreadAnnouncedEpoch()
        {
            var entry = Metadata.Entries.GetRef(instanceId);
            return entry == kInvalidIndex ? 0 : (*(tableAligned + entry)).localCurrentEpoch;
        }

        /// <summary>
        /// Try to suspend the epoch, if it is currently held
        /// </summary>
        /// <returns></returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool TrySuspend()
        {
            if (ThisInstanceProtected())
            {
                Suspend();
                return true;
            }
            return false;
        }

        /// <summary>
        /// Enter the thread into the protected code region
        /// </summary>
        /// <returns>Current epoch</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void ProtectAndDrain()
        {
            ref var entry = ref Metadata.Entries.GetRef(instanceId);

            Debug.Assert(entry > 0, "Trying to refresh unacquired epoch");
            Debug.Assert((*(tableAligned + entry)).threadId > 0, "Epoch table entry missing threadId");

            // Protect CurrentEpoch by copying it to the instance-specific epoch table
            // so that ComputeNewSafeToReclaimEpoch() will see it.
            if (TestRefreshOrder == 0)
            {
                (*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;
            }
            else if (TestRefreshOrder == 1)
            {
                Volatile.Write(ref (*(tableAligned + entry)).localCurrentEpoch, CurrentEpoch);
            }
            else if (TestRefreshOrder == 2)
            {
                (*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;
                Interlocked.MemoryBarrier();
            }
            else
            {
                // The hazard here is purely load-side. The reclaimer already orders its
                // unlink before the epoch bump (Interlocked.Increment is a full RMW), so
                // this is message passing: reading the bumped epoch must imply seeing the
                // unlink. An acquire load supplies exactly that, and nothing more.
                //
                // Announcing an epoch this thread has not caught up to is what authorises
                // the reclaimer to free an object this thread is about to read: a raised
                // slot raises SafeToReclaimEpoch. Reading CurrentEpoch with acquire means
                // a thread that announces the new epoch has necessarily observed the
                // unlink that preceded it, so it never enters the critical section.
                //
                // x86 gives every load acquire semantics, which is why the plain store is
                // safe there and this is a plain MOV; on AArch64 it is LDAR, far cheaper
                // than the DMB ISH a full barrier costs.
                (*(tableAligned + entry)).localCurrentEpoch = Volatile.Read(ref CurrentEpoch);
            }

            // Max epoch across all threads may have advanced, so check for pending drain actions to process
            if (drainCount > 0)
                Drain((*(tableAligned + entry)).localCurrentEpoch);

            if (waiterCount > 0)
            {
                SuspendResume();
            }
        }

        /// <summary>
        /// Thread suspends, then resumes, to give waiting threads a fair chance of making progress.
        /// </summary>
        [MethodImpl(MethodImplOptions.NoInlining)]
        public void SuspendResume()
        {
            Suspend();
            Resume();
        }

        /// <summary>
        /// Thread suspends its epoch entry
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Suspend()
        {
            Release();
            if (drainCount > 0)
                SuspendDrain();
        }

        /// <summary>
        /// Thread resumes its epoch entry
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Resume()
        {
            Acquire();
        }

        /// <summary>
        /// Thread resumes its epoch entry if it has not already been acquired
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool ResumeIfNotProtected()
        {
            if (ThisInstanceProtected())
                return false;
            Resume();
            return true;
        }

        /// <summary>
        /// Increment global current epoch
        /// </summary>
        /// <returns></returns>
        internal long BumpCurrentEpoch()
        {
            Debug.Assert(ThisInstanceProtected(), "BumpCurrentEpoch must be called on a protected thread");
            var nextEpoch = Interlocked.Increment(ref CurrentEpoch);

            if (drainCount > 0)
                Drain(nextEpoch);
            else
                _ = ComputeNewSafeToReclaimEpoch(nextEpoch);

            return nextEpoch;
        }

        /// <summary>
        /// Increment current epoch and associate trigger action
        /// with the prior epoch
        /// </summary>
        /// <param name="onDrain">Trigger action</param>
        /// <returns></returns>
        public void BumpCurrentEpoch(Action onDrain)
        {
            var PriorEpoch = BumpCurrentEpoch() - 1;

            var i = 0;
            while (true)
            {
                if (Volatile.Read(ref drainList[i].epoch) == long.MaxValue)
                {
                    // This was an empty slot. If it still is, assign this action/epoch to the slot.
                    if (Interlocked.CompareExchange(ref drainList[i].epoch, long.MaxValue - 1, long.MaxValue) == long.MaxValue)
                    {
                        drainList[i].action = onDrain;
                        PublishDrainEpoch(ref drainList[i].epoch, PriorEpoch);
                        _ = Interlocked.Increment(ref drainCount);
                        break;
                    }
                }
                else
                {
                    var triggerEpoch = Volatile.Read(ref drainList[i].epoch);

                    if (triggerEpoch <= SafeToReclaimEpoch)
                    {
                        // This was a slot with an epoch that was safe to reclaim. If it still is, execute its trigger, then assign this action/epoch to the slot.
                        if (Interlocked.CompareExchange(ref drainList[i].epoch, long.MaxValue - 1, triggerEpoch) == triggerEpoch)
                        {
                            var triggerAction = drainList[i].action;
                            drainList[i].action = onDrain;
                            PublishDrainEpoch(ref drainList[i].epoch, PriorEpoch);
                            triggerAction();
                            break;
                        }
                    }
                }

                if (++i == kDrainListSize)
                {
                    // We are at the end of the drain list and found no empty or reclaimable slot. ProtectAndDrain, which should clear one or more slots.
                    ProtectAndDrain();
                    i = 0;
                    _ = Thread.Yield();
                }
            }

            // Now ProtectAndDrain, which may execute the action we just added.
            ProtectAndDrain();
        }

        /// <summary>
        /// Repro instrumentation. Reads every epoch-table entry and returns their sum.
        /// Purely read-only, so it cannot influence any epoch decision; it exists so a
        /// disturber thread can keep the table's cache lines in a shared state rather
        /// than exclusively owned by the thread that announces into them. An announce
        /// into a shared line must first win an RFO, and because x86 store buffers
        /// commit in order that keeps the announce pending long enough for the missing
        /// StoreLoad fence to be observable.
        /// </summary>
        public long ReadAllEntries()
        {
            long sum = 0;
            for (var index = 1; index <= kTableSize; index++)
                sum += (*(tableAligned + index)).localCurrentEpoch;

            return sum;
        }

        /// <summary>
        /// Looks at all threads and return the latest safe epoch
        /// </summary>
        /// <param name="currentEpoch">Current epoch</param>
        /// <returns>Safe epoch</returns>
        long ComputeNewSafeToReclaimEpoch(long currentEpoch)
        {
            var oldestOngoingCall = currentEpoch;

            for (var index = 1; index <= kTableSize; index++)
            {
                var entry_epoch = (*(tableAligned + index)).localCurrentEpoch;
                if (0 != entry_epoch)
                {
                    if (entry_epoch < oldestOngoingCall)
                        oldestOngoingCall = entry_epoch;
                }
            }

            // The latest safe epoch is the one just before the earliest unsafe epoch.
            SafeToReclaimEpoch = oldestOngoingCall - 1;
            return SafeToReclaimEpoch;
        }

        /// <summary>
        /// Take care of pending drains after epoch suspend
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void SuspendDrain()
        {
            while (drainCount > 0)
            {
                // Barrier ensures we see the latest epoch table entries. Ensures
                // that the last suspended thread drains all pending actions.
                Thread.MemoryBarrier();
                for (var index = 1; index <= kTableSize; index++)
                {
                    var entry_epoch = (*(tableAligned + index)).localCurrentEpoch;
                    if (0 != entry_epoch)
                        return;
                }
                Resume();
                Release();
            }
        }

        /// <summary>
        /// Check and invoke trigger actions that are ready
        /// </summary>
        /// <param name="nextEpoch">Next epoch</param>
        [MethodImpl(MethodImplOptions.NoInlining)]
        void Drain(long nextEpoch)
        {
            _ = ComputeNewSafeToReclaimEpoch(nextEpoch);

            for (var i = 0; i < kDrainListSize; i++)
            {
                var trigger_epoch = Volatile.Read(ref drainList[i].epoch);

                if (trigger_epoch <= SafeToReclaimEpoch)
                {
                    if (Interlocked.CompareExchange(ref drainList[i].epoch, long.MaxValue - 1, trigger_epoch) == trigger_epoch)
                    {
                        // Store off the trigger action, then set epoch to int.MaxValue to mark this slot as "available for use".
                        var trigger_action = drainList[i].action;
                        drainList[i].action = null;
                        PublishDrainEpoch(ref drainList[i].epoch, long.MaxValue);
                        _ = Interlocked.Decrement(ref drainCount);

                        // Execute the action
                        trigger_action();
                        if (drainCount == 0)
                            break;
                    }
                }
            }
        }

        /// <summary>
        /// Thread acquires its epoch entry
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void Acquire()
        {
            ref var entry = ref Metadata.Entries.GetRef(instanceId);
            Debug.Assert(entry == kInvalidIndex,
                "Trying to acquire protected epoch. Make sure you do not re-enter Tsavorite from callbacks or IDevice implementations. If using tasks, use TaskCreationOptions.RunContinuationsAsynchronously.");

            // Read CurrentEpoch BEFORE claiming the slot. A stale (older) read is safe: it can
            // only lower oldestOngoingCall, hence lower SafeToReclaimEpoch, which is the
            // conservative direction. It can never let a reclaimer advance past this thread.
            var epoch = CurrentEpoch;

            // Reserve an entry in the epoch table for this thread. The reservation CAS writes
            // localCurrentEpoch, so claiming the slot and announcing the epoch are a single
            // locked RMW: the announce is globally visible before any load in the protected
            // region, closing the StoreLoad window against ComputeNewSafeToReclaimEpoch().
            ReserveEntryForThread(ref entry, epoch);

            Debug.Assert((*(tableAligned + entry)).threadId > 0, "Epoch table entry missing threadId");

            // Max epoch across all threads may have advanced, so check for pending drain actions to process
            if (drainCount > 0)
            {
                Drain((*(tableAligned + entry)).localCurrentEpoch);
            }
        }

        /// <summary>
        /// Thread releases its epoch entry
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void Release()
        {
            ref var entry = ref Metadata.Entries.GetRef(instanceId);

            Debug.Assert((*(tableAligned + entry)).localCurrentEpoch != 0,
                "Trying to release unprotected epoch. Make sure you do not re-enter Tsavorite from callbacks or IDevice implementations. If using tasks, use TaskCreationOptions.RunContinuationsAsynchronously.");

            // Clear "ThisInstanceProtected()" (non-static epoch table)
            (*(tableAligned + entry)).threadId = 0;

            // localCurrentEpoch is the slot-ownership word, so this store is what publishes the
            // slot as free. It must be a release store: if it were reordered ahead of the
            // threadId clear above, another thread could win the claim CAS and write its own
            // threadId, only for this thread's clear to land afterwards and wipe it.
            if (TestReleaseOrder == 0)
                Volatile.Write(ref (*(tableAligned + entry)).localCurrentEpoch, 0);
            else if (TestReleaseOrder == 1)
                _ = Interlocked.Exchange(ref (*(tableAligned + entry)).localCurrentEpoch, 0);
            else
                (*(tableAligned + entry)).localCurrentEpoch = 0;

            entry = kInvalidIndex;
            if (waiterCount > 0)
                waiterSemaphore.Release();
        }

        /// <summary>
        /// Try to acquire an entry by probing startOffset1, startOffset2, 
        /// then circling twice around the epoch table. On a successful acquire, 
        /// startOffset1 contains the acquired offset so that the next acquire 
        /// can optimistically get the same slot. This method relies on the fact 
        /// that no thread will ever have ID 0.
        /// </summary>
        /// <returns>True if entry was acquired, false if table is full</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        bool TryAcquireEntry(ref int entry, long epoch)
        {
            // Try primary offset
            entry = Metadata.startOffset1;
            if (0 == (tableAligned + entry)->localCurrentEpoch)
            {
                if (0 == Interlocked.CompareExchange(
                    ref (tableAligned + entry)->localCurrentEpoch,
                    epoch, 0))
                {
                    if (TestAcquireOrder == 1)
                        Interlocked.MemoryBarrier();
                    (tableAligned + entry)->threadId = Metadata.threadId;
                    return true;
                }
            }

            // Try alternate offset
            var tmp = Metadata.startOffset1;
            Metadata.startOffset1 = Metadata.startOffset2;
            Metadata.startOffset2 = tmp;

            entry = Metadata.startOffset1;
            if (0 == (tableAligned + entry)->localCurrentEpoch)
            {
                if (0 == Interlocked.CompareExchange(
                    ref (tableAligned + entry)->localCurrentEpoch,
                    epoch, 0))
                {
                    if (TestAcquireOrder == 1)
                        Interlocked.MemoryBarrier();
                    (tableAligned + entry)->threadId = Metadata.threadId;
                    return true;
                }
            }

            // Circle twice around the table looking for free entries
            for (var i = 0; i < 2 * kTableSize; i++)
            {
                Metadata.startOffset1++;
                if (Metadata.startOffset1 > kTableSize)
                    Metadata.startOffset1 -= kTableSize;

                entry = Metadata.startOffset1;
                if (0 == (tableAligned + entry)->localCurrentEpoch)
                {
                    if (0 == Interlocked.CompareExchange(
                        ref (tableAligned + entry)->localCurrentEpoch,
                        epoch, 0))
                    {
                        if (TestAcquireOrder == 1)
                            Interlocked.MemoryBarrier();
                        (tableAligned + entry)->threadId = Metadata.threadId;
                        return true;
                    }
                }
            }

            // Note: Metadata.startOffset1 should now be back to where it started because
            // we circled the entire table twice.
            entry = kInvalidIndex;
            return false;
        }

        /// <summary>
        /// Reserve entry for thread. First try synchronous acquire, then fall back to a SemaphoreSlim wait.
        /// </summary>
        /// <returns>Reserved entry</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void ReserveEntry(ref int entry, long epoch)
        {
            if (TryAcquireEntry(ref entry, epoch))
                return;

            // Table is full, fall back to slow path with waiting
            ReserveEntryWait(ref entry);
        }

        /// <summary>
        /// Slow path for reserving an entry when the table is full.
        /// Waits on semaphore until an entry becomes available.
        /// </summary>
        /// <returns>Reserved entry</returns>
        [MethodImpl(MethodImplOptions.NoInlining)]
        void ReserveEntryWait(ref int entry)
        {
            int newCount = Interlocked.Increment(ref waiterCount);
            try
            {
                // If the MSB (disposed flag) is set, the epoch is being disposed.
                if ((newCount & kDisposedFlag) != 0)
                    throw new ObjectDisposedException(nameof(FixedLightEpochWithCasAnnounce));

                while (true)
                {
                    // Re-check for free slot after incrementing waiterCount. This avoids
                    // us waiting on the semaphore forever in case we increment waiterCount
                    // immediately after the epoch releaser sees a zero waiterCount (and
                    // therefore does not release the semaphore).
                    // Re-read CurrentEpoch on each attempt so a long wait does not announce a
                    // stale epoch and pin reclamation behind this thread.
                    if (TryAcquireEntry(ref entry, CurrentEpoch))
                        return;

                    // No slot available, wait for a signal from Release()
                    waiterSemaphore.Wait(cts.Token);
                }
            }
            catch (OperationCanceledException)
            {
                throw new ObjectDisposedException(nameof(FixedLightEpochWithCasAnnounce));
            }
            finally
            {
                _ = Interlocked.Decrement(ref waiterCount);
            }
        }

        /// <summary>
        /// Allocate a new entry in epoch table
        /// </summary>
        /// <returns>Reserved entry</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void ReserveEntryForThread(ref int entry, long epoch)
        {
            if (Metadata.threadId == 0) // run once per thread for performance
                Metadata.threadId = Environment.CurrentManagedThreadId;

            // TryAcquireEntry's probe loop advances startOffset1, so under TestSlotSpace the home
            // offsets are re-seeded on every acquire. Without this each thread drifts onto a
            // private slot within a few rounds and the cross-thread reuse under test disappears.
            if (Metadata.startOffset1 == 0 || TestSlotSpace != 0)
            {
                var code = (uint)Utility.Murmur3(Metadata.threadId);
                var span = TestSlotSpace == 0 ? kTableSize : TestSlotSpace;
                Metadata.startOffset1 = (ushort)(1 + (code % span));
                Metadata.startOffset2 = (ushort)(1 + ((code >> 16) % span));
            }
            ReserveEntry(ref entry, epoch);
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine($"CurrentEpoch: {CurrentEpoch}, SafeToReclaimEpoch: {SafeToReclaimEpoch}");

            var wc = waiterCount;
            bool disposed = (wc & kDisposedFlag) != 0;
            sb.AppendLine($"Waiters: {wc & ~kDisposedFlag}, Disposed: {disposed}");

            // Active epoch table entries
            sb.Append("Threads: [");
            bool first = true;
            for (int i = 1; i <= kTableSize; i++)
            {
                var e = *(tableAligned + i);
                if (e.threadId != 0)
                {
                    if (!first) sb.Append(", ");
                    sb.Append($"tid={e.threadId} epoch={e.localCurrentEpoch}");
                    first = false;
                }
            }
            sb.AppendLine(first ? "none]" : "]");

            // Drain list entries
            sb.Append("DrainList: [");
            first = true;
            for (int i = 0; i < kDrainListSize; i++)
            {
                var d = drainList[i];
                if (d.epoch != long.MaxValue)
                {
                    if (!first) sb.Append(", ");
                    sb.Append($"epoch={d.epoch} action={(d.action is null ? "null" : d.action.Method.Name)}");
                    first = false;
                }
            }
            sb.Append(first ? "none]" : "]");

            return sb.ToString();
        }

        #region User-word API

        /// <summary>
        /// Number of entries in the epoch table.
        /// </summary>
        public int EntryCount => kTableSize;

        /// <summary>
        /// Claim a per-thread user-word slot. Returns the word index to pass to
        /// <see cref="ThisThreadUserWord(int)"/> and <see cref="GetMinUserWord(int)"/>.
        /// The column across all entries is initialized to <paramref name="initialValue"/>.
        /// After allocation, the application owns the slot contents — LightEpoch does not
        /// automatically reset slots on epoch Acquire/Release. Throws if all
        /// <see cref="MaxUserWords"/> slots are already claimed.
        /// </summary>
        /// <param name="initialValue">Value written to every entry's slot at allocation time.</param>
        /// <returns>Word index in the range <c>[0, <see cref="MaxUserWords"/>)</c>.</returns>
        public int AllocateUserWord(long initialValue)
        {
            while (true)
            {
                var mask = Volatile.Read(ref userWordMask);
                int idx = BitOperations.TrailingZeroCount(~mask);
                if (idx >= MaxUserWords)
                    throw new InvalidOperationException($"All {MaxUserWords} LightEpoch user-word slots are claimed.");

                // CAS to claim the slot. Only the winner proceeds to initialize.
                var newMask = mask | (1 << idx);
                if (Interlocked.CompareExchange(ref userWordMask, newMask, mask) != mask)
                    continue; // another thread modified the mask; retry

                // We exclusively own this slot — initialize the column across all entries.
                for (int i = 1; i <= kTableSize; i++)
                    Volatile.Write(ref UserWordRef(i, idx), initialValue);

                return idx;
            }
        }

        /// <summary>
        /// Release a previously claimed user-word slot. Caller is responsible for ensuring that no
        /// producer thread still holds or can still issue writes to the slot (e.g., by calling this
        /// only after subsystem quiescence / Dispose).
        /// </summary>
        public void ReleaseUserWord(int wordIndex)
        {
            if ((uint)wordIndex >= MaxUserWords)
                throw new ArgumentOutOfRangeException(nameof(wordIndex));
            while (true)
            {
                var mask = Volatile.Read(ref userWordMask);
                var newMask = mask & ~(1 << wordIndex);
                if (Interlocked.CompareExchange(ref userWordMask, newMask, mask) == mask)
                    return;
            }
        }

        /// <summary>
        /// Get a ref to the current thread's user-word slot. Caller MUST be inside epoch protection
        /// (<see cref="Resume"/> / before <see cref="Suspend"/>). Returns the same cache line that is
        /// already hot due to epoch Resume, so writes are essentially free.
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public ref long ThisThreadUserWord(int wordIndex)
        {
            Debug.Assert((uint)wordIndex < MaxUserWords, "Invalid user-word index");
            Debug.Assert(ThisInstanceProtected(), "ThisThreadUserWord must be called while epoch is protected");
            int entryIndex = Metadata.Entries.GetRef(instanceId);
            return ref UserWordRef(entryIndex, wordIndex);
        }

        /// <summary>
        /// Compute the minimum value of the user-word at <paramref name="wordIndex"/> across all epoch
        /// table entries, using a direct unsafe pointer walk.
        /// </summary>
        /// <param name="wordIndex">User-word slot index (0-based).</param>
        /// <returns>The minimum value observed across all entries.</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public long GetMinUserWord(int wordIndex)
        {
            Debug.Assert((uint)wordIndex < MaxUserWords, "Invalid user-word index");

            // Derive the base address from the actual Entry field layout via UserWordRef,
            // rather than hardcoding byte offsets. Entries occupy indices 1..kTableSize
            // (index 0 is kInvalidIndex and unused). Stride between entries is kCacheLineBytes.
            long min = long.MaxValue;
            byte* basePtr = (byte*)Unsafe.AsPointer(ref UserWordRef(1, wordIndex));
            int stride = kCacheLineBytes;
            int count = kTableSize;

            for (int i = 0; i < count; i++)
            {
                long v = Volatile.Read(ref Unsafe.AsRef<long>(basePtr + (long)i * stride));
                if (v < min) min = v;
            }
            return min;
        }

        /// <summary>
        /// Get a ref to the user word at <paramref name="wordIndex"/> for entry <paramref name="entryIndex"/>.
        /// </summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        ref long UserWordRef(int entryIndex, int wordIndex) => ref Unsafe.Add(ref (*(tableAligned + entryIndex)).userWord0, wordIndex);

        #endregion

        /// <summary>
        /// Epoch table entry (cache line size).
        /// Existing epoch fields occupy the first 16 bytes (localCurrentEpoch + threadId + 4 bytes padding).
        /// The remaining 48 bytes host <see cref="MaxUserWords"/> general-purpose per-thread <see cref="long"/> slots that
        /// subsystems can claim via <see cref="AllocateUserWord(long)"/>. This reuses the cache line that is already
        /// hot from epoch Resume/Suspend, so user-word access is essentially free compared to touching a separate
        /// data structure.
        /// </summary>
        [StructLayout(LayoutKind.Explicit, Size = kCacheLineBytes)]
        struct Entry
        {
            /// <summary>
            /// Thread-local value of epoch
            /// </summary>
            [FieldOffset(0)]
            public long localCurrentEpoch;

            /// <summary>
            /// ID of thread associated with this entry.
            /// </summary>
            [FieldOffset(8)]
            public int threadId;

            /// <summary>
            /// First user-word slot. Remaining <see cref="MaxUserWords"/> - 1 slots are contiguous after this
            /// field at 8-byte stride. Access via <c>Unsafe.Add(ref userWord0, wordIndex)</c>.
            /// </summary>
            [FieldOffset(16)]
            public long userWord0;

            [FieldOffset(24)]
            public long userWord1;

            [FieldOffset(32)]
            public long userWord2;

            [FieldOffset(40)]
            public long userWord3;

            [FieldOffset(48)]
            public long userWord4;

            [FieldOffset(56)]
            public long userWord5;

            public override string ToString() => $"lce = {localCurrentEpoch}, tid = {threadId}";
        }

        /// <summary>
        /// Pair of epoch and action to be executed
        /// </summary>
        struct EpochActionPair
        {
            public long epoch;
            public Action action;

            public override readonly string ToString() => $"epoch = {epoch}, action = {(action is null ? "n/a" : action.Method.ToString())}";
        }
    }
}