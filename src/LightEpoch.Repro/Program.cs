// LightEpoch enter-path litmus — minimal and self-judging.
//
// The claim under test (one sentence):
//   A reader that has completed Resume() (it is PROTECTED) and then observed a
//   shared object as still-linked may dereference it — but on a weak-memory CPU
//   (ARM64) the epoch reclamation machinery can concurrently free that object,
//   because the epoch "announce" store (localCurrentEpoch = CurrentEpoch) has no
//   StoreLoad fence, so the reclaimer's safe-epoch scan can miss the reader.
//
// This is the classic Store-Buffer (SB) litmus mapped onto the two real ops:
//   Reader     : STORE announce (Resume)      ; then LOAD the object pointer.
//   Reclaimer  : STORE unlink (curPage = 0)   ; then LOAD the reader slot (scan,
//                inside BumpCurrentEpoch, ordered by its Interlocked.Increment).
// The forbidden-if-correct outcome is BOTH loads missing the other's store:
//   reader still sees the object linked (derefs it)  AND
//   reclaimer misses the announce (frees it)         -> reader faults.
// The reclaimer side is ALREADY fenced (the Interlocked in BumpCurrentEpoch
// orders its unlink before its scan). The ONLY missing fence is on the reader's
// announce. So one StoreLoad fence after the announce closes the litmus.
//
// Why this is self-judging (the harness makes no reclamation decision):
//   It hands each retired page to the real public API BumpCurrentEpoch(onDrain),
//   and the epoch implementation itself decides — via ComputeNewSafeToReclaimEpoch
//   + Drain — WHEN to invoke onDrain (which unmaps the page). A fault therefore
//   means the epoch freed an object while a protected reader that had seen it
//   linked was still reading it.
//
// Expected, per --impl:
//   baseline     : real (unfenced) source     -> hard fault within ~seconds on ARM64, every run.
//   fullbarrier  : StoreLoad fence on announce -> runs indefinitely, no fault.
//   interlocked  : seq-cst RMW announce        -> runs indefinitely, no fault.
//   asymmetric   : reclaimer-side barrier       -> runs indefinitely, no fault.
//   On x86 every mode effectively never faults (incidental fast store-buffer drain).

using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using Tsavorite.core;

namespace LightEpoch.Repro
{
    internal static class Program
    {
        static int Main(string[] args)
        {
            string impl = "baseline";
            string pattern = "bare";
            long rounds = 200_000_000;
            int deref = 20000, readerCore = 1, reclaimerCore = 0;

            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--impl": impl = args[++i].ToLowerInvariant(); break;
                    case "--pattern": pattern = args[++i].ToLowerInvariant(); break;
                    case "--rounds": rounds = long.Parse(args[++i]); break;
                    case "--deref": deref = int.Parse(args[++i]); break;
                    case "--reader-core": readerCore = int.Parse(args[++i]); break;
                    case "--reclaimer-core": reclaimerCore = int.Parse(args[++i]); break;
                    case "-h": case "--help": Usage(); return 0;
                }
            }

            if (pattern != "bare" && pattern != "tsavorite" && pattern != "refresh")
                return FailPattern(pattern);

            Console.WriteLine($"LightEpoch litmus  impl={impl}  pattern={pattern}  rounds={rounds:N0}  deref={deref}");
            Console.WriteLine($"OS={RuntimeInformation.OSDescription.Trim()}  Arch={RuntimeInformation.ProcessArchitecture}  cores(reclaimer={reclaimerCore},reader={readerCore})");

