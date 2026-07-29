using System;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Environments;
using BenchmarkDotNet.Jobs;
using BenchmarkDotNet.Running;
using LightEpoch.Core;

namespace LightEpoch.Micro
{
    /// <summary>
    /// Per-operation cost of the epoch protocol itself, with no storage engine around it.
    ///
    /// The point of this harness is to answer one question: does the CAS-carries-epoch fix
    /// change the cost of the sequence Tsavorite actually runs on every operation? BDN's
    /// end-to-end Garnet numbers move by more than the epoch protocol costs in total, so a
    /// regression there cannot be attributed without measuring the protocol in isolation.
    ///
    /// All three implementations are benchmarked in the SAME process from the SAME assembly,
    /// so JIT, GC, and layout are held constant across variants.
    /// </summary>
    [MemoryDiagnoser]
    public class EpochPath<TOps> where TOps : struct, IEpochOps
    {
        private TOps ops;
        private long sink;

        [GlobalSetup]
        public void Setup()
        {
            ops = new TOps();
            sink = 0;

            // Touch the slot once so the per-thread startOffset/threadId metadata is warm and
            // the measured iterations exercise the steady-state path, not first-touch.
            ops.Resume();
            ops.Refresh();
            ops.Suspend();
        }

        /// <summary>
        /// The full sequence Tsavorite runs to enter and leave a protected region:
        /// Acquire -> ProtectAndDrain -> critical section -> Release.
        /// This is the path the fix changes, and the one that matters.
        /// </summary>
        [Benchmark(Baseline = true, Description = "Resume+Refresh+CS+Suspend")]
        public long ResumeRefreshSuspend()
        {
            ops.Resume();
            ops.Refresh();
            var v = CriticalSection();
            ops.Suspend();
            return v;
        }

        /// <summary>
        /// Isolates the 0 -> epoch -> 0 slot transition, which is the only part the fix
        /// restructures. If a regression exists, it must show up here.
        /// </summary>
        [Benchmark(Description = "Resume+Suspend only")]
        public long ResumeSuspend()
        {
            ops.Resume();
            var v = CriticalSection();
            ops.Suspend();
            return v;
        }

        /// <summary>
        /// Control: Refresh inside a long-lived protected region. The fix does not touch this
        /// path, so any difference between implementations here is measurement noise and
        /// calibrates how much of a delta in the other rows to believe.
        /// </summary>
        [Benchmark(Description = "Refresh only (control)")]
        public long RefreshOnly()
        {
            ops.Resume();
            for (var i = 0; i < 8; i++)
                ops.Refresh();

            var v = CriticalSection();
            ops.Suspend();
            return v;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private long CriticalSection()
        {
            // Stands in for a record dereference: cheap, but a real dependent load so the
            // protected region is not empty and cannot be elided.
            return Volatile.Read(ref sink);
        }
    }

    public static class Program
    {
        public static void Main(string[] args)
        {
            if (args.Contains("--contended"))
            {
                Contended.Run(args);
                return;
            }

            if (args.Contains("--asm"))
            {
                AsmProbe.Run();
                return;
            }

            var config = ManualConfig.CreateMinimumViable()
                .AddJob(Job.Default
                    .WithRuntime(CoreRuntime.Core10_0)
                    .WithGcServer(true)
                    .WithEnvironmentVariables(new EnvironmentVariable("DOTNET_TieredPGO", "0"))
                    .WithId(".NET 10"))
                .AddDiagnoser(BenchmarkDotNet.Diagnosers.MemoryDiagnoser.Default);

            BenchmarkSwitcher.FromTypes(new[]
            {
                typeof(EpochPath<BaselineOps>),
                typeof(EpochPath<FullBarrierOps>),
                typeof(EpochPath<CasAnnounceOps>),
            }).Run(args, config);
        }
    }

