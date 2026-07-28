# LightEpoch memory-ordering study: missing StoreLoad fence

This repository is a self-contained, reproducible study of a **memory-ordering
bug in an epoch-based safe-memory-reclamation (SMR) scheme** called
`LightEpoch`. The epoch *enter* (announce) path publishes a thread's current
epoch with a **plain store and no StoreLoad fence**. This lets the reclaimer's
"safe-to-reclaim" scan miss a live reader and free memory that the reader is about
to dereference. This happens reliably on a weakly-ordered CPU (**ARM64**), and more
rarely — but still demonstrably — on **x86-64**.

The bug is demonstrated in two complementary ways:

1. **A running C# repro** (`src/`) that links the epoch implementation
   unmodified and lets the epoch machinery *itself* free the object. On real
   Windows ARM64 the buggy build faults within seconds, while the fixed builds run
   indefinitely. On x86-64 the buggy build also reproduces, in a smaller window
   (see [Results](#results-reproduced-on-arm64-and-x86-64) below).
2. **Formal TLA+ models** (`tla/`) of the x86-TSO (total store order) memory model, and
   of the epoch algorithm with each candidate fix. TLC exhaustively finds the
   use-after-free in the baseline and proves each fix closes it.

> Terminology note: throughout, "fault" / "memory fault" / `0xC0000005` all
> mean the process touched memory that had been unmapped — the
> observable symptom of reclaiming memory that is still in use.

---

## Results: reproduced on ARM64 and x86-64

Every number below is from real hardware (Azure VMs and a local workstation),
running the **unmodified** epoch implementation, with the epoch's own
`BumpCurrentEpoch` → `ComputeNewSafeToReclaimEpoch` → drain logic deciding when to
free. The harness never frees anything on its own. There are two different patterns of
using the epoch API, and both are covered: `--pattern bare` (`Resume()` → access →
`Suspend()`) and `--pattern resume-and-refresh`, which mirrors a Tsavorite
`BasicContext` operation ([§8](Draft.md#8-how-tsavorite-actually-uses-lightepoch)).

### Hardware under test

| Machine | Architecture | CPU | Microarch | Phys cores / LPs | SMT | NUMA nodes |
|---|---|---|---|---|---|---|
| Azure `D4ps_v5` | **ARM64** | Ampere Altra | Neoverse-N1 | 4 / 4 | no | 1 |
| Azure `D4ps_v6` | **ARM64** | Microsoft Cobalt 100 | Neoverse-N2 | 4 / 4 | no | 1 |
| Azure `D16ps_v5` | **ARM64** | Ampere Altra | Neoverse-N1 | 16 / 16 | no | 1 |
| Azure `D16ps_v6` | **ARM64** | Microsoft Cobalt 100 | Neoverse-N2 | 16 / 16 | no | 1 |
| local workstation | **x86-64** | Intel i7-12700K | Alder Lake | 12 / 20 | yes (P-cores) | 1 |
| Azure `D64s_v4` | **x86-64** | Intel Xeon Platinum 8272CL | Cascade Lake | 32 / 64 | yes | **2** |

Threads are always pinned one per **physical** core; SMT siblings are never paired
(they share a store buffer, so the race window cannot open at all).

### ARM64 — hardware access violation (`0xC0000005`)

Detection is a genuine unmapped-page fault. "Time to fault" is wall-clock from
process start; `SURVIVED` means the run was killed at the cap with no fault.

| CPU (phys cores) | Repro | Threads (pairs) | `baseline` (buggy) | `fullbarrier` (fixed) |
|---|---|---|---|---|
| Cobalt 100 / N2 (4) | `bare` | 2 (1 pair) | no fault in 120 s | — |
| Cobalt 100 / N2 (4) | `bare` | 4 (2 pairs) | **FAULT @ 8 s** | — |
| Ampere Altra / N1 (4) | `bare` | 2 (1 pair) | no fault in 120 s | — |
| Ampere Altra / N1 (4) | `bare` | 4 (2 pairs) | no fault in 120 s | — |
| Cobalt 100 / N2 (16) | `bare` | 4 (2 pairs) | **FAULT @ 36 s** | — |
| Cobalt 100 / N2 (16) | `bare` | 8 (4 pairs) | no fault in 120 s *(capped)* | — |
| Cobalt 100 / N2 (16) | `bare` | 16 (8 pairs) | **FAULT @ 7 s** | SURVIVED 300 s |
| Cobalt 100 / N2 (16) | `resume-and-refresh` | 8 (4 pairs) | **FAULT @ 73 s** | — |
| Ampere Altra / N1 (16) | `bare` | 4 (2 pairs) | no fault in 120 s *(capped)* | — |
| Ampere Altra / N1 (16) | `bare` | 8 (4 pairs) | no fault in 120 s *(capped)* | — |
| Ampere Altra / N1 (16) | `bare` | 16 (8 pairs) | no fault in 120 s *(capped)* | — |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 8 (4 pairs) | **FAULT @ 72 s** | SURVIVED 300 s |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 16 (8 pairs) | **FAULT @ 41 s** | SURVIVED 300 s |

The 4-core and 16-core rows are the same two machines, resized between runs.

Concurrency is the dominant factor in how fast the window opens: every extra pair is
another independent chance per unit time for the reclaimer's scan to run before the
reader's unfenced announce becomes visible. Two results make the point sharply:

* **`bare` is much harder to reproduce on Neoverse-N1 than on N2.** N2 faults under
  `bare` in as little as 7 s; N1 did not fault under `bare` in any 120 s run, at
  either core count or any pair count. Under `resume-and-refresh` — the sequence a
  real Tsavorite `BasicContext` operation performs — N1 faults readily. These are
  capped observations, not proof of absence.
* **N1 at 4 physical cores produced no fault at all**, under either pattern; 16 cores
  are what make it reproducible.

Faulting stack, every time — the reader dereferencing a page the epoch already freed:

```
Fatal error.
System.AccessViolationException: Attempted to read or write protected memory.
   at LightEpoch.Repro.Common.Litmus`2[[LightEpoch.Core.BaselineOps, ...],
                                       [LightEpoch.Repro.Common.BareReproPattern, ...]].ReaderLoop()
   at System.Threading.Thread.StartCallback()
```

### ARM64 — repeatability

A single fault proves the window exists; it does not show how readily it opens. To
measure that, the `baseline` build was run back to back on both 16-core machines until
50 faults were collected, each attempt capped and killed if it survived. A capped run
counts as a miss.

| CPU (phys cores) | Repro | Threads (pairs) | Cap | Faults / attempts | Hit rate | Time to fault (avg / min / max) |
|---|---|---|---|---|---|---|
| Cobalt 100 / N2 (16) | `bare` | 16 (8 pairs) | 300 s | **50 / 51** | 98 % | 40 s / 1 s / 158 s |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 8 (4 pairs) | 300 s | 6 / 21 | 29 % | 61 s / 20 s / 143 s |
| Ampere Altra / N1 (16) | `resume-and-refresh` | 16 (8 pairs) | 120 s | 8 / 24 *(running)* | 33 % | 47 s / 7 s / 94 s |

Neoverse-N2 reproduces essentially on demand — 50 faults in 51 attempts, taking about
43 minutes end to end, with the fastest fault landing in 1 second. Neoverse-N1 is far
more resistant: roughly one attempt in three faults, so the same 50 faults cost hours
of wall clock. In both cases the faults are **bursty** rather than evenly spread —
long runs of misses sit between clusters of quick faults — which is why a single
"survived" run is weak evidence and the repeat count matters.

`fullbarrier` was run for a full 300 s on each machine under the exact configuration
that faults the baseline there, and survived every time.

### x86-64 — logical use-after-free detection

x86 needs a different detection mechanism, because the memory unmap used on ARM64
forces a TLB-shootdown IPI that introduces a memory barrier on the reader and
destroys the very window under test
(the full explanation is
[Appendix A](Draft.md#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown)).
So instead the `--quarantine` mode is used: a poison value is written into the page
being reclaimed, which allows a use-after-free to be detected without unmapping
anything. Counts below are use-after-free **reads** observed:

| CPU | Pattern | NUMA placement | Impl | Pairs violating | Violations |
|---|---|---|---|---|---|
| i7-12700K (1 node) | `bare` | same node | `baseline` | **5 / 40** | **59** |
| i7-12700K (1 node) | `bare` | same node | `fullbarrier` | 0 / 40 | 0 |
| i7-12700K (1 node) | `bare` | same node | `interlocked` | 0 / 40 | 0 |
| i7-12700K (1 node) | `bare` | same node | `asymmetric` | 0 / 40 | 0 |
| i7-12700K (1 node) | `resume-and-refresh` | same node | `baseline` | **3 / 40** | **17** |
| i7-12700K (1 node) | `resume-and-refresh` | same node | `fullbarrier` | 0 / 40 | 0 |
| Xeon 8272CL (**2 nodes**) | `bare` | **pairs straddle nodes** | `baseline` | **3 / 30** | **6** |
| Xeon 8272CL (**2 nodes**) | `bare` | single node | `baseline` | **1 / 30** | **4** |
| Xeon 8272CL (**2 nodes**) | `bare` | pairs straddle nodes | `fullbarrier` | 0 / 30 | 0 |
| Xeon 8272CL (**2 nodes**) | `bare` | single node | `fullbarrier` | 0 / 30 | 0 |

### What this establishes

* The unfenced announce is **incorrect on both architectures**, matching the TLA+
  result (`X86TSO` with no fence is **VIOLATED**; ARM64 is weaker than TSO, so the
  same window is open there too).
* **Every fix was clean under the conditions that broke the baseline.**
  `fullbarrier` was run on every machine and every configuration in the tables above
  and never faulted or violated; `interlocked` and `asymmetric` were additionally
  clean across all x86-64 quarantine runs. The buggy build failed on both
  architectures under exactly the same conditions.
* **The failure is repeatable, not a one-off.** 50 independent faults were collected
  back to back on Neoverse-N2, at a 98 % hit rate.
* **How easily it reproduces varies enormously by microarchitecture and workload
  shape.** Neoverse-N2 faults under the minimal `bare` sequence within seconds, and
  under `resume-and-refresh` too. Neoverse-N1 produced no fault at 4 physical cores
  at all, and at 16 cores reproduces only under the Tsavorite-like
  `resume-and-refresh` sequence, never under `bare`. A clean run on one ARM64 part
  therefore says nothing about another.

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
barrier), so the **only** unordered access in the whole loop is the reader's announce
store. A violation therefore requires exactly one thing: the reclaimer's scan ran
before the reader's announce became visible, so the scan concluded no reader was
protected and the page was freed while the reader was still inside its critical
section.

The repro harness has these flags for distributing the reader-reclaimer pairs across
the machine:

* `--pairs N` — runs N reader-reclaimer pairs concurrently on 2N distinct physical cores.
* `--seed S` — shuffles which cores are used.
* `--cross-numa` — forces the reclaimer and the reader of each pair onto **different NUMA nodes**.

### ARM64 method — detection by real memory unmapping

* `WindowsNative.Alloc` = `VirtualAlloc` of a whole 4 KB page;
  `WindowsNative.Free` = `VirtualFree(..., MEM_RELEASE)`, a **full unmap**.
* The unmap is passed as the `onDrain` callback to the real public API
  `BumpCurrentEpoch(onDrain)`. The page is only unmapped if the epoch's own
  safe-to-reclaim logic decides it is safe.
* If a reader is still dereferencing that page, the addresses are no longer mapped
  and the CPU raises `0xC0000005`, terminating the process.
* **Verdict:** process exit code. Zero = survived; an access violation = the epoch
  freed memory a protected reader was reading. There is no heuristic and nothing to
  tune — the hardware decides.
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
* Implemented in `QuarantineLitmus<TOps, TPattern>` (`--quarantine`), a **separate**
  class; the ARM64 unmap path is untouched.

Because this verdict is software rather than hardware, the detector itself is
validated with `--self-test` — see [Appendix A.7](Draft.md#a7-validating-the-detector).

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

# x86-64 - logical detection. "USE-AFTER-FREE" on stderr = bug reproduced.
dotnet LightEpoch.Repro.dll --impl baseline    --pairs 5 --rounds 8000000 --quarantine
dotnet LightEpoch.Repro.dll --impl fullbarrier --pairs 5 --rounds 8000000 --quarantine

# x86-64, multi-socket: force each pair's reader and reclaimer onto different NUMA nodes
dotnet LightEpoch.Repro.dll --impl baseline --pairs 8 --rounds 8000000 --quarantine --cross-numa

# Detector self-test - MUST report violations, otherwise --quarantine results are meaningless
dotnet LightEpoch.Repro.dll --impl fullbarrier --pairs 1 --rounds 200000 --self-test
```

x86 violations are rare, so run the buggy build several times (the counts above are
totals over 30–40 pair-runs) and always compare against a fixed build over the same
number of runs.

---

## Corner case: the exact interleaving, step by step

The hardware repro proves the bug *happens*. It cannot show you *why*, because by the
time the page faults the evidence is gone. The TLA+ model can: TLC explores every
interleaving of the two threads and every possible moment the store buffer drains, and
when it finds a violation it prints the shortest path to it.

Reproduce it yourself:

```powershell
cd tla
.\run-tests-in-docker.ps1
```

### The mental model you need first

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

This is the counterexample exactly as TLC prints it, unedited:

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
fence on the announce, the object *can* be freed while the reader is inside. The
`readerPc`/`reclaimerPc` fields are each thread's program counter, so the two threads
can be read off independently down the trace.

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
([`LightEpoch.cs:527`](src/LightEpoch.Implementations/LightEpoch.cs#L527)).

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

This step is the one most people expect to save them, and it is worth being precise
about why it does not. A barrier is **local to the core that executes it**. It flushes
the *reclaimer's* store buffer. It has no power to reach into the *reader's* store
buffer and flush that. The reader's announce is still sitting in a queue that only the
reader can see.

---

**Step 5 — `ComputeNewSafeToReclaimEpoch`: the reclaimer scans the slots and frees the object.**

`ComputeNewSafeToReclaimEpoch`
([`LightEpoch.cs:435`](src/LightEpoch.Implementations/LightEpoch.cs#L435)) walks every
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

### Why it is genuinely hard to see

Three properties conspire to make this bug nearly invisible in review:

1. **The `0` that means "absent" is indistinguishable from the `0` that means "not yet
   visible."** The scan's `if (0 != entry_epoch)` cannot tell a thread that never
   entered from a thread whose announce is still queued. A skipped slot and an absent
   thread look identical.
2. **Every individual thread is correct in isolation.** The reader announced before
   entering. The reclaimer bumped the epoch before scanning. Read either thread's code
   on its own and it is right. The defect exists only in the *ordering relationship
   between* them, which no single function shows.
3. **The reader can self-verify and be misled.** Because of store forwarding, if the
   reader re-reads its own slot it sees `1` — the value it wrote. Any debug assertion
   the reader makes about its own protection passes. The value is only invisible
   *from other cores*.

### What actually fixes it, and what does not

The reader must not be allowed to *load* `ret` until its announce *store* is globally
visible. That specific constraint — no load may float above an earlier store — is a
**StoreLoad** barrier, the one ordering x86-TSO does **not** give away for free.

This is why the usual instincts fail:

| Attempt | Why it does not work |
| --- | --- |
| Mark the field `volatile` | On x86 a release store is *already* a plain store; TSO gives release semantics for free. It orders StoreStore and LoadLoad, **not StoreLoad**. The window is untouched. |
| "`Interlocked.Increment` is a barrier" | It is — on the **reclaimer's** core. Barriers are local. It cannot drain the reader's buffer (step 4). |
| "The CAS when acquiring the slot is a barrier" | It is, but it runs *before* the announce store. Fencing before a store says nothing about that store versus a *later* load. |
| Add a fence in `ComputeNewSafeToReclaimEpoch` | The reclaimer can flush only its own buffer. It cannot pull the reader's queued announce into memory. |

The fix must be on the **reader's** core, between the announce and the first load:

```csharp
(*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;
Interlocked.MemoryBarrier();   // ← drain THIS core's store buffer before any load
```

With that barrier the reader cannot reach step 2 while its announce is still queued, so
by the time the reclaimer scans in step 5 the slot reads `1`, the scan computes
`SafeToReclaimEpoch = 0`, and the retire at epoch 1 is held back. TLC confirms this:
`FixedLightEpochWithMemoryBarrier` **HOLDS** under both memory models.

### The same trace, in production shape

`LightEpoch.tla` models the bare enter path. Tsavorite does not call it that way — it
runs `Resume()` → `ProtectAndDrain()` → operation → `Suspend()` per operation, which
announces at **two** sites
([`LightEpoch.cs:527`](src/LightEpoch.Implementations/LightEpoch.cs#L527) and
[`:304`](src/LightEpoch.Implementations/LightEpoch.cs#L304)), both unfenced.
`LightEpochResumeAndRefresh.tla` models that exact sequence and is **also VIOLATED**,
which is what carries the result from "a bug in the abstract algorithm" to "a bug
reachable through the API Tsavorite actually uses."

### Reading the model yourself

| File | What it is |
| --- | --- |
| [`tla/StoreBuffer.tla`](tla/StoreBuffer.tla) | The store buffer itself — queuing, store forwarding, drain, barriers. Every spec below shares it. |
| [`tla/memory-models/X86TSO.tla`](tla/memory-models/X86TSO.tla) | Calibration: reproduces the textbook SB litmus, proving the harness is neither too weak nor too strong. |
| [`tla/epoch/LightEpoch.tla`](tla/epoch/LightEpoch.tla) | The trace above. **VIOLATED.** |
| [`tla/epoch/LightEpochResumeAndRefresh.tla`](tla/epoch/LightEpochResumeAndRefresh.tla) | Tsavorite's per-operation sequence. **VIOLATED.** |
| [`tla/epoch/fixes/`](tla/epoch/fixes) | The same two specs with the barrier added. **HOLD.** |

Each spec is checked under two memory models: `tso` (x86, only StoreLoad relaxed) and
`arm` (additionally allows a core's stores to become visible out of order). Every TSO
behaviour is also an ARM behaviour, so a violation under `tso` is the conservative
result, and the fixes holding under `arm` shows they do not secretly depend on
FIFO drain order.

---

## Full report

The analysis behind these results — the algorithm and the bug, the x86-TSO and ARM64
memory models, each candidate fix, how the repros detect a use-after-free, how
Tsavorite actually drives the epoch, and the TLA+ models — is in
**[Draft.md](Draft.md)**.

