using System.Threading;
using System.Runtime.CompilerServices;
using BenchmarkDotNet.Attributes;

namespace LightEpoch.Bench
{
    // Isolates the cost of the announce fence with ZERO type/layout confound:
    // the SAME type, the SAME store+load shape, differing ONLY by whether an
    // Interlocked.MemoryBarrier() (x86: `lock or [rsp],0`) sits between them.
    // This is the exact StoreLoad shape of the epoch announce.
    public class FenceMicroBenchmarks
    {
        int slot;
        int sink;

        [Benchmark(Baseline = true, Description = "store; load (no fence)")]
        [MethodImpl(MethodImplOptions.NoInlining)]
        public void PlainStoreLoad() { slot = 1; sink = slot; }

        [Benchmark(Description = "store; MemoryBarrier; load")]
        [MethodImpl(MethodImplOptions.NoInlining)]
        public void StoreBarrierLoad() { slot = 1; Interlocked.MemoryBarrier(); sink = slot; }
    }
}
