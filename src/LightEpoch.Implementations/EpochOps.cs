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
        public string Name { get; }
    }

    public readonly struct BaselineOps : IEpochOps
    {
        private readonly LightEpoch e;
        public BaselineOps() { e = new LightEpoch(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "baseline (LightEpoch, no fence)";
    }

    public readonly struct FullBarrierOps : IEpochOps
    {
        private readonly FixedLightEpochWithMemoryBarrier e;
        public FullBarrierOps() { e = new FixedLightEpochWithMemoryBarrier(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "full-barrier (FixedLightEpochWithMemoryBarrier)";
    }
}
