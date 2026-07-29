using System;

namespace LightEpoch.Core
{
    /// <summary>
    /// Uniform surface over the epoch implementations for the repro harnesses.
    /// Implemented by <c>struct</c>s so a generic caller
    /// constrained to <c>struct, IEpochOps</c> is JIT-specialized and fully
    /// devirtualized — the emitted code is identical to calling the concrete
    /// epoch class directly, so the harness does not perturb the race it studies.
    /// </summary>
    public interface IEpochOps
    {
        public void Resume();
        public void Refresh();
        public void Suspend();
        public void BumpCurrentEpoch(Action onDrain);
        public int EntryIndex { get; }
        public void SetTestSlotSpace(ushort slots);
        public long ReadAllEntries();
        public string Name { get; }

        /// <summary>Epoch this thread currently announces, for the tripwire diagnostic.</summary>
        public long ThisThreadAnnouncedEpoch { get; }

        /// <summary>Global epoch counter, for the tripwire diagnostic.</summary>
        public long CurrentEpoch { get; }

        /// <summary>Highest epoch the implementation believes is safe to reclaim.</summary>
        public long SafeToReclaimEpoch { get; }
    }

    public readonly struct BaselineOps : IEpochOps
    {
        private readonly LightEpoch e;
        public BaselineOps() { e = new LightEpoch(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public int EntryIndex => e.ThisThreadEntry();
        public void SetTestSlotSpace(ushort slots) => LightEpoch.TestSlotSpace = slots;
        public long ReadAllEntries() => e.ReadAllEntries();
        public string Name => "baseline (LightEpoch, no fence)";
        public long ThisThreadAnnouncedEpoch => e.ThisThreadAnnouncedEpoch();
        public long CurrentEpoch => e.CurrentEpoch;
        public long SafeToReclaimEpoch => e.SafeToReclaimEpoch;
    }

    public readonly struct FullBarrierOps : IEpochOps
    {
        private readonly FixedLightEpochWithMemoryBarrier e;
        public FullBarrierOps() { e = new FixedLightEpochWithMemoryBarrier(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public int EntryIndex => e.ThisThreadEntry();
        public void SetTestSlotSpace(ushort slots) => FixedLightEpochWithMemoryBarrier.TestSlotSpace = slots;
        public long ReadAllEntries() => e.ReadAllEntries();
        public string Name => "full-barrier (FixedLightEpochWithMemoryBarrier)";
        public long ThisThreadAnnouncedEpoch => e.ThisThreadAnnouncedEpoch();
        public long CurrentEpoch => e.CurrentEpoch;
        public long SafeToReclaimEpoch => e.SafeToReclaimEpoch;
    }

    public readonly struct CasAnnounceOps : IEpochOps
    {
        private readonly FixedLightEpochWithCasAnnounce e;
        public CasAnnounceOps() { e = new FixedLightEpochWithCasAnnounce(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public int EntryIndex => e.ThisThreadEntry();
        public void SetTestSlotSpace(ushort slots) => FixedLightEpochWithCasAnnounce.TestSlotSpace = slots;
        public long ReadAllEntries() => e.ReadAllEntries();
        public string Name => "cas-announce (FixedLightEpochWithCasAnnounce)";
        public long ThisThreadAnnouncedEpoch => e.ThisThreadAnnouncedEpoch();
        public long CurrentEpoch => e.CurrentEpoch;
        public long SafeToReclaimEpoch => e.SafeToReclaimEpoch;
    }
}
