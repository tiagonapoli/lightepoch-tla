# LightEpoch memory-ordering study: missing StoreLoad fence

This repository is a self-contained, reproducible study of a **memory-ordering
bug in an epoch-based safe-memory-reclamation scheme**. The epoch *enter* (announce) path publishes a thread's current
epoch with a **plain store and no StoreLoad fence**. This lets the reclaimer's
"safe-to-reclaim" scan miss a live reader and free memory that the reader is about
to dereference. This happens reliably on a weakly-ordered CPU (**ARM64**), and more
rarely — but still demonstrably — on **x86-64**.

The bug is demonstrated in two complementary ways:

1. **A running C# repro** (`src/`) that links the epoch implementation
   unmodified and lets the epoch machinery *itself* free the object. On real
   Windows ARM64 the buggy build faults within seconds, while the fixed builds run
   indefinitely. On x86-64 the buggy build also reproduces, while the build with the
   memory barrier runs without violations
   (see [Results](#results-reproduced-on-arm64-and-x86-64) below).
2. **Formal TLA+ models** (`tla/`) of the x86-TSO (total store order) memory model, and
   of the epoch algorithm with each candidate fix. TLC exhaustively finds the
   use-after-free in the baseline and proves each fix closes it.

## Contents

* [Overview: where the barrier is missing](#overview-where-the-barrier-is-missing)
  * [The reader side — announces with a plain store](#the-reader-side--announces-with-a-plain-store)
  * [The reclaimer side — scans without synchronizing with the reader](#the-reclaimer-side--scans-without-synchronizing-with-the-reader)
* [Results: reproduced on ARM64 and x86-64](#results-reproduced-on-arm64-and-x86-64)
  * [Hardware used for tests](#hardware-used-for-tests)
  * [ARM64 — hardware access violation (`0xC0000005`)](#arm64--hardware-access-violation-0xc0000005)
  * [x86-64 — logical use-after-free detection](#x86-64--logical-use-after-free-detection)
* [Methodology](#methodology)
  * [The shared race (both architectures)](#the-shared-race-both-architectures)
  * [ARM64 method — detection by real memory unmapping](#arm64-method--detection-by-real-memory-unmapping)
  * [x86-64 method — quarantine, logical verdict](#x86-64-method--quarantine-logical-verdict)
  * [Reproducing the numbers](#reproducing-the-numbers)
* [The exact interleaving with TLA+](#the-exact-interleaving-with-tla)
  * [Note on StoreBuffer](#note-on-storebuffer)
  * [The raw TLC output](#the-raw-tlc-output)
  * [The same trace, step by step](#the-same-trace-step-by-step)
  * [Reading the model yourself](#reading-the-model-yourself)

---

## Overview: where the barrier is missing

Epoch-based reclamation rests on one agreement between two threads:

> If a reader has **announced** epoch `E`, then a reclaimer **must see** that
> announcement, and must not reclaim anything retired in epoch `E` or later.

This requires the reader's announce *store* to be globally visible before the
reader's first *load* of the object — and "store, then load" is exactly the one
ordering that **both x86-TSO and ARM64 are allowed to reorder**. Preventing it needs
an explicit **StoreLoad** fence — which flushes the core's store buffer and ensures
later loads happen only after the store is globally visible — and that fence is
missing in `LightEpoch`.

### The reader side — announces with a plain store

```cs
// LightEpoch.cs:545  --  Acquire()
// (ProtectAndDrain() at :304 has the identical unfenced announce.)

// Reserve an entry in the epoch table for this thread
ReserveEntryForThread(ref entry);

// Protect CurrentEpoch by copying it to the instance-specific epoch table
// so that ComputeNewSafeToReclaimEpoch() will see it.
(*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;

// >>> MISSING: Interlocked.MemoryBarrier();  <<<
// Without it this store may sit in THIS core's store buffer while the thread
// races ahead into the critical section, so other cores keep reading the slot
// as 0.

// ... caller now dereferences the object it believes it has protected.
```

### The reclaimer side — scans without synchronizing with the reader

```cs
// LightEpoch.cs:453  --  ComputeNewSafeToReclaimEpoch()

long ComputeNewSafeToReclaimEpoch(long currentEpoch)
{
    var oldestOngoingCall = currentEpoch;

    for (var index = 1; index <= kTableSize; index++)
    {
        // >>> NOTHING SYNCHRONIZES THIS LOAD WITH THE READER'S ANNOUNCE <<<
        // The reader never flushed its store buffer and this thread never
        // established any ordering against it, so this load can still return the
        // pre-announce value. The delayed announce reads as 0, which is also how
        // a genuinely free slot reads, so the live reader is skipped below and
        // does not hold the safe epoch back.
        var entry_epoch = (*(tableAligned + index)).localCurrentEpoch;

        if (0 != entry_epoch)
        {
            if (entry_epoch < oldestOngoingCall)
                oldestOngoingCall = entry_epoch;
        }
    }

    // With the live reader skipped, this advances past the epoch the object was
    // retired in -- and the object is freed while the reader is inside it.
    SafeToReclaimEpoch = oldestOngoingCall - 1;
    return SafeToReclaimEpoch;
}
```

Note that an ordinary fence *here* cannot help. A barrier only drains the buffer of
the core that executes it, and the reclaimer has no way to reach into the reader's
store buffer — unless it uses an **asymmetric barrier**, a process-wide primitive
that forces every other core to drain
([`FlushProcessWriteBuffers`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-flushprocesswritebuffers)
on Windows, `sys_membarrier` on Linux). Short of that,
**the fix must be on the reader's core**, between the announce and the first load.

The rest of this document establishes that this is not merely theoretical: it
reproduces on real ARM64 and x86-64 hardware ([Results](#results-reproduced-on-arm64-and-x86-64)),
and TLA+ models run on TLC find the exact interleaving
([Corner case](#the-exact-interleaving-with-tla)).

---

## Results: reproduced on ARM64 and x86-64

Every number below is from real hardware (Azure VMs), running the **unmodified**
epoch implementation, with the epoch's own
`BumpCurrentEpoch` → `ComputeNewSafeToReclaimEpoch` → drain logic deciding when to
free. The harness never frees anything on its own. There are two different patterns of
using the epoch API, and both are covered: `--pattern bare` (`Resume()` → access →
`Suspend()`) and `--pattern resume-and-refresh` (`Resume()` →
`InternalRefresh()`/`ProtectAndDrain()` → access → `Suspend()`), which mirrors a
Tsavorite `BasicContext` operation ([§8](Draft.md#8-how-tsavorite-actually-uses-lightepoch)).

Every configuration is also run against a `fullbarrier` build — the same code with
the missing `Interlocked.MemoryBarrier()` added right after the announce — and it
reliably shows no issues.

### Hardware used for tests

| Machine | Architecture | CPU | Microarch | Phys cores / LPs | SMT | NUMA nodes |
|---|---|---|---|---|---|---|
| Azure `D16ps_v5` | **ARM64** | Ampere Altra | Neoverse-N1 | 16 / 16 | no | 1 |
| Azure `D16ps_v6` | **ARM64** | Microsoft Cobalt 100 | Neoverse-N2 | 16 / 16 | no | 1 |
| Azure `D32as_v5` | **x86-64** | AMD EPYC 7763 | Zen 3 | 16 / 32 | yes | 1 |
| Azure `D64s_v3` | **x86-64** | Intel Xeon Platinum 8171M | Skylake-SP | 32 / 64 | yes | **2** |

Threads are always pinned one per **physical** core; SMT siblings are never paired
(they share a store buffer, so the race window cannot open at all). On the EPYC 7763
and Xeon 8171M, SMT siblings are the logical-processor pairs `(2i, 2i+1)`.

### ARM64 — hardware access violation (`0xC0000005`)

The harness allocates and releases whole memory pages under epoch protection: a page
is unmapped only once the epoch's own drain logic declares it safe to reclaim.
Detection of a bug is therefore a genuine hardware fault — the reader dereferences a
page the OS has already unmapped — not a software-level check. "Time to fault" is
wall-clock from process start; `SURVIVED` means the run was killed at the cap with no
fault.

| CPU (phys cores) | Repro | Threads (pairs) | `baseline` (buggy) | `fullbarrier` (fixed) |
|---|---|---|---|---|
| Cobalt 100 / N2 (16) | `bare` | 4 (2 pairs) | **FAULT @ 36 s** | SURVIVED 300 s |
| Cobalt 100 / N2 (16) | `bare` | 16 (8 pairs) | **FAULT @ 7 s** | SURVIVED 300 s |
| Cobalt 100 / N2 (16) | `resume-and-refresh` | 8 (4 pairs) | **FAULT @ 73 s** | SURVIVED 300 s |
| Ampere Altra / N1 (16) | `bare` | 8 (4 pairs) | **FAULT @ 26 s** *(1 / 4 runs)* | SURVIVED 300 s |
| Ampere Altra / N1 (16) | `bare` | 16 (8 pairs) | **FAULT @ 38 s** *(5 / 16 runs)* | SURVIVED 300 s |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 8 (4 pairs) | **FAULT @ 72 s** | SURVIVED 300 s |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 16 (8 pairs) | **FAULT @ 41 s** | SURVIVED 300 s |

`fullbarrier` was run for a full 300 s on each machine under the exact configuration
that faults the baseline there, and survived every time.

`bare` on Neoverse-N1 is the least likely configuration to fault and needs repeated
attempts, so its cells report the fastest observed fault together with the hit rate
over repeated runs. At 16 threads it faulted in 5 of 16 runs (≈30 %), at 38, 44, 48,
52 and 65 s; N2 under the same configuration faults in 6 of 10 runs. Because every N1
fault landed after 38 s, a single attempt or a short run cap frequently shows nothing
— that is a sampling artifact, not an absence of the bug. Every other row in the table
faults readily enough that one run suffices.

Faulting stack, every time — the reader dereferencing a page the epoch already freed:

```
Fatal error.
System.AccessViolationException: Attempted to read or write protected memory.
   at LightEpoch.Repro.Common.Litmus`2[[LightEpoch.Core.BaselineOps, ...],
                                       [LightEpoch.Repro.Common.BareReproPattern, ...]].ReaderLoop()
   at System.Threading.Thread.StartCallback()
```

### x86-64 — logical use-after-free detection

The previous memory allocate/free workload cannot be used here: on x86 the unmap
forces a TLB-shootdown IPI, which fences the reader and closes the very window under
test
([Appendix A](Draft.md#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown)).
So `--quarantine` mode pre-allocates the pages and never unmaps them: when a page is
"freed", a poison value is written over it. A reader that reads poison has touched
memory the epoch already reclaimed — a genuine epoch bug.

Run plainly, violations are extremely rare. Reproducing them at a useful rate
required adding **read-only "disturber" threads** that do nothing but read the epoch
table, keeping its cache line shared and so delaying the reader's announce long
enough to cause the bug. Reads cannot change an epoch decision, so they cannot
manufacture a false positive, and the implementation under test is untouched.
Disturbers must be pinned to **distinct physical cores**, and SMT siblings must be
avoided — they produce no coherence traffic, silently dropping the yield to zero.

With up to 10 disturbers per pair:

| CPU | Pattern | Impl | Violations | Rounds | Exec time | Violations / 1M rounds |
|---|---|---|---|---|---|---|
| EPYC 7763 | `bare` | `baseline` | **1,422** | 50,000,000 | 196 s | **28.4** |
| EPYC 7763 | `bare` | `fullbarrier` | 0 | 50,000,000 | 165 s | 0 |
| EPYC 7763 | `resume-and-refresh` | `baseline` | **1,004** | 50,000,000 | 159 s | **20.1** |
| EPYC 7763 | `resume-and-refresh` | `fullbarrier` | 0 | 50,000,000 | 158 s | 0 |
| Xeon 8171M | `bare` | `baseline` | **648** | 45,000,000 | ~174 s | **14.4** |
| Xeon 8171M | `bare` | `fullbarrier` | 0 | 45,000,000 | ~174 s | 0 |
| Xeon 8171M | `resume-and-refresh` | `baseline` | **665** | 60,000,000 | ~165 s | **11.1** |
| Xeon 8171M | `resume-and-refresh` | `fullbarrier` | 0 | 60,000,000 | ~165 s | 0 |
| | | **total** | **3,739 / 0** | 410,000,000 | ~22 min | |

A **pair** is one reader thread plus one reclaimer thread, and each pair runs in its
own process with every core pinned explicitly. On the EPYC two processes run
concurrently, each putting its reader and its reclaimer on opposite sides of the
LP 0-15 / LP 16-31 latency boundary:

```
dotnet LightEpoch.Repro.dll --impl baseline --pattern bare --pairs 1 --rounds 5000000 --quarantine \
    --reclaimer-core 0  --reader-core 16 --disturber-cores 2,4,6,8,10,18,20,22,24,26
dotnet LightEpoch.Repro.dll --impl baseline --pattern bare --pairs 1 --rounds 5000000 --quarantine \
    --reclaimer-core 12 --reader-core 28 --disturber-cores 3,5,7,9,11,19,21,23,25,27
```

On the Xeon three run concurrently, each with its reader and its reclaimer on
different sockets (socket 0 = LP 0-31, socket 1 = LP 32-63):

```
    --reclaimer-core 0  --reader-core 32 --disturber-cores 2,4,6,8,10,34,36,38,40,42
    --reclaimer-core 12 --reader-core 44 --disturber-cores 14,16,18,20,22,46,48,50,52,54
    --reclaimer-core 24 --reader-core 56 --disturber-cores 26,28,30,58,60,62
```

`--impl fullbarrier` and `--pattern resume-and-refresh` are run with the identical
core assignments.

`fullbarrier` recorded **0 violations**.

---

## Methodology

Both modes run the identical race and differ *only* in how a use-after-free is
detected. The epoch implementation is never modified, and the harness contributes no
reclamation policy of its own.

### The shared race (both architectures)

Each **litmus pair** — a litmus test is a minimal two-thread program written to expose
one specific memory-ordering behaviour — is one reader thread and one reclaimer
thread, pinned to two distinct physical cores. Per round, a two-phase reusable barrier
releases both threads simultaneously so their store/load windows overlap:

```
        RECLAIMER thread                          READER thread
        ────────────────                          ─────────────
setup   page = allocate(4 KB)
        fill page with known values
        publish curPage = page

        ═════════ StartBarrier: both threads released together ═════════

race    curPage = 0  (unlink the page)           Resume()
                                                   └─ announce store, NO FENCE  ← the bug
        BumpCurrentEpoch(onDrain: free page)     p = read curPage
          └─ Interlocked.Increment(CurrentEpoch)
          └─ ComputeNewSafeToReclaimEpoch()      dereference p ~20,000 times
               └─ scans every thread's slot
          └─ if deemed safe: free/poison page    Suspend()

        ═════════ EndBarrier: wait for both, then next round ═════════
```

The reclaimer side is already correctly fenced (`Interlocked.Increment` is a full
barrier), so the **only** unordered access is the reader's announce store. A
violation therefore requires exactly one thing: the reclaimer's scan ran before the
reader's announce became visible, so the scan concluded no reader was protected and
the page was freed while the reader was still inside its critical section.

The repro harness has these flags for distributing the reader-reclaimer pairs across
the machine:

* `--pairs N` — runs N reader-reclaimer pairs concurrently on 2N distinct physical cores.
* `--seed S` — shuffles which cores are used.

### ARM64 method — detection by real memory unmapping

* `WindowsNative.Alloc` = `VirtualAlloc` of a whole 4 KB page;
  `WindowsNative.Free` = `VirtualFree(..., MEM_RELEASE)`, a **full unmap**.
* The unmap is passed as the `onDrain` callback to the real public API
  `BumpCurrentEpoch(onDrain)`. The page is only unmapped if the epoch's own
  safe-to-reclaim logic decides it is safe.
* If a reader is still dereferencing that page, the addresses are no longer mapped
  and the CPU raises `0xC0000005`, terminating the process.
* **Verdict:** process exit code. Zero = survived; an access violation = the epoch
  freed memory a protected reader was reading.
* Implemented in `Litmus<TOps, TPattern>`. This is the default mode.

### x86-64 method — quarantine, logical verdict

Unmapping cannot be used here: on x86 there is no broadcast TLB invalidation, so
every `VirtualFree` makes the kernel IPI the reader's core, and taking an interrupt
on x86 drains the store buffer — the OS supplies the missing fence on every round.
So the x86 mode keeps the kernel out of the loop entirely:

* **Pages come from a pool** allocated once up front (1024 pages) and are recycled,
  so there is no `VirtualAlloc`/`VirtualFree`, no page-table edit, and no shootdown.
* **"Freeing" stamps the page** with a poison sentinel (`0xDEADBEEFDEADBEEF`) instead
  of unmapping it. It is still driven by the epoch's own drain decision.
* **Drain callbacks are pre-built**, one per pool slot, so no allocation happens in
  the race loop and therefore no GC — .NET's GC suspension calls
  `FlushProcessWriteBuffers`, which would itself flush the store buffer.
* **Verdict:** the reader checks the values it reads while protected. Observing
  poison means the epoch freed a page the reader was legitimately reading — a
  use-after-free by the algorithm's own definition.
* Implemented in `QuarantineLitmus<TOps, TPattern>` (`--quarantine`).

### Reproducing the numbers

Build once on Windows with a .NET 10 SDK:

```powershell
dotnet build src/LightEpoch.Repro -c Release
```

Then run from the build output directory (`net10.0`), setting `DOTNET_gcServer=1`:

```powershell
# ARM64 - hardware fault. Nonzero exit / AccessViolationException = bug reproduced.
dotnet LightEpoch.Repro.dll --impl baseline    --pairs 2 --rounds 100000000000
dotnet LightEpoch.Repro.dll --impl fullbarrier --pairs 2 --rounds 100000000000

# The Tsavorite per-operation sequence (defaults to --pattern bare)
dotnet LightEpoch.Repro.dll --pattern resume-and-refresh --impl baseline --pairs 2 --rounds 100000000000

# x86-64 with read-only disturbers - the high-yield configuration used for the table
# above. "USE-AFTER-FREE" on stderr = bug reproduced. --disturber-cores must list
# DISTINCT physical cores; SMT siblings share L1 and produce no coherence traffic,
# which silently drops the yield to zero.
dotnet LightEpoch.Repro.dll --impl baseline --pairs 1 --rounds 5000000 --quarantine `
    --reclaimer-core 0 --reader-core 16 --disturber-cores 2,4,6,8,10,18,20,22,24,26
```

---

## The exact interleaving with TLA+

The hardware repro proves the bug *happens*. The TLA+ model can show the states
leading to the issue: TLC explores every interleaving of the two threads and every
possible moment the store buffer drains, and when it finds a violation it prints the
shortest path to it.

Reproduce it yourself:

```powershell
cd tla
.\run-tests-in-docker.ps1
```

### Note on StoreBuffer

One idea explains the entire bug:

> **A store does not go to memory. It goes to a queue.**

On modern CPUs each core owns a private FIFO **store buffer**. When a core executes a
plain store, the value lands in that queue and the core moves on immediately — it does
not wait for memory. The value becomes visible to *other* cores only later, when the
buffer drains. Nobody else can see the queue's contents.

This creates an asymmetry that is the crux of the bug:

* The **writing core** reads its own buffer first (*store forwarding*), so it always
  sees its own latest value. From the inside, the write looks like it happened.
* **Every other core** still reads the stale value from memory. From the outside, the
  write has not happened yet.

So the reader thread genuinely believes it announced itself, while the reclaimer
thread genuinely observes an empty slot. **Both are reading correctly.** No cache is
"stale" in the sense of a bug; this is architecturally permitted behaviour.

In the TLA+ trace, that queue is `storeBuffer` (one per thread) and memory is `memory`:

| Symbol | Meaning | Production equivalent |
| --- | --- | --- |
| `memory.currentEpoch` | the global current epoch | `CurrentEpoch` |
| `memory.localCurrentEpoch` | the reader's slot, as **the rest of the machine sees it** | `(*(tableAligned + entry)).localCurrentEpoch` |
| `memory.objectUnlinked` | object unlinked / retired | `curPage = 0` |
| `memory.objectFreed` | object actually freed | the `onDrain` callback ran |
| `storeBuffer[Reader]` | reader's private store queue | the reader core's store buffer |
| `storeBuffer[Reclaimer]` | reclaimer's private store queue | the reclaimer core's store buffer |
| `readerInCriticalSection` | reader is dereferencing the object | inside the critical section |
| `readerAnnouncedEpoch` | what the reader *thinks* it published | the value it stored into its slot |
| `triggerEpoch` | epoch the retire was tagged with | `epoch.BumpCurrentEpoch(onDrain)` |

The safety property in the TLA+ model is one line — never free while a reader is still
inside:

```tla
NoUseAfterFree == ~ (memory.objectFreed /\ readerInCriticalSection)
```

### The raw TLC output

This is the counterexample exactly as TLC prints it:

```
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Warning: Please run the Java VM which executes TLC with a throughput optimized garbage collector by passing the "-XX:+UseParallelGC" property.
(Use the -nowarning option to disable this warning.)
Running breadth-first search Model-Checking with fp 108 and seed -8976058988207400573 with 1 worker on 20 cores with 7984MB heap and 64MB offheap memory [pid: 7] (Linux 6.6.87.2-microsoft-standard-WSL2 amd64, Eclipse Adoptium 21.0.11 x86_64, MSBDiskFPSet, DiskStateQueue).
Parsing file /work/epoch/LightEpoch.tla
Parsing file /tmp/Naturals.tla
Parsing file /tmp/Sequences.tla
Parsing file /work/StoreBuffer.tla
Semantic processing of module Naturals
Semantic processing of module Sequences
Semantic processing of module StoreBuffer
Semantic processing of module LightEpoch
Starting... (2026-07-28 03:41:31)
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-07-28 03:41:31.
Error: Invariant NoUseAfterFree is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ readerPc = "Acquire"
/\ readerInCriticalSection = FALSE
/\ triggerEpoch = 0
/\ reclaimerPc = "Unlink"
/\ readerAnnouncedEpoch = 0
/\ storeBuffer = [Reader |-> <<>>, Reclaimer |-> <<>>]
/\ memory = [ currentEpoch |-> 1,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> FALSE,
  objectFreed |-> FALSE ]

State 2: <Acquire line 75, col 5 to line 79, col 79 of module LightEpoch>
/\ readerPc = "ReadObject"
/\ readerInCriticalSection = FALSE
/\ triggerEpoch = 0
/\ reclaimerPc = "Unlink"
/\ readerAnnouncedEpoch = 1
/\ storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]
/\ memory = [ currentEpoch |-> 1,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> FALSE,
  objectFreed |-> FALSE ]

State 3: <ReadObject line 84, col 5 to line 87, col 89 of module LightEpoch>
/\ readerPc = "Dereference"
/\ readerInCriticalSection = TRUE
/\ triggerEpoch = 0
/\ reclaimerPc = "Unlink"
/\ readerAnnouncedEpoch = 1
/\ storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]
/\ memory = [ currentEpoch |-> 1,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> FALSE,
  objectFreed |-> FALSE ]

State 4: <Unlink line 105, col 5 to line 108, col 98 of module LightEpoch>
/\ readerPc = "Dereference"
/\ readerInCriticalSection = TRUE
/\ triggerEpoch = 0
/\ reclaimerPc = "BumpCurrentEpoch"
/\ readerAnnouncedEpoch = 1
/\ storeBuffer = [ Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>,
  Reclaimer |-> <<[f |-> "objectUnlinked", v |-> TRUE]>> ]
/\ memory = [ currentEpoch |-> 1,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> FALSE,
  objectFreed |-> FALSE ]

State 5: <BumpCurrentEpoch line 114, col 5 to line 120, col 76 of module LightEpoch>
/\ readerPc = "Dereference"
/\ readerInCriticalSection = TRUE
/\ triggerEpoch = 1
/\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
/\ readerAnnouncedEpoch = 1
/\ storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]
/\ memory = [ currentEpoch |-> 2,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> TRUE,
  objectFreed |-> FALSE ]

State 6: <ComputeNewSafeToReclaimEpoch line 130, col 5 to line 138, col 103 of module LightEpoch>
/\ readerPc = "Dereference"
/\ readerInCriticalSection = TRUE
/\ triggerEpoch = 1
/\ reclaimerPc = "Done"
/\ readerAnnouncedEpoch = 1
/\ storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]
/\ memory = [ currentEpoch |-> 2,
  localCurrentEpoch |-> 0,
  objectUnlinked |-> TRUE,
  objectFreed |-> TRUE ]

54 states generated, 36 distinct states found, 15 states left on queue.
The depth of the complete state graph search is 6.
The average outdegree of the complete state graph is 2 (minimum is 0, the maximum 3 and the 95th percentile is 3).
Finished in 00s at (2026-07-28 03:41:31)
```

`Error: Invariant NoUseAfterFree is violated.` is the result: on x86-TSO, with no
fence on the announce, the object *can* be freed while the reader is inside.

### The same trace, step by step

TLC finds the violation in **five steps** (six states, counting the initial one). Watch
one value: `memory.localCurrentEpoch`. It is `0` — "no reader present" — for the entire
trace, even though the reader announced itself in step 1 and never left.

**Initial state.** Epoch 1 is current, the reader's slot is empty, both queues are
empty, nothing is retired or freed.

```
memory      = [currentEpoch |-> 1, localCurrentEpoch |-> 0, objectUnlinked |-> FALSE, objectFreed |-> FALSE]
storeBuffer = [Reader |-> <<>>, Reclaimer |-> <<>>]
```

---

**Step 1 — `Acquire`: the reader announces itself. This is the bug.**

The reader reads `CurrentEpoch` (= 1) and writes it into its slot. That write is a
**plain store**, so it goes into the reader's queue, not to memory
([`LightEpoch.cs:545`](src/LightEpoch.Implementations/LightEpoch.cs#L545)).

```
storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]   ← queued, private to Reader
memory      = [currentEpoch |-> 1, localCurrentEpoch |-> 0, ...]                          ← memory still says "nobody here"
readerAnnouncedEpoch = 1                                                                  ← what the reader believes
```

Note `memory.localCurrentEpoch` is still `0`. The reader has announced itself to
*itself*. The rest of the machine has no idea it exists. **This is the only unordered
access in the entire program** — everything the reclaimer does is already correctly
fenced.

---

**Step 2 — `ReadObject`: the reader checks the object is still linked, and takes it.**

The reader loads `objectUnlinked` and sees `FALSE`, so the object looks live. It enters
its critical section: `readerInCriticalSection = TRUE`. From here on, freeing the object
is a use-after-free.

```
readerInCriticalSection = TRUE     ← reader is now dereferencing the object
```

The reader has done everything the API asks of it. It is correctly protected under the
epoch contract. Everything that follows is the reclaimer failing to notice.

---

**Step 3 — `Unlink`: the reclaimer unlinks the object.**

```
storeBuffer = [ Reader    |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>,
                Reclaimer |-> <<[f |-> "objectUnlinked", v |-> TRUE]>> ]
```

Both queues now hold one pending store. The reader's announce is still not visible.

---

**Step 4 — `BumpCurrentEpoch`: the reclaimer increments the epoch — and this fences *its own* buffer.**

`Interlocked.Increment(ref CurrentEpoch)`
([`LightEpoch.cs:365`](src/LightEpoch.Implementations/LightEpoch.cs#L365)) is a locked
RMW, which is a **full barrier**. The reclaimer's queue drains completely:
`objectUnlinked` is now visible in memory, and the epoch advances to 2. The retire is
tagged with epoch 1.

```
memory      = [currentEpoch |-> 2, localCurrentEpoch |-> 0, objectUnlinked |-> TRUE, objectFreed |-> FALSE]
storeBuffer = [Reader |-> <<[f |-> "localCurrentEpoch", v |-> 1]>>, Reclaimer |-> <<>>]
triggerEpoch = 1                    ← Reclaimer drained; Reader's announce STILL queued
```

A barrier is **local to the core that executes it**. This one flushes the
*reclaimer's* store buffer; it has no power to reach into the *reader's* store buffer
and flush that. The reader's announce is still sitting in a queue that only the
reader can see.

---

**Step 5 — `ComputeNewSafeToReclaimEpoch`: the reclaimer scans the slots and frees the object.**

`ComputeNewSafeToReclaimEpoch`
([`LightEpoch.cs:453`](src/LightEpoch.Implementations/LightEpoch.cs#L453)) walks every
thread's slot looking for the oldest active epoch, skipping slots that read `0`:

```csharp
var entry_epoch = (*(tableAligned + index)).localCurrentEpoch;
if (0 != entry_epoch)                        // ← reader's slot reads 0, so it is SKIPPED
{
    if (entry_epoch < oldestOngoingCall)
        oldestOngoingCall = entry_epoch;
}
SafeToReclaimEpoch = oldestOngoingCall - 1;
```

The reader's slot reads `0`, so the scan skips it and concludes **no thread is
active**. Therefore `oldestOngoingCall = CurrentEpoch = 2`, and
`SafeToReclaimEpoch = 1`. The object was retired at epoch 1, and `1 <= 1`, so it is
safe to free:

```
memory = [currentEpoch |-> 2, localCurrentEpoch |-> 0, objectUnlinked |-> TRUE, objectFreed |-> TRUE]
readerInCriticalSection = TRUE                ← reader is STILL dereferencing it
```

`memory.objectFreed /\ readerInCriticalSection` — **`NoUseAfterFree` is violated.** On
ARM64 the reader's next dereference of that page takes an access violation
(`0xC0000005`).

The reader's announce is *still* in its store buffer, unflushed, at the moment the
memory is released.

### Reading the model yourself

| File | What it is |
| --- | --- |
| [`tla/StoreBuffer.tla`](tla/StoreBuffer.tla) | The store buffer itself — queuing, store forwarding, drain, barriers. Every spec below shares it. |
| [`tla/memory-models/X86TSO.tla`](tla/memory-models/X86TSO.tla) | Calibration: reproduces the textbook SB litmus, proving the harness is neither too weak nor too strong. |
| [`tla/epoch/LightEpoch.tla`](tla/epoch/LightEpoch.tla) | The trace above. **VIOLATED.** |
| [`tla/epoch/LightEpochResumeAndRefresh.tla`](tla/epoch/LightEpochResumeAndRefresh.tla) | Tsavorite's per-operation sequence. **VIOLATED.** |
| [`tla/epoch/fixes/`](tla/epoch/fixes) | The same two specs with the barrier added. **HOLD.** |

Each epoch spec is built on top of `StoreBuffer.tla`.

