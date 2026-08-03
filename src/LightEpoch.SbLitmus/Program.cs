using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

// Hardware litmus for the LightEpoch lost-wakeup pair (U2), run on x86-64.
//
//   Release():          publish "slot free"                then load waiterCount
//   ReserveEntryWait(): Interlocked.Increment(waiterCount)  then re-probe the slot
//
// The lost wakeup is both loads returning stale values in the same trial: the
// releaser sees no waiter and does not signal, while the waiter sees the slot
// still occupied and goes to sleep on a slot that is free.
//
// The four arms differ ONLY in how the releaser publishes. `plain` and
// `volatile` are the spellings under test; `barrier` and `exchange` are
// positive controls that must drive the count to zero. Their zero is what makes
// a nonzero count for the other two meaningful rather than an artifact of the
// harness.

internal static class Program
{
    // Padded so the two locations never share a cache line.
    private static readonly int[] pad = new int[256];

    private static int releaserSaw, waiterSaw;
    private static int phase, done;

    private const int SlotIdx = 32;
    private const int WaitIdx = 96;

    private enum Mode { Plain, Volatile, Barrier, Exchange }

    private static void Main(string[] args)
    {
        long trials = args.Length > 0 ? long.Parse(args[0]) : 2_000_000;
        Console.WriteLine($"hardware litmus: LightEpoch lost wakeup (U2)  [{RuntimeInformation.ProcessArchitecture}]");
        Console.WriteLine($"cores={Environment.ProcessorCount}  trials={trials:N0} per arm");
        Console.WriteLine();
        Console.WriteLine($"{"arm",-9} {"how the releaser publishes",-40} {"lost wakeups",13} {"rate",11}");
        Console.WriteLine(new string('-', 78));

        foreach (var mode in new[] { Mode.Plain, Mode.Volatile, Mode.Barrier, Mode.Exchange,
                                     Mode.Plain, Mode.Volatile, Mode.Barrier, Mode.Exchange })
        {
            long hits = Run(mode, trials);
            string label = mode switch
            {
                Mode.Plain    => "slot = 0                    (production)",
                Mode.Volatile => "Volatile.Write(ref slot, 0)",
                Mode.Barrier  => "slot = 0; MemoryBarrier()      [control]",
                Mode.Exchange => "Interlocked.Exchange(ref slot, 0) [ctrl]",
                _ => "?"
            };
            Console.WriteLine($"{mode,-9} {label,-40} {hits,13:N0} {(double)hits / trials,11:P5}");
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static long Run(Mode mode, long trials)
    {
        long hits = 0;
        var p = pad;
        Volatile.Write(ref phase, 0);
        Volatile.Write(ref done, 0);

        var releaser = new Thread(() =>
        {
            for (long t = 0; t < trials; t++)
            {
                while (Volatile.Read(ref phase) != t + 1) Thread.SpinWait(1);

                switch (mode)
                {
                    case Mode.Plain:    p[SlotIdx] = 0; break;
                    case Mode.Volatile: Volatile.Write(ref p[SlotIdx], 0); break;
                    case Mode.Barrier:  p[SlotIdx] = 0; Thread.MemoryBarrier(); break;
                    case Mode.Exchange: Interlocked.Exchange(ref p[SlotIdx], 0); break;
                }

                releaserSaw = Volatile.Read(ref p[WaitIdx]);   // the volatile read in Release()

                Interlocked.Increment(ref done);
            }
        }) { IsBackground = true };

        var waiter = new Thread(() =>
        {
            for (long t = 0; t < trials; t++)
            {
                while (Volatile.Read(ref phase) != t + 1) Thread.SpinWait(1);

                Interlocked.Increment(ref p[WaitIdx]);          // register as a waiter
                waiterSaw = Volatile.Read(ref p[SlotIdx]);      // re-probe before sleeping

                Interlocked.Increment(ref done);
            }
        }) { IsBackground = true };

        releaser.Start();
        waiter.Start();

        for (long t = 0; t < trials; t++)
        {
            p[SlotIdx] = 1;
            Volatile.Write(ref p[WaitIdx], 0);
            releaserSaw = -1;
            waiterSaw = -1;
            Volatile.Write(ref done, 0);

            Volatile.Write(ref phase, (int)(t + 1));           // release both threads

            while (Volatile.Read(ref done) != 2) Thread.SpinWait(1);

            if (releaserSaw == 0 && waiterSaw == 1) hits++;
        }

        releaser.Join(10000);
        waiter.Join(10000);
        return hits;
    }
}
