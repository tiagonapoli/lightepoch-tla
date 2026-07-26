using System;

namespace Tsavorite.core
{
    /// <summary>
    /// Uniform surface over the epoch implementations for the litmus harness and
    /// the benchmarks. Implemented by <c>struct</c>s so a generic caller
    /// constrained to <c>struct, IEpochOps</c> is JIT-specialized and fully
    /// devirtualized — the emitted code is identical to calling the concrete
    /// epoch class directly, so the harness does not perturb the race it studies.
    /// </summary>
    public interface IEpochOps
    {
        void Resume();
        void Refresh();
        void Suspend();
        void BumpCurrentEpoch(Action onDrain);
        string Name { get; }
    }

    public readonly struct BaselineOps : IEpochOps
    {
        readonly LightEpoch e;
        public BaselineOps() { e = new LightEpoch(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "baseline (LightEpoch, no fence)";
    }

    public readonly struct FullBarrierOps : IEpochOps
    {
        readonly FixedLightEpoch e;
        public FullBarrierOps() { e = new FixedLightEpoch(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "full-barrier (FixedLightEpoch)";
    }

    public readonly struct InterlockedExchangeOps : IEpochOps
    {
        readonly FixedLightEpochWithInterlockedExchange e;
        public InterlockedExchangeOps() { e = new FixedLightEpochWithInterlockedExchange(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "interlocked-exchange announce";
    }

    public readonly struct AsymmetricOps : IEpochOps
    {
        readonly FixedLightEpochAsymmetricBarrier e;
        public AsymmetricOps() { e = new FixedLightEpochAsymmetricBarrier(); }
        public void Resume() => e.Resume();
        public void Refresh() => e.ProtectAndDrain();
        public void Suspend() => e.Suspend();
        public void BumpCurrentEpoch(Action onDrain) => e.BumpCurrentEpoch(onDrain);
        public string Name => "asymmetric barrier (reclaimer-side)";
    }
}