            return impl switch
            {
                "baseline"    => new Litmus<BaselineOps>(rounds, deref, readerCore, reclaimerCore, pattern).Run(),
                "fullbarrier" => new Litmus<FullBarrierOps>(rounds, deref, readerCore, reclaimerCore, pattern).Run(),
                "interlocked" => new Litmus<InterlockedExchangeOps>(rounds, deref, readerCore, reclaimerCore, pattern).Run(),
                "asymmetric"  => new Litmus<AsymmetricOps>(rounds, deref, readerCore, reclaimerCore, pattern).Run(),
                _ => Fail(impl),
            };
        }

        static int Fail(string impl)
        {
            Console.Error.WriteLine($"unknown --impl '{impl}' (want: baseline|fullbarrier|interlocked|asymmetric)");
            return 2;
        }

        static int FailPattern(string pattern)
        {
            Console.Error.WriteLine($"unknown --pattern '{pattern}' (want: bare|tsavorite|refresh)");
            return 2;
        }

        static void Usage() => Console.WriteLine(
            "usage: LightEpoch.Repro --impl <baseline|fullbarrier|interlocked|asymmetric> " +
            "[--pattern <bare|tsavorite|refresh>] [--rounds N] [--deref N] [--reader-core N] [--reclaimer-core N]\n" +
            "  --pattern bare      : Resume() ; read ; Suspend()  per round (exercises the Acquire announce).\n" +
            "  --pattern tsavorite : Resume() ; Refresh() ; read ; Suspend()  per round -- the exact BasicContext\n" +
            "                        UnsafeResumeThread/UnsafeSuspendThread sequence (exercises the ProtectAndDrain announce).\n" +
            "  --pattern refresh   : Resume() once ; { Refresh() ; read } loop ; Suspend() once -- the cheap amortized\n" +
            "                        UnsafeContext idiom (the announce is at its most 'naked', no adjacent locked RMW).\n" +
            "exit 0 = survived (no reclaim-while-protected); nonzero/aborted = fault observed.");
    }

    /// <summary>
    /// Two-sided Store-Buffer litmus over one epoch instance. Generic over the
    /// epoch ops <typeparamref name="TOps"/> (a struct), so the JIT specializes
    /// and devirtualizes every Resume/Suspend/Bump call — the harness adds no
    /// synchronization of its own beyond the barnyard barrier between rounds.
    /// </summary>
    internal sealed unsafe class Litmus<TOps> where TOps : struct, IEpochOps
    {
        const nuint PAGE = 4096;

        TOps ops;
        long curPage;                 // page the reader dereferences this round
        int startCount, startSense, endCount, endSense;
        long sink;
        volatile bool stop;

        readonly long rounds;
        readonly int deref, readerCore, reclaimerCore;
        readonly string pattern;

        public Litmus(long rounds, int deref, int readerCore, int reclaimerCore, string pattern)
        {
            this.rounds = rounds;
            this.deref = deref;
            this.readerCore = readerCore;
            this.reclaimerCore = reclaimerCore;
            this.pattern = pattern;
            ops = new TOps();
        }

        public int Run()
        {
            Console.WriteLine($"ops = {ops.Name}   pattern = {pattern}");

            var reader = new Thread(ReaderLoop) { IsBackground = true, Name = "reader", Priority = ThreadPriority.Highest };
            reader.Start();
            Plat.Pin(reclaimerCore);

            var sw = Stopwatch.StartNew();
            ReclaimerLoop();
            sw.Stop();

            stop = true;
            reader.Join(2000);
            Console.WriteLine($"Completed {rounds:N0} rounds in {sw.Elapsed.TotalSeconds:F1}s with NO fault.  sink={Volatile.Read(ref sink)}");
            return 0;   // reaching here == survived (no reclaim while a protected reader held the page)
        }

        void ReaderLoop()
        {
            Plat.Pin(readerCore);

            if (pattern == "refresh")
            {
                // Cheap amortized UnsafeContext idiom: protect ONCE, then re-announce
                // each operation solely through Refresh() (ProtectAndDrain). The announce
                // is at its most 'naked' here -- no adjacent slot-reservation CAS.
                ops.Resume();
                for (long r = 0; r < rounds && !stop; r++)
                {
                    StartBarrier();
                    ops.Refresh();                    // ProtectAndDrain: re-announce (plain) + drain
                    ReadAndDeref();
                    EndBarrier();
                }
                ops.Suspend();
                return;
            }

            for (long r = 0; r < rounds && !stop; r++)
            {
                StartBarrier();

                ops.Resume();                         // Acquire: slot-reservation CAS + announce store
                if (pattern == "tsavorite")
                    ops.Refresh();                    // InternalRefresh -> ProtectAndDrain: a 2nd (plain) announce + drain
                ReadAndDeref();
                ops.Suspend();

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void ReadAndDeref()
        {
            long p = curPage;                         // LOAD object pointer (plain): old page or 0 (unlinked)
            if (p != 0)                               // only dereference what looked still-linked
            {
                long* pg = (long*)p;
                long acc = 0;
                for (int k = 0; k < deref; k++)
                    acc += pg[k & 511];               // faults here if the epoch freed the page
                sink += acc;
            }
        }

        void ReclaimerLoop()
        {
            for (long r = 0; r < rounds; r++)
            {
                byte* page = Plat.Alloc(PAGE);
                for (int j = 0; j < 512; j++) ((long*)page)[j] = j;
                Volatile.Write(ref curPage, (long)page);   // link/publish the object

                StartBarrier();

                curPage = 0;                          // STORE unlink (plain, like removing from a structure)

                // Hand the retired page to the epoch. The epoch alone decides, via its own
                // ComputeNewSafeToReclaimEpoch + Drain, when to invoke the unmap. Its
                // Interlocked.Increment orders this unlink before the safe-epoch scan.
                long pg = (long)page;
                ops.BumpCurrentEpoch(() => Plat.Free((byte*)pg, PAGE));

                EndBarrier();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void StartBarrier()
        {
            int s = Volatile.Read(ref startSense);
            if (Interlocked.Increment(ref startCount) == 2) { startCount = 0; Volatile.Write(ref startSense, s ^ 1); }
            else { var w = new SpinWait(); while (Volatile.Read(ref startSense) == s) w.SpinOnce(-1); }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void EndBarrier()
        {
            int s = Volatile.Read(ref endSense);
            if (Interlocked.Increment(ref endCount) == 2) { endCount = 0; Volatile.Write(ref endSense, s ^ 1); }
            else { var w = new SpinWait(); while (Volatile.Read(ref endSense) == s) w.SpinOnce(-1); }
        }
    }
}
