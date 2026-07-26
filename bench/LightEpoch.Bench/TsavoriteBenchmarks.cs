using System;
using BenchmarkDotNet.Attributes;
using Tsavorite.core;

namespace LightEpoch.Bench
{
    /// <summary>
    /// Cost of the epoch enter/exit as Tsavorite's DEFAULT API actually calls it.
    ///
    /// A BasicContext Read/Upsert/RMW wraps every operation in
    ///   UnsafeResumeThread()  = epoch.Resume()  (Acquire: slot-reservation CAS + announce)
    ///                           + InternalRefresh() -> epoch.ProtectAndDrain() (a 2nd announce + drain)
    ///   ... the operation ...
    ///   UnsafeSuspendThread() = epoch.Suspend() (Release).
    ///
    /// So this benchmark's body — Resume(); ProtectAndDrain(); Suspend() — is the
    /// exact per-operation epoch cost the shipped default API pays, for each variant:
    ///   * baseline    — two plain announce stores, no fence (INCORRECT on ARM64).
    ///   * fullbarrier — each announce followed by Interlocked.MemoryBarrier (dmb ish).
    ///   * interlocked — each announce via Interlocked.Exchange (seq-cst RMW).
    ///   * asymmetric  — plain announce stores (pays its cost only on reclaim).
    ///
    /// Compare against <see cref="EnterExitBenchmarks"/> (bare Resume/Suspend, no
    /// Refresh) to see what the extra InternalRefresh announce costs, and against
    /// <see cref="AmortizedRefreshBenchmarks"/> to see what per-op acquire/release
    /// costs over the cheap UnsafeContext idiom. See the top-level README, section 8.
    /// </summary>
    [MemoryDiagnoser]
    public class TsavoriteBenchmarks
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
        public void Baseline() { baseline.Resume(); baseline.ProtectAndDrain(); baseline.Suspend(); }

        [Benchmark(Description = "full-barrier")]
        public void FullBarrier() { full.Resume(); full.ProtectAndDrain(); full.Suspend(); }

        [Benchmark(Description = "interlocked-exchange")]
        public void InterlockedExchange() { interlocked.Resume(); interlocked.ProtectAndDrain(); interlocked.Suspend(); }

        [Benchmark(Description = "asymmetric (reader side)")]
        public void Asymmetric() { asymmetric.Resume(); asymmetric.ProtectAndDrain(); asymmetric.Suspend(); }
    }

    /// <summary>
    /// Cost of the cheap amortized idiom (UnsafeContext): protect ONCE, then run
    /// many operations that each only re-announce via ProtectAndDrain() (Refresh),
    /// and release once. The per-operation cost here is a single ProtectAndDrain()
    /// with NO slot-reservation CAS and NO release — the thread stays protected
    /// (Resume in GlobalSetup, Suspend in GlobalCleanup, both on the benchmark
    /// thread).
    ///
    /// The gap between this and <see cref="TsavoriteBenchmarks"/> is exactly the
    /// acquire/release machinery the default BasicContext API pays on every op
    /// (see README section 8.1 vs 8.2). For the fixed variants it also isolates
    /// the announce fence on the most "naked" announce (no adjacent locked RMW).
    /// </summary>
    [MemoryDiagnoser]
    public class AmortizedRefreshBenchmarks
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

            baseline.Resume();
            full.Resume();
            interlocked.Resume();
            asymmetric.Resume();
        }

        [GlobalCleanup]
        public void Cleanup()
        {
            baseline.Suspend();
            full.Suspend();
            interlocked.Suspend();
            asymmetric.Suspend();
        }

        [Benchmark(Baseline = true, Description = "baseline (no fence)")]
        public void Baseline() { baseline.ProtectAndDrain(); }

        [Benchmark(Description = "full-barrier")]
        public void FullBarrier() { full.ProtectAndDrain(); }

        [Benchmark(Description = "interlocked-exchange")]
        public void InterlockedExchange() { interlocked.ProtectAndDrain(); }

        [Benchmark(Description = "asymmetric (reader side)")]
        public void Asymmetric() { asymmetric.ProtectAndDrain(); }
    }
}
