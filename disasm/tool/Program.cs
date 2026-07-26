// Forces the JIT to compile the epoch announce-path methods so that
// DOTNET_JitDisasm dumps their native code. The method of interest is
// ProtectAndDrain(), a real (non-inlined) method whose first statement is the
// announce store `localCurrentEpoch = CurrentEpoch` -- the exact site where the
// missing StoreLoad fence lives. Comparing the four variants' ProtectAndDrain
// disassembly shows precisely which instruction each fix adds.
//
// Run with (see capture.sh):
//   DOTNET_TieredCompilation=0   -> compile straight to FullOpts (no tier-0 noise)
//   DOTNET_JitDisasm=ProtectAndDrain
//   DOTNET_JitDisasmDiffable=1   -> stable, address-free output

using System;
using Tsavorite.core;

namespace DisasmDump
{
    internal static class Program
    {
        static void Main()
        {
            // Each variant: protect the thread, invoke the announce-path method
            // (ProtectAndDrain), retire once, then release. Invoking each method
            // once is enough to trigger its JIT compilation and disassembly.
            Exercise_Baseline();
            Exercise_FullBarrier();
            Exercise_Interlocked();
            Exercise_Asymmetric();
        }

        static void Exercise_Baseline()
        {
            var e = new LightEpoch();
            e.Resume();
            Action protectAndDrain = e.ProtectAndDrain;
            protectAndDrain();
            e.BumpCurrentEpoch(Nop);
            e.Suspend();
        }

        static void Exercise_FullBarrier()
        {
            var e = new FixedLightEpoch();
            e.Resume();
            Action protectAndDrain = e.ProtectAndDrain;
            protectAndDrain();
            e.BumpCurrentEpoch(Nop);
            e.Suspend();
        }

        static void Exercise_Interlocked()
        {
            var e = new FixedLightEpochWithInterlockedExchange();
            e.Resume();
            Action protectAndDrain = e.ProtectAndDrain;
            protectAndDrain();
            e.BumpCurrentEpoch(Nop);
            e.Suspend();
        }

        static void Exercise_Asymmetric()
        {
            var e = new FixedLightEpochAsymmetricBarrier();
            e.Resume();
            Action protectAndDrain = e.ProtectAndDrain;
            protectAndDrain();
            e.BumpCurrentEpoch(Nop);
            e.Suspend();
        }

        static void Nop() { }
    }
}
