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
* [Choosing the fix: the hazard is load-side](#choosing-the-fix-the-hazard-is-load-side)
  * [What each candidate costs and whether it works](#what-each-candidate-costs-and-whether-it-works)
  * [Graded violation counts on ARM64](#graded-violation-counts-on-arm64)
  * [The same matrix on x86-64: an architectural double dissociation](#the-same-matrix-on-x86-64-an-architectural-double-dissociation)
  * [The powered crash matrix](#the-powered-crash-matrix)
  * [What the hardware actually executes](#what-the-hardware-actually-executes)
  * [Open questions](#open-questions)
  * [A note on method](#a-note-on-method)
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
* ["But Tsavorite already adds the barrier anyway"](#but-tsavorite-already-adds-the-barrier-anyway)
* [Is `Entry.threadId` still needed?](#is-entrythreadid-still-needed)
  * [A verdict that turned out to be a theorem](#a-verdict-that-turned-out-to-be-a-theorem)
  * [The one thing blocking removal](#the-one-thing-blocking-removal)
* [Other ordering defects in the same class](#other-ordering-defects-in-the-same-class)
  * [The lost wakeup, and two wrong answers on the way to it](#the-lost-wakeup-and-two-wrong-answers-on-the-way-to-it)
  * [What the fix costs](#what-the-fix-costs)
* [What to change in production](#what-to-change-in-production)
  * [The one thing this study does not settle](#the-one-thing-this-study-does-not-settle)

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

These cells are single runs, so read them as *existence* results: they establish
that the baseline faults and roughly how fast, not a rate. Survival rows here
carry no statistical weight on their own — the
[powered crash matrix](#the-powered-crash-matrix) further down is what
supports the "survived" claims, with 20 runs per arm and a live control.

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

## Choosing the fix: the hazard is load-side

The obvious fix is a full `StoreLoad` barrier after the announce, and it works.
But it costs **+56%** on the hot path, and it fails a basic sanity check: *the
buggy code is safe on x86*. If the hazard were really a store-buffer /
`StoreLoad` problem, x86 would fault too — x86 permits `StoreLoad` reordering.
It does not fault. So the store-side diagnosis cannot be the whole story.

Reading the two sides together shows why:

```
Reclaimer:  STORE objectUnlinked = TRUE
            Interlocked.Increment(CurrentEpoch)   // locked RMW - already ordered
Reader:     LOAD  CurrentEpoch  -> E+1
            STORE slot = E+1                      // announce
            LOAD  objectUnlinked -> STALE FALSE   // <-- the bug
```

The reclaimer's side needs no help: `Interlocked.Increment` is a locked RMW, so
its unlink is already ordered before the epoch bump. This is textbook **message
passing**, and the broken side is the *reader's* **load→load** ordering.
Announcing `E+1` while your own view is still at `E` means vouching for an epoch
you have not caught up to — which raises `SafeToReclaimEpoch` and authorises the
reclaimer to free the very object you are about to read.

That diagnosis explains the architecture split exactly: **x86 gives every load
acquire semantics**, so the plain announce is already safe there; AArch64 does
not. The fix is therefore an **acquire load**, not a barrier:

```csharp
(*(tableAligned + entry)).localCurrentEpoch = Volatile.Read(ref CurrentEpoch);
```

### What each candidate costs and whether it works

| Refresh announce | TLA+ (`armlb`) | herd7 (official `aarch64.cat`) | ARM64 crashes | ARM64 violations | x86 cost |
|---|---|---|---|---|---|
| plain store | **VIOLATED** (255 states) | **ALLOWED** | **13 / 20** | **2,475 – 435,814** | — |
| release store | **VIOLATED** (175 states) | **ALLOWED** | crashed | **235,051 – 848,621** | — |
| plain + `DMB ISH` | HOLDS (155 states) | FORBIDDEN (0/5) | 0 / 20 | not measured | **+49% to +56%** |
| **acquire load** | **HOLDS** (235 states) | **FORBIDDEN** | **0 / 20** | **0, 0, 0** | **~0%** |

Cost column re-measured on the i7-12700K with the contended micro-benchmark
(8 threads, 5 s), each mode run in its own batch alongside an unmodified baseline
as a stability control. The baseline landed at 8.3 / 8.2 / 8.2 ns per operation
across the three batches, so within-batch comparisons are sound:

| Mode | Mops/s | ns/op | vs. baseline |
|---|---:|---:|---:|
| `baseline` (unfixed) | 974.55 | 8.2 | — |
| `casannounce`, plain refresh | 980.24 | 8.2 | ~0% |
| **`casannounce`, acquire load** | **971.12** | **8.2** | **~0%** |
| `casannounce`, `DMB ISH` refresh | 627.20 | 12.8 | **+56%** |
| `fullbarrier` implementation | 442.62 | 18.1 | **+120%** |

The acquire load is indistinguishable from the *unfixed* baseline at this
resolution — it replaces a plain load with `ldapr`, adding no barrier and no
extra memory traffic. The `DMB ISH` variants are the ones that cost, which is
the practical argument for diagnosing the hazard correctly rather than reaching
for the strongest available barrier.

Note the release store: it is *not* merely weaker than the fix, it violates at a
rate comparable to the unfixed baseline. That is the predicted result — a release
store orders the wrong side, publishing the slot while doing nothing to order the
reader's later loads — and it is the row that most clearly separates "a barrier
somewhere" from "the right barrier".

### Graded violation counts on ARM64

Crash-or-not is a coin flip, and distinguishing arms through a binary outcome
needs large samples. Quarantine mode replaces it with a *count*: the reclaimer
stamps a poison sentinel instead of unmapping, so the process never dies and each
run returns how many times a protected reader observed poison. Run as
`resume-and-refresh --quarantine --pairs 8 --rounds 10000000`, three interleaved
runs per arm:

| Arm | Violations (3 runs) | Sampled opportunities |
|---|---|---|
| `baseline` (unfixed) — **control** | **1,035,797 / 640,862 / 115,601** | 11.4M – 15.2M |
| `casannounce` + `LE_REFRESH_ORDER=plain` | **435,814 / 253,499 / 2,475** | 18.1M – 19.5M |
| `casannounce` + `LE_REFRESH_ORDER=release` | **478,515 / 848,621 / 235,051** | 6.0M – 13.9M |
| `casannounce` + acquire load (default) | **0 / 0 / 0** | 6.3M – 12.9M |
| `fullbarrier` | **0 / 0 / 0** | 12.5M – 17.3M |

What makes those zeros meaningful is the sensitivity control. `--self-test`
poisons every round, as if reclamation had been wrongly authorised every time; on
this machine it converted 297,375 of 297,381 sampled rounds into detections — a
conversion rate of **0.99998**, spread evenly across all ten deciles rather than
clustered at startup. So an arm that was fully broken should register violations
on the order of its sampled-opportunity count. The acquire load registered **zero
across roughly 30 million opportunities**. That is a strong null, not an absence
of testing.

This is also the measurement that rules out the harness itself being the source
of the faults: `fullbarrier` is a known-safe reference, and it reports exactly
zero while the baseline reports hundreds of thousands under identical conditions.
A harness generating false positives could not tell those two apart.

### The same matrix on x86-64: an architectural double dissociation

The diagnosis says the refresh hazard is *load-side* — the reader announces an
epoch it has not yet caught up to — and that x86 is immune to it because every
x86 load already has acquire semantics. That is a falsifiable prediction, and the
two architectures disagree in exactly the way it requires. Same harness, same
graded counts, `resume-and-refresh --quarantine --pairs 1 --rounds 30000000` with
eight disturber threads on distinct physical cores, three interleaved cycles:

| Arm | x86-64 violations (3 cycles) | x86 opportunities | ARM64 violations |
|---|---|---|---|
| `baseline` — **control** | **25 / 16 / 18** | 8.8M | 1,035,797 / 640,862 / 115,601 |
| `casannounce` + `plain` refresh | **0 / 0 / 0** | 8.9M | **435,814 / 253,499 / 2,475** |
| `casannounce` + `release` refresh | **0 / 0 / 0** | 10.3M | **478,515 / 848,621 / 235,051** |
| `casannounce` + acquire load | 0 / 0 / 0 | 9.6M | 0 / 0 / 0 |
| `fullbarrier` | 0 / 0 / 0 | 4.1M | 0 / 0 / 0 |

The two middle rows are the whole point. `plain` and `release` refresh violate on
ARM64 at rates comparable to the unfixed baseline, and on x86 they do not violate
at all — while the baseline violates on **both**. Three of the four candidate arms
carried *more* detector opportunity than the control did, so the x86 zeros are not
a power artifact.

That split is what a load-side diagnosis predicts and what a store-side one
cannot explain. If the hazard were the announce *store* escaping late, x86's store
buffer would expose it too, and `plain` would fault on both machines. Instead the
refresh hazard vanishes precisely where loads are already acquire. The baseline
still fails on x86 because its *other* defect is the acquire-side `SB` race — and
StoreLoad is the one reordering x86-TSO does permit. Each architecture sees the
half of the bug its memory model allows.

### The powered crash matrix

`resume-and-refresh --pairs 8`, 180 s cap, **20 runs per arm**, interleaved
across two Neoverse-N2 VMs so that no single arm can be biased by a slow VM or a
noisy-neighbour period:

| Arm | Crashed | Fastest crash |
|---|---:|---|
| `baseline` (unfixed) — **control** | **16 / 20** | 2.1 s |
| `casannounce` + `LE_REFRESH_ORDER=plain` | **13 / 20** | 1.7 s |
| `casannounce` + `LE_REFRESH_ORDER=fence` | 0 / 20 | — |
| `casannounce` + acquire load (default) | 0 / 20 | — |
| `fullbarrier` | 0 / 20 | — |

Fisher exact, plain (13/20) against the acquire load (0/20): **p = 1.3e-5**.
Against the baseline control: **p = 1.5e-7**. Every crash landed in
`Litmus<…>.ReaderLoop()`, i.e. the reader dereferencing a page the reclaimer had
already unmapped — the use-after-free itself, not an unrelated fault.

This matrix supersedes an earlier 10-run batch in which `fence` appeared to
crash 6/10 while the weaker acquire load survived — an impossible ordering that
turned out to be a stale binary predating a redeploy. It also supersedes every
3-run verdict in this study.

A release store fails because it orders the *wrong side*: it publishes the slot
but does nothing to order the reader's later loads.

The acquire load is not sufficient on its own — the **acquire-side** announce is
a different shape. It is store-buffering (`SB`), not message passing, and
release/acquire provably does not close `SB`; it needs the slot-claiming CAS.
The two announce sites fail differently and need different strengths, which is
why the fix has two parts.

Neither is the acquire side sufficient on its own. Strengthening *only* the
slot-claiming CAS, while leaving the refresh announce plain, still faults:

| `LE_ACQUIRE_ORDER` | `LE_REFRESH_ORDER` | `resume-and-refresh`, 180 s |
|---|---|---|
| `cas` | `plain` | **crashed 2/3** — control |
| `fence` | `plain` | **crashed 2/3** |
| `cas` | acquire load | survived 3/3 |
| `fence` | acquire load | survived 3/3 |

Only 3 runs per cell, which on its own is far too few — an arm that crashes
around half the time survives 3/3 by chance about one time in eight. This table
is reported for the *positive* rows only: the two `plain` cells crashing is
consistent with the 20-run `plain` rate of 13/20, and the point being made is
that adding a fence to the claim CAS does **not** rescue a plain refresh. The
two survival rows carry no weight here; the acquire load's 0/20 in the powered
matrix above is what supports it.

Adding a full `DMB ISH` after the claim CAS changes nothing while the refresh
announce stays plain, and adds nothing once it is fixed. On this path the
refresh acquire-load is the load-bearing change.

### What the hardware actually executes

Verified by dumping emitted JIT bytes and disassembling them (the
`DOTNET_JitDisasm` knobs produced no output), rather than by inference:

| Source | Emitted on arm64 | Notes |
|---|---|---|
| `Interlocked.CompareExchange` (LSE) | `casal x1, x21, [x0]` | herd7: FORBIDDEN |
| `Interlocked.CompareExchange` (no LSE) | `ldaxr` / `stlxr` + `dmb ish` | the trailing `dmb` is what makes it safe |
| `Volatile.Read(ref CurrentEpoch)` | `ldapr x2, [x2]` | no `dmb` — a genuine one-instruction fix |

The bare `ldaxr`/`stlxr` loop *without* the trailing barrier is **ALLOWED**
(unsafe): an acquire load composed with a release store yields no `StoreLoad`
edge. RyuJIT's `genCodeForCmpXchg` emits that barrier unconditionally at the
join label, so both codegen paths are sound.

Both complete sequences were then checked **as composed programs**, using the
exact mnemonics above rather than idealised stand-ins:

| Composed fix | herd7 verdict | witnesses |
|---|---|---|
| `casal` announce + `ldapr` refresh (LSE) | **FORBIDDEN** | 0/14 |
| `ldaxr`/`stlxr` + `dmb ish` announce + `ldapr` refresh (no LSE) | **FORBIDDEN** | 0/13, 0/21 |

Note `Volatile.Read` emits **`LDAPR`** (acquire-RCpc), not the stronger
**`LDAR`** (RCsc). That distinction was checked rather than assumed: run in the
same batch, the two are indistinguishable here (both `Never 0 6`), because this
hazard needs only load→load ordering, which RCpc supplies. The RCsc/RCpc
difference concerns ordering against an *earlier store-release*, which this
shape does not involve.

Both rows carry live controls: replacing `LDAPR` with a plain `LDR` is
**ALLOWED** (`Sometimes 1 7`), and making the writer's RMW relaxed
(`LDADDAL` → `LDADD`) flips the verdict back to **ALLOWED** — so the
`FORBIDDEN` depends on the writer genuinely publishing `objectUnlinked` before
`currentEpoch`, and is not an artifact of an over-constrained encoding.

That second control initially looked like it might be the RCsc/RCpc difference
showing up after all, since it was only ever run against `LDAPR`. It is not.
Filling in the missing cell settles it — the four combinations form a clean
double dissociation:

| reader's refresh load | writer's bump | verdict |
|---|---|---|
| `LDR` (plain) | `LDADDAL` | Allowed `1 7` |
| `LDAR` (RCsc) | `LDADDAL` | **Never `0 6`** |
| `LDAPR` (RCpc) | `LDADDAL` | **Never `0 6`** |
| `LDAR` (RCsc) | `LDADD` (relaxed) | Allowed `1 7` |
| `LDAPR` (RCpc) | `LDADD` (relaxed) | Allowed `1 7` |

`LDAR` and `LDAPR` agree in *every* cell. The acquire strength is what closes
the reader side and RCpc is enough for it; the relaxed-RMW allowance is a
**writer**-side defect that the reader cannot repair no matter how strong its
load. Both requirements are real and neither substitutes for the other.

The writer-side requirement is satisfied by construction in production:
`BumpCurrentEpoch` advances the epoch with `Interlocked.Increment`
(`LightEpoch.cs:368`), and .NET's `Interlocked` operations are specified as
fully sequentially consistent, so they compile to the `AL` form. The relaxed
cell is a what-if that exists to prove the encoding has teeth, not a reachable
production state.

### Open questions

These are recorded because they are not yet closed, not because they are
expected to fail:

* The non-LSE codegen path (`DOTNET_EnableArm64Atomics=0`) is now **half
  covered**. In shared-epoch mode the batch carried a live control and it fired:
  `baseline` crashed 4/4 (at 110.2 s, 57.7 s, 2.8 s, 20.1 s) while the fix
  survived 4/4, with 8/8 slot reuse — so on that path the fix is doing real
  work. In `resume-and-refresh` mode the control did **not** fire (`plain` 0/8,
  fix 0/8), which under the rule below means those eight survivals prove
  nothing: with LSE disabled the whole runtime's atomics change, and the
  `ldaxr`/`stlxr`/`dmb ish` sequence is plausibly slow enough to close the race
  window for every arm. Reported as *no coverage in that mode* rather than as a
  pass. (The non-LSE path is covered formally in both modes, by the composed
  litmus above.)
* **Whether the fix is exposed to the lost wakeup on ARM64.** This is now only
  half open. On **x86 it is settled and the answer is yes**: the fix publishes
  with `Volatile.Write` and then probes `waiterCount`, which is exactly the
  `volatile` arm of the hardware litmus below — measured at tens of thousands of
  lost wakeups per million trials. On ARM64 it escapes only if the probe emits
  `ldar` rather than `ldapr` (`STLR;LDAR` is forbidden, `STLR;LDAPR` is allowed),
  and the disassembly table above shows this JIT emitting `ldapr` for
  `Volatile.Read`, which points the same way. That is deliberately **not** being
  inferred — it is the same one-half-of-the-pair mistake documented below — and a
  disassembly of `Release()` is pending. It does not affect the recommended
  repair, which is correct on every target either way.

`WeakMemory.tla` cannot decide the RCsc/RCpc question either way — its acquire
abstraction does not distinguish the two, and says so in a comment at
`AcquireLoadFields`. That question is settled only by the herd7 rows above.

### A note on method

Two results in this study were retracted after being checked properly, both for
the same reason: **a test mode proves nothing unless a known-buggy build still
fails in it.**

A third instance of the same failure mode was caught in the harness itself. The
`LE_REFRESH_ORDER` knob accepted mode *names* and silently fell back to the
default for anything else — and the default is the **fixed** mode. So a control
invoked as `LE_REFRESH_ORDER=0` (the value the source comments use to describe
the plain store) would quietly run the fix, survive, and be recorded as
"the broken mode is safe". Unrecognised values now throw, and the banner prints
the *resolved* mode name rather than echoing the raw environment string, so the
run's own output states which arm it exercised. Any knob whose failure mode is
"silently becomes the safe configuration" will eventually manufacture a false
negative.

The unmap-mode harness had a related hole: it printed **nothing** about how much
it had actually reclaimed. A "survived" verdict is vacuous if the fix quietly
stopped reclaiming — a build that never frees a page cannot fault no matter how
broken its epoch logic is. Worse, the end-of-run summary only prints on normal
completion, and the ARM runs are killed at a time cap, so the numbers that would
have shown this never appeared at all. Both unmap harnesses now emit a progress
line every 10 s carrying the reclaimed-page count (and, in shared-epoch mode, the
slot-reuse report), so a killed run still leaves evidence that it was doing the
work its verdict claims. Measured on the fixed build, reclamation is unaffected:
`freedPages` equals the round count exactly. The ARM64 runs now carry the same
evidence from the time-capped runs themselves rather than from an auxiliary
finite run — on the **fixed** arm, `rounds=7,864,320 freedPages=7,864,321
slot reuse: 8/8` in shared-epoch mode, and `rounds=1,638,400
freedPages=1,638,401` in `resume-and-refresh`. A build reclaiming several million
pages while surviving is not surviving by failing to reclaim.

The one defect that ran the other way — manufacturing a **false alarm** rather
than a false negative — was in the PowerShell driver, and it briefly appeared to
demolish the fix: a batch reported *every* arm crashing 10/10, including the two
independently known-safe ones. On **Windows PowerShell 5.1**,
`Start-Process -PassThru` returns a process object that does not cache the
process handle, so after `WaitForExit` the `ExitCode` property yields `$null`
instead of the status. The classifier was

```powershell
if ($p.WaitForExit(180000)) { $code = $p.ExitCode; if ($code -ne 0) { 'CRASHED' } else { 'COMPLETED' } }
```

and `$null -ne 0` is `$true`, so **every** process that exited before the time
cap was stamped `CRASHED` and the `COMPLETED` branch was unreachable. Running
that batch's exact configuration through a byte-identical copy of the driver
reproduced it: all four arms were stamped `CRASHED` while all four printed their
normal end-of-run summary, at 26.8–60.1 s. (PowerShell 7 returns the status
correctly, which is why this never showed up locally; touching `$p.Handle` once
before `WaitForExit` fixes it on 5.1.)

What saved every other batch was an accident: they all pass
`--rounds 2000000000`, which cannot finish inside the 180 s cap, so "exited early"
really did imply "crashed" and the verdicts are sound. The one batch with a
`--rounds` small enough to *complete* is the only crash-verdict batch affected,
and it is discarded. The graded quarantine counts are parsed from the process
output rather than its status, so they were never affected — which is the general
lesson: **a verdict derived from a process's exit status is only as trustworthy as
the shell's ability to report that status, whereas one parsed from the program's
own output is self-describing.** Prefer instruments that say what they observed
over instruments that say only whether something died.

One more instance appeared in the *benchmark*, and it is the subtlest, because a
null result is exactly what one of these measurements was supposed to produce.
Pricing the drain-list release store against a plain store showed no difference —
correctly, as it turns out, but not for the reason the measurement supplied. The
contended harness's inner loop is `Resume(); Refresh(); Suspend();` and never
calls `BumpCurrentEpoch(Action)`, so the sites under test never executed. The
measurement showed that the instrument could not see the change, and "no
difference" and "no coverage" are indistinguishable in the output. A null result
needs a positive control every bit as much as a crash verdict does: something
that *would* have moved the number, to demonstrate the number can move. The claim
was re-established from disassembly instead, which does not depend on how often
the site runs.

The sharpest example: tuning `--reclaimer-delay` to maximise how often thereader is mid-dereference when a page is reclaimed looks like a large sensitivity
win, and is worthless. Holding the command and core pinning fixed and varying
only the delay, on the **known-buggy** baseline:

| `--reclaimer-delay` | Detector opportunity (`sampledRounds` / 30,000,000) | Violations found |
|---|---|---:|
| 0 | 2.8 M (~9%) | **13** |
| 200 | **30.0 M (~100%)** | **0** |

Ten times the detector reach, and it finds nothing — because the delay that
maximises detector opportunity also *closes the race window it is trying to
observe*. Spinning the reclaimer before it unlinks gives the reader's announce
all the time it needs to become visible, so the bug can no longer happen.
Harness knobs must be tuned to maximise the failure rate of the **control**,
never the reach of the detector; `sampledRounds` and self-test conversion are not
proxies for statistical power. Every hardware number in this document was taken
at delay 0 for that reason.

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
| [`tla/tsavorite/`](tla/tsavorite) | Two **real Tsavorite flows** run against each other, with Tsavorite's own barriers included. See below. |

Each epoch spec is built on top of `StoreBuffer.tla`.

## "But Tsavorite already adds the barrier anyway"

The most common objection to fixing `LightEpoch` is that it does not matter in
practice: whatever `LightEpoch` omits, Tsavorite's own interlocked operations
supply, so the announce is fenced by the time it matters.

That objection is **true for some Tsavorite flows and false for others**, and
the specs in [`tla/tsavorite/`](tla/tsavorite) pin down exactly where the line
falls. Both threads run real Tsavorite call sequences, and *every* interlocked
operation Tsavorite actually performs on those paths is modelled as a full
StoreLoad barrier — a deliberately generous reading of the objection.

The reclaimer is the same in all three specs: `AllocatorBase.ShiftHeadAddress`,
which fences twice (`MonotonicUpdate`'s `Interlocked.CompareExchange`, then
`BumpCurrentEpoch`'s `Interlocked.Increment`) before draining `OnPagesClosed` →
`FreePage`. Only the reader flow changes.

| Spec | Reader flow | Fence between announce and deref? | `tso` | `arm` |
| --- | --- | --- | --- | --- |
| [`TsavoriteReadAtAddress.tla`](tla/tsavorite/TsavoriteReadAtAddress.tla) | `BasicContext.ReadAtAddress` → `InternalReadAtAddress` | **none** | **VIOLATED** | **VIOLATED** |
| [`TsavoriteReadWithBucketLatch.tla`](tla/tsavorite/TsavoriteReadWithBucketLatch.tla) | `BasicContext.Read` → `InternalRead` | yes — `HashBucket.TryAcquireSharedLatch` CAS | HOLDS | HOLDS |
| [`TsavoriteTransactionalRead.tla`](tla/tsavorite/TsavoriteTransactionalRead.tla) | `TransactionalContext.Read` → **the same** `InternalRead` | **none** — `TransactionalSessionLocker` takes no latch | **VIOLATED** | **VIOLATED** |
| [`TsavoriteLogScanGetNext.tla`](tla/tsavorite/TsavoriteLogScanGetNext.tla) | `TsavoriteLogScanIterator.GetNext` | **none** | **VIOLATED** | **VIOLATED** |
| [`fixes/FixedTsavoriteReadAtAddress.tla`](tla/tsavorite/fixes/FixedTsavoriteReadAtAddress.tla) | `ReadAtAddress` on a fixed `LightEpoch` | yes — the fence in the announce itself | HOLDS | HOLDS |

Each spec gives the **same verdict under both memory models**. The memory model
is not the variable here — the flow is. The two reader flows differ in one
respect only: whether an interlocked operation happens to sit between the epoch
announce and the dereference of the epoch-protected page.

`InternalRead` takes an ephemeral shared bucket latch
(`FindTagAndTryEphemeralSLock` → `HashBucket.TryAcquireSharedLatch`, an
`Interlocked.CompareExchange`) before it touches the hybrid log. That CAS drains
the reader's store buffer, so the announce is visible to the reclaimer's
min-scan. The flow is safe — **by accident**. Nothing about that lock exists for
reclamation safety; it is concurrency control for the hash bucket.

`InternalReadAtAddress` takes no such latch. It says so explicitly:

> `// We do things in a different order here than in InternalRead, in part to handle NoKey (especially with Revivification).`

It checks the plain field `hlogBase.HeadAddress` (`public long`, not `volatile`)
and then calls `CreateLogRecord` → `GetPhysicalAddress` →
`*(pagePointers + pageIndex)`. Between the two announce stores and that
dereference there is no interlocked operation, no volatile access, and no
fence — so the store-buffer window is wide open, and TLC finds the
use-after-free **under plain x86-TSO**, not only under the weaker `arm` model.

The same gap exists on other paths, and they are modelled above rather than
merely asserted:

**Transactional sessions lose the accidental fence entirely.** `TryEphemeralSLock`
dispatches through `ISessionLocker`. Transactional sessions bind
`TransactionalSessionLocker`, whose `TryLockEphemeralShared` is:

```csharp
public bool TryLockEphemeralShared(... ref stackCtx)
{
    Debug.Assert(store.LockTable.IsLocked(ref stackCtx.hei), ...);
    return true;
}
```

No interlocked operation, no lock, no barrier — and `Debug.Assert` is compiled
out in Release, so in a shipping build the method is literally `return true`.
`Helpers.cs` states the reason outright: *"Manual locking already automatically
locks the bucket"* — the bucket was latched back at `BeginTransaction`, so no CAS
runs per operation. Those earlier locks cannot help: `TransactionalContext` calls
`UnsafeResumeThread` on **every** operation, so the announce store is issued
*after* them, and a barrier in the past cannot order a store in the future.
`TsavoriteTransactionalRead.tla` runs the *same* `InternalRead` code over the
*same* allocator with the *same* reclaimer as the spec that HOLDS, and it is
VIOLATED. The only variable is which session type the caller happened to pick.

**Scan and iterator paths take no bucket latch at all**, because there is no hash
bucket involved. `TsavoriteLogScanIterator.GetNext` calls `epoch.Resume()`, reads
the plain field `allocator.HeadAddress`, and dereferences
`allocator.GetPhysicalAddress(currentAddress)` — with nothing in between. It does
not even call `InternalRefresh`, so this flow is *weaker* than `ReadAtAddress`.
The same shape recurs in five further `GetNext`/`GetNextRaw` overloads on that
class, and in `SpanByteScanIterator`/`ObjectScanIterator`, which back `Log.Scan`
and compaction. The main-store iterator even documents the guarantee it is
relying on:

> `// Acquire the epoch BEFORE sampling Initializing / TailAddress / HeadAddress / pagePointers, so that any allocator state we read is consistent with the epoch we hold.`

That comment is exactly what the missing fence invalidates. Source order is not
visibility order: the announce can still be sitting in the store buffer while
those loads execute, so the allocator state read is *not* consistent with the
epoch held, and the reclaimer's min-scan never sees the iterator.

For balance, the paths that *are* safe: basic-session `Read`/`Upsert`/`RMW`/
`Delete` and all the pending-IO completion paths (`ContinuePendingRead`,
`ContinuePendingRMW`, `CompletePendingAsync`) do reach a `HashBucket` CAS before
any dereference. The bug is not everywhere — it is in whichever flows happen to
miss an unrelated lock.

Note also that `FreePage` is `ClearPage` (`Array.Clear`) plus an optional return
to a page pool — the page is *recycled*, not unmapped. The reader does not
fault; it silently reads zeroed or re-used bytes as a live record.

So "Tsavorite adds the barrier anyway" is not a property of Tsavorite. It is a
property of one code path, produced by a lock taken for unrelated reasons, that
no comment or test enforces, and that disappears the moment the caller switches
session type or iterates the log. Fixing `LightEpoch` covers every caller at
once; the alternative is auditing each flow individually and keeping that audit
correct forever.

---

## Is `Entry.threadId` still needed?

With the claim carried by a CAS on the epoch word itself, `threadId` no longer
participates in acquiring a slot, and the natural question is whether the field
can go.

It never participated in reclamation. `ComputeNewSafeToReclaimEpoch` and
`SuspendDrain` read `localCurrentEpoch` and nothing else, so no scan has ever
consulted `threadId` to decide what is safe to free. Under the original code it
served as the ownership word — `Interlocked.CompareExchange(ref entry.threadId,
myTid, 0)` — with the epoch announced separately afterwards, and that split is
exactly the bug. The fix collapses the two into one operation, at which point
ownership rests on the claim CAS plus the thread-private entry index in
`Metadata.Entries[instanceId]`. There is no ABA exposure, because the index is
invalidated in the same operation that frees the slot. There is no reentrancy to
protect either: `Acquire` asserts against nesting. Removing the field saves no
memory, since `Entry` is `[StructLayout(LayoutKind.Explicit, Size = 64)]` for
cache-line isolation and would stay 64 bytes.

Four specs check this. `CasAnnounceNoThreadId` and
`CasAnnounceTwoReadersNoThreadId` delete the field and hold; two controls on two
independent axes fail, so the holds are not artifacts of removing the field the
invariants were watching. `CasAnnounceNoThreadIdNoCas` fails on the *announce*
axis and `CasAnnounceNoThreadIdStaleIndex` on the *ownership* axis — the latter
adding a single action, a departing reader that issues a second `Release` through
a token it failed to invalidate.

### A verdict that turned out to be a theorem

Something initially looked wrong with these runs: the `tso` and `arm`
configurations explored *byte-identical* state spaces, where the same spec with
`threadId` present explores 4.3× more states under `arm` than under `tso`. A
relaxation knob that changes nothing usually means the knob is disconnected.

It is not. `StoreBuffer`'s `arm` flush may retire *any* pending store, while `tso`
retires only the head — so the two differ **only when a thread has two or more
stores in flight**. In the version that keeps `threadId`, the reader has exactly
two unfenced stores, publishing and clearing that field. Deleting it removes
both, and with them every unfenced store the reader had; the CAS is atomic and
the release is a single store. At one store in flight, `arm` and `tso` are the
same model by construction.

To make sure this was not hiding behind an over-strong model of the release —
`CasAnnounceNoThreadId` models `Volatile.Write` as a full barrier, which is more
than an `stlr` gives — `CasAnnounceNoThreadIdWeakRelease` weakens it to a store
that may linger in the buffer. It holds, and still identically across both
models, for the same structural reason. A release that lands late makes the slot
look *occupied* for longer, which is the conservative direction: it can delay
reclamation but never free under a live reader.

So the equality is the finding. The fix works because it leaves store-order
relaxation nothing to act on, and deleting `threadId` strengthens that rather
than weakening it.

### The one thing blocking removal

`ThisInstanceProtected()` is `kInvalidIndex != entry && (*(tableAligned +
entry)).threadId == Metadata.threadId` (`:272-276`). That second clause is doing
real work, and not only in assertions — it gates control flow in
`ThisInstanceProtectedAndSuspend` and `ResumeIfNeeded` (`:285`, `:355`).
`Metadata.Entries` is thread-static and indexed by `instanceId`, and `Dispose()`
recycles an `instanceId` without first checking that the table is empty. A thread
that holds a stale index for a disposed instance can therefore name a live slot
belonging to a *different* `LightEpoch` — and today the `threadId` comparison is
what disqualifies it. Remove the field and `Release()` would wipe another
thread's announcement, which is the original use-after-free by a different route.
This is the hazard `CasAnnounceNoThreadIdStaleIndex` encodes, and it is why that
control violates.

The removal is therefore safe only alongside a generation stamp on the entry
index, or a `Dispose()` that quiesces before recycling an `instanceId`. Since the
field costs nothing in a 64-byte padded struct, the honest recommendation is to
leave it in place and treat it as a debug assertion rather than as ownership
state — the CAS is what makes the algorithm correct, and `threadId` should no
longer be described as though it were.


## Other ordering defects in the same class

Auditing every ordering construct in the production class — rather than only the
announce — turned up three more sites. They are recorded here because two of them
are independent of the bug this document is about, and one of them is a
cautionary tale about how easy it is to get this reasoning wrong.

First, a negative result worth stating plainly: **the hot path is under-fenced,
not over-fenced.** `ProtectAndDrain`'s fast path contains no barrier at all — one
plain load, one plain store, two volatile reads — so there is nothing there to
remove. The single `Thread.MemoryBarrier()` in the class, in `SuspendDrain`, is
genuinely required *on x86 as well as ARM64*: it closes an `SB` pair between one
thread clearing its own slot and another scanning for the minimum, and x86-TSO
permits StoreLoad reordering. It is also on a cold path, since drain actions fire
at page or checkpoint granularity. Keep it exactly where it is.

**The drain list is published with plain stores.** `BumpCurrentEpoch` writes the
payload and then the field that publishes it:

```csharp
drainList[i].action = onDrain;              // plain store — the payload
drainList[i].epoch  = PriorEpoch;           // plain store — the publish
_ = Interlocked.Increment(ref drainCount);  // a fence, but after both stores
```

This is message passing with no release on the writer side, so the publishing
store may be reordered ahead of the payload by the JIT on any architecture, or by
ARM64 hardware. The interlocked increment does not save it: a fence placed *after*
both stores orders them against everything that follows, but says nothing about
their visibility relative to *each other*. Nor does the `drainCount > 0` gate that
guards every call into `Drain`, because a drainer already in flight — or one
admitted by a different slot's increment — has no ordering dependency on this
slot at all. The second branch of the same function, which reuses a reclaimable
slot at `:412-413`, performs the identical pair of plain stores with no
interlocked operation after them whatsoever.

A drainer can therefore observe the new epoch, win the claim CAS, and read
`action` as `null` or as the previous delegate — a `NullReferenceException` inside
reclamation, or a stale reclamation action run twice, which for a hybrid-log page
is a double free. The fix is a release store on the publish, and it is free: both
spellings compile to identical x86-64 machine code, so the change is one
`stlr`-for-`str` substitution on ARM64 and nothing at all elsewhere.

That last claim is worth a note on how it was established, because the obvious
route to it is vacuous. Benchmarking the two spellings showed no difference — but
the contended harness's inner loop is `Resume(); Refresh(); Suspend();` and never
calls `BumpCurrentEpoch(Action)`, so the three sites never execute during the
measurement. The null result showed the benchmark could not *see* the site, not
that the fix was cheap. The defensible evidence is the disassembly, which does
not depend on drain frequency at all.

**`Release()` unpublishes the slot with plain stores**, so prior loads from inside
the protected region may sink past the store that declares the slot free. The
realistic threat here is the compiler rather than the hardware, and it applies on
both architectures — the .NET memory model explicitly permits reordering ordinary
accesses, so the once-common belief that plain stores carry release semantics on
the CLR gives no protection.

### The lost wakeup, and two wrong answers on the way to it

The third finding is the interesting one, because it was analysed wrongly twice —
first too strongly, then too weakly — and the litmus tests are what settled it.
`Release()` and `ReserveEntryWait()` form an `SB` pair:

| Releaser (`Release`) | Waiter (`ReserveEntryWait`) |
|---|---|
| publish slot free | `Interlocked.Increment(waiterCount)` — full fence |
| load `waiterCount`; if `> 0`, signal | re-probe the slot; if still taken, sleep |

If the releaser reads a stale `0` while the waiter reads a stale non-zero, nobody
signals and the waiter sleeps forever on a slot that is free.

**The first answer** was that this is unconditional, because a volatile read is
only an acquire load and acquire does not close store buffering — the same
argument this document uses to reject the release-store candidate for the
announce. That is right about the .NET memory model and wrong about AArch64,
whose acquire/release are **RCsc**: an `LDAR` may not be reordered before an
earlier `STLR`, so the pair supplies StoreLoad ordering by itself. `LDAPR` is
RCpc and drops exactly that edge.

**The second answer** — mine — was that the hang therefore hinges on JIT codegen,
on whether a `volatile int` read becomes `ldar` or `ldapr` on a core implementing
`FEAT_LRCPC`. That is true of *the fixed implementation*, and it quietly assumed
the releaser's publishing store is an `STLR`. In production it is not.
`Release()` clears both words with **ordinary stores** (`:551-552`) and only then
does the volatile read of `waiterCount` (`:555`). The shape is `STR ; LDAR`, and
an `LDAR` constrains only what follows it — it places no ordering constraint on an
earlier plain store. Under ARM's official `aarch64.cat`:

| Releaser's store | Waiter's load | Waiter's RMW | Verdict |
|---|---|---|---|
| **`STR`** (production) | `LDAR` | `LDADDAL`+`CASAL` | **Sometimes 3 7 — allowed** |
| **`STR`** (production) | `LDAPR` | `LDADDAL`+`CASAL` | **Sometimes 3 7 — allowed** |
| `STLR` (the fix) | `LDAR` | `LDADDAL`+`CASAL` | **Never 0 7** — forbidden |
| `STLR` | `LDAPR` | `LDADDAL` | Sometimes 3 7 |
| `SWPAL` | `LDAR` | `LDADDAL` | Never 0 7 |
| `STLR ; DMB ISH` | `LDAR` | `LDADDAL` | Never 0 7 |
| `STLR` | `LDAR` | `LDADD` (relaxed) — **control** | Sometimes 3 7 |

Rows 1 and 3 differ in exactly one character of one instruction, `STR` versus
`STLR`, with the waiter byte-identical, so store strength is isolated as the
single variable. The last row is the sensitivity control: weakening the waiter's
RMW does produce the hang, which is what makes the `Never` verdicts worth
anything.

So the conclusion is the opposite of the one I published a few hours earlier.
**In production the lost wakeup is real and unconditional on AArch64**, and does
not depend on the unresolved `ldar`/`ldapr` codegen question at all. That question
only ever decided whether the *fixed* implementation is also exposed — and because
the fix publishes with `Volatile.Write`, it is not, at least on the RCsc reading.

It is also not confined to ARM64. `SB` is precisely the reordering x86-TSO
permits, and on x86 both the publish and the volatile probe are plain `mov`
instructions, so nothing orders them. The litmus tests above are AArch64 because
that is what `aarch64.cat` models, but the hazard itself is architecture-neutral
— and it reproduces on x86 hardware at roughly 2% of trials, measured below.

Two lessons generalise, and the second is the one that caught me. Reasoning at the
memory-model level tells you what is *permitted*, which is the right level for
deciding what to fix, but not what a given target *exhibits*; conflating them
produces confident claims in both directions. And when a pairwise ordering
argument saves you, check that **both** halves of the pair are what you assumed
— I had verified the load and inferred the store.

Graded honestly, this is liveness only, with no memory-safety consequence, and it
is unreachable until the epoch table is full, which needs more concurrently
protected threads than `max(128, 2 × ProcessorCount)`. Garnet does not do that
today. The unstated assumption keeping it safe is "the table is never full", and
that assumption is written down nowhere.

What makes it worth recording is that the code already *anticipates* this exact
race and mitigates it with something that cannot work. `ReserveEntryWait`
re-probes the slot after registering, and says why (`:648-651`):

> `// Re-check for free slot after incrementing waiterCount. This avoids us waiting on the semaphore forever in case we increment waiterCount immediately after the epoch releaser sees a zero waiterCount (and therefore does not release the semaphore).`

That is the right hazard, and the re-check would close it if the two threads'
operations were ordered against each other. They are not: the waiter's
`Interlocked.Increment` fences the waiter's *own* pair, but nothing forces the
releaser's clearing store to become visible before the releaser's load of
`waiterCount`. Both sides may read stale simultaneously, which is the definition
of `SB`, and a re-check on one side cannot repair a missing edge on the other.

### What the fix costs

This one is not ARM-specific, which narrows the repair options considerably.
`SB` is the canonical reordering that **x86-TSO also permits** — it is the same
pattern that makes the `Thread.MemoryBarrier()` in `SuspendDrain` necessary on
x86 — and on x86-64 a release store is a plain `mov`. So spelling the publish
`Volatile.Write` does nothing for this hazard on x86, and on ARM64 it helps only
under the RCsc reading.

That is not left as an argument from the memory model.
[`src/LightEpoch.SbLitmus`](src/LightEpoch.SbLitmus) runs the pair directly on
hardware — two threads, a rendezvous per trial, and a grader that counts trials
in which the releaser saw no waiter *and* the waiter saw the slot occupied. Both
spellings under test are measured against two positive controls in the same run.
On the x86-64 box (i7-12700K, 1,000,000 trials per arm, two interleaved cycles):

| arm | how the releaser publishes | lost wakeups | rate |
|---|---|---:|---:|
| `plain` | `slot = 0` — **production** | 24,952 / 19,084 | ~2% |
| `volatile` | `Volatile.Write(ref slot, 0)` | 46,927 / 15,184 | ~2–5% |
| `barrier` | `slot = 0; Thread.MemoryBarrier()` — control | **0 / 0** | 0 |
| `exchange` | `Interlocked.Exchange(ref slot, 0)` — control | **0 / 0** | 0 |

So the lost wakeup is not a theoretical reading of a `.cat` file: it happens on
ordinary x86 hardware in roughly one trial in fifty. The two controls sit at
exactly zero across four million trials, which is what makes the other two rows
mean something rather than being an artifact of the harness. And the `volatile`
row is the load-bearing one — **the release-store repair does not close this
hazard**, exactly as x86-TSO predicts, because there the release store *is* the
plain store.

That row also settles a question about *this repository's own fix*. The fixed
implementation's `Release()` publishes with `Volatile.Write` and then probes
`waiterCount`, which is precisely the `volatile` arm. So the fix inherits the
lost wakeup on x86 too. It is not a defect introduced by the fix — production has
it as well, and worse, since production is exposed on ARM64 unconditionally while
the fix is only exposed there under the RCpc reading — but it does mean the
announce repair and this repair are independent, and shipping one does not
address the other.

Priced on the same box, paired against a live control in the same batch:

| Repair | Cost | Closes the hang? |
|---|---:|---|
| publish with `Volatile.Write` (release store) | **0** — byte-identical x86 codegen | **no** on x86; ARM64 only, and only if the probe is `ldar` |
| publish with `Interlocked.Exchange` (`swpal`) | **+6.5 ns / +75%** | yes, everywhere — but far too expensive |
| `Thread.MemoryBarrier()` between publish and probe | +4.2 ns / +48% | yes, everywhere — still on the hot path |
| bound the sleep: `waiterSemaphore.Wait(timeout, …)` | **0** — slow path only | yes, everywhere |

The `Interlocked.Exchange` spelling is the expensive one: `xchg` must take the
actively contended slot line exclusive, where a `MemoryBarrier`'s `lock or
[rsp],0` touches the thread's own always-local stack line — the same "one locked
instruction" on paper, and 55% worse than the barrier it was proposed to replace.

So **bounding the wait is the recommendation**, and by some distance. It is the
only repair that is both free and correct on every target: it costs nothing
because it sits on the table-full slow path, it converts a permanent hang into a
bounded delay under every reading of the memory model, and it depends neither on
the architecture nor on which acquire instruction the JIT selects. The
alternatives all pay a per-operation price on the hottest path in the system to
fix a liveness bug that only manifests when the epoch table is full.


---

## What to change in production

Collecting the actionable conclusions in one place, with the evidence grade for
each. Costs are per-operation on the epoch hot path, measured on the x86 box
against a live control in the same batch.

| # | Change | Fixes | Cost | Evidence |
| --- | --- | --- | ---: | --- |
| 1 | **Announce via CAS on acquire, and refresh with an acquire load** (`Volatile.Read(ref CurrentEpoch)`) | use-after-free | **~0%** | hardware on two architectures + TLA+ + herd7 |
| 2 | **Release store on the drain-list publish** (3 sites) | `NullReferenceException` / double free of a hybrid-log page | **0** | code reading + identical codegen |
| 3 | **Release store on the `Release()` unpublish** | slot-handoff race, compiler sinking | **0** | code reading + identical codegen |
| 4 | **Bound the semaphore wait** in `ReserveEntryWait` | lost wakeup (hang) | **0** | hardware litmus + herd7 |
| 5 | Keep `Entry.threadId`, but stop treating it as ownership state | nothing — documentation | 0 | TLA+ |

Changes 2, 3 and 4 are free, and 2 and 4 are the ones a reviewer is most likely
to wave off. Both are real: the drain-list publish is unsynchronised message
passing whose payload is a delegate that gets invoked, and the lost wakeup
reproduces on ordinary x86 hardware at roughly one trial in fifty.

Equally important is what **not** to do. Three plausible-looking repairs were
priced and rejected, each because it puts a fence or a locked instruction on a
path that every Tsavorite operation traverses:

| Rejected repair | Cost | Why it was proposed |
| --- | ---: | --- |
| Full `StoreLoad` barrier after the announce | **+120%** | the obvious reading of "the announce needs a fence" |
| `DMB ISH` on the refresh path | **+56%** | targets the refresh announce specifically |
| `Interlocked.Exchange` for the unpublish or the wakeup | **+75%** | "it is only one locked instruction" |

The last is the most instructive. It *is* only one locked instruction, and it is
still worse than the full `MemoryBarrier` it was meant to replace, because `xchg`
must take the actively contended epoch slot exclusive while `lock or [rsp],0`
touches the thread's own always-local stack line. Instruction counts are not
costs.

### The one thing this study does not settle

Every result here concerns whether a given ordering is *permitted* and whether it
*reproduces*. Neither answers whether a particular shipping binary on a
particular core will exhibit it, and the gap between those questions is where
this investigation went wrong twice — once by treating an ARM-only diagnosis as
settled when the defect also reproduces on x86, and once by verifying one half of
an ordering pair and inferring the other. The fixes above are chosen so that they
do not depend on resolving that gap: each is correct under the weakest reading of
the .NET memory model, rather than under the strongest reading of what current
JIT output happens to emit.