    /// <summary>
    /// Throughput under contention. The two designs CAS different words, so their behaviour
    /// when several threads race for slots is not necessarily the same as their uncontended
    /// cost, and BDN's single-threaded numbers cannot show that.
    /// </summary>
    public static class Contended
    {
        public static void Run(string[] args)
        {
            var threads = ArgValue(args, "--threads", Environment.ProcessorCount / 2);
            var seconds = ArgValue(args, "--seconds", 5);

            Console.WriteLine($"contended epoch throughput  threads={threads}  seconds={seconds}  " +
                              $"cores={Environment.ProcessorCount}");
            Console.WriteLine($"cas-announce knobs: acquire={FixedLightEpochWithCasAnnounce.AcquireOrderName}  " +
                              $"refresh={FixedLightEpochWithCasAnnounce.RefreshOrderName}  " +
                              $"release={FixedLightEpochWithCasAnnounce.ReleaseOrderName}  " +
                              $"drain-publish={FixedLightEpochWithCasAnnounce.DrainPublishOrderName}");
            Console.WriteLine();
            Console.WriteLine($"{"impl",-46} {"Mops/s",12} {"ns/op",10}");

            Measure<BaselineOps>(threads, seconds);
            Measure<FullBarrierOps>(threads, seconds);
            Measure<CasAnnounceOps>(threads, seconds);
        }

        private static void Measure<TOps>(int threads, int seconds) where TOps : struct, IEpochOps
        {
            var ops = new TOps();
            var stop = false;
            var counts = new long[threads];
            var ready = new CountdownEvent(threads);
            var go = new ManualResetEventSlim(false);

            var workers = new Thread[threads];
            for (var t = 0; t < threads; t++)
            {
                var id = t;
                workers[t] = new Thread(() =>
                {
                    ready.Signal();
                    go.Wait();

                    long n = 0;
                    while (!Volatile.Read(ref stop))
                    {
                        // Same sequence as the BDN path, batched to keep the stop-flag read
                        // off the measured inner loop.
                        for (var i = 0; i < 64; i++)
                        {
                            ops.Resume();
                            ops.Refresh();
                            ops.Suspend();
                        }
                        n += 64;
                    }
                    counts[id] = n;
                })
                { IsBackground = true };
                workers[t].Start();
            }

            ready.Wait();
            var sw = Stopwatch.StartNew();
            go.Set();
            Thread.Sleep(seconds * 1000);
            Volatile.Write(ref stop, true);
            foreach (var w in workers)
                w.Join();
            sw.Stop();

            var total = counts.Sum();
            var mops = total / sw.Elapsed.TotalSeconds / 1e6;
            var nsPerOp = sw.Elapsed.TotalSeconds * 1e9 / total * threads;
            Console.WriteLine($"{ops.Name,-46} {mops,12:F2} {nsPerOp,10:F1}");
        }

        private static int ArgValue(string[] args, string name, int fallback)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length && int.TryParse(args[i + 1], out var v) ? v : fallback;
        }
    }

    /// <summary>
    /// Drives each implementation's hot path enough to force tier-1 JIT, so that running under
    /// DOTNET_JitDisasm dumps optimized code for the methods the fix touches. Used to count
    /// lock-prefixed instructions per variant rather than reasoning about them on paper.
    /// </summary>
    public static class AsmProbe
    {
        public static void Run()
        {
            Console.WriteLine("warming baseline...");
            Warm<BaselineOps>();
            Console.WriteLine("warming full-barrier...");
            Warm<FullBarrierOps>();
            Console.WriteLine("warming cas-announce...");
            Warm<CasAnnounceOps>();
            Console.WriteLine("warming store spellings...");
            WarmStoreSpellings();
            Console.WriteLine("done");
        }

        static long plainSlot, volatileSlot;

        /// <summary>
        /// Isolates the two spellings of the drain-list publish store (U3) so their emitted code can
        /// be compared directly. The contended harness never calls <c>BumpCurrentEpoch(Action)</c>,
        /// so it cannot price that site; this can.
        /// </summary>
        static void WarmStoreSpellings()
        {
            for (var i = 0; i < 2_000_000; i++)
            {
                PublishPlain(i);
                PublishVolatile(i);
            }

            Thread.Sleep(400);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        static void PublishPlain(long v) => plainSlot = v;

        [MethodImpl(MethodImplOptions.NoInlining)]
        static void PublishVolatile(long v) => Volatile.Write(ref volatileSlot, v);

        private static void Warm<TOps>() where TOps : struct, IEpochOps
        {
            var ops = new TOps();
            long acc = 0;
            for (var i = 0; i < 2_000_000; i++)
            {
                ops.Resume();
                ops.Refresh();
                acc += i;
                ops.Suspend();
            }

            // Re-JIT at tier 1 takes a moment to publish; give it a window before the next impl.
            Thread.Sleep(400);
            GC.KeepAlive(acc);
        }
    }
}
