using System;
using BenchmarkDotNet.Attributes;
using Tsavorite.core;

namespace LightEpoch.Bench
{
    /// <summary>
    /// Cost of the epoch ENTER/EXIT hot path (Resume + Suspend) for each variant.
    ///
    /// This is the read-mostly path taken on every protected operation, so its
    /// per-call cost is what a fix "charges" the common case:
    ///   * baseline    — plain announce store, no fence (INCORRECT on ARM64).
    ///   * fullbarrier — announce store + Interlocked.MemoryBarrier (dmb ish on ARM64).
    ///   * interlocked — announce via Interlocked.Exchange (seq-cst RMW).
    ///   * asymmetric  — plain announce store, no fence: pays NOTHING here
    ///                   (its cost is moved entirely to the reclaimer, below).
    /// </summary>
    [MemoryDiagnoser]
    public class EnterExitBenchmarks
    {
        Tsavorite.core.LightEpoch baseline;
        FixedLightEpoch full;
        FixedLightEpochWithInterlockedExchange interlocked;
        FixedLightEpochAsymmetricBarrier asymmetric;

        [GlobalSetup]
        public void Setup()
        {
            baseline = new Tsavorite.core.LightEpoch();
            full = new FixedLightEpoch();
            interlocked = new FixedLightEpochWithInterlockedExchange();
            asymmetric = new FixedLightEpochAsymmetricBarrier();
        }

        [Benchmark(Baseline = true, Description = "baseline (no fence)")]
        public void Baseline() { baseline.Resume(); baseline.Suspend(); }

        [Benchmark(Description = "full-barrier")]
        public void FullBarrier() { full.Resume(); full.Suspend(); }

        [Benchmark(Description = "interlocked-exchange")]
        public void InterlockedExchange() { interlocked.Resume(); interlocked.Suspend(); }

        [Benchmark(Description = "asymmetric (reader side)")]
        public void Asymmetric() { asymmetric.Resume(); asymmetric.Suspend(); }
    }

    /// <summary>
    /// Cost of a RECLAIM (BumpCurrentEpoch, which runs the safe-epoch scan).
    ///
    /// This is where the asymmetric variant pays its price: it issues a
    /// process-wide barrier (FlushProcessWriteBuffers / membarrier) before the
    /// scan, so this path is far more expensive than the others — but reclaim is
    /// rare and batched, whereas enter/exit is on every protected operation.
    /// The full-barrier and interlocked variants add nothing to reclaim; the
    /// baseline is the (incorrect) floor.
    /// </summary>
    [MemoryDiagnoser]
    public class ReclaimBenchmarks
    {
        static readonly Action NoOp = static () => { };

        Tsavorite.core.LightEpoch baseline;
        FixedLightEpoch full;
        FixedLightEpochWithInterlockedExchange interlocked;
        FixedLightEpochAsymmetricBarrier asymmetric;

        [GlobalSetup]
        public void Setup()
        {
            baseline = new Tsavorite.core.LightEpoch();
            full = new FixedLightEpoch();
            interlocked = new FixedLightEpochWithInterlockedExchange();
            asymmetric = new FixedLightEpochAsymmetricBarrier();
        }

        [Benchmark(Baseline = true, Description = "baseline (no fence)")]
        public void Baseline() { baseline.Resume(); baseline.BumpCurrentEpoch(NoOp); baseline.Suspend(); }

        [Benchmark(Description = "full-barrier")]
        public void FullBarrier() { full.Resume(); full.BumpCurrentEpoch(NoOp); full.Suspend(); }

        [Benchmark(Description = "interlocked-exchange")]
        public void InterlockedExchange() { interlocked.Resume(); interlocked.BumpCurrentEpoch(NoOp); interlocked.Suspend(); }

        [Benchmark(Description = "asymmetric (reclaimer side)")]
        public void Asymmetric() { asymmetric.Resume(); asymmetric.BumpCurrentEpoch(NoOp); asymmetric.Suspend(); }
    }
}
