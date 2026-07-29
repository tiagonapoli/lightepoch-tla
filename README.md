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
But it costs **+49%** on the hot path, and it fails a basic sanity check: *the
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
| plain + `DMB ISH` | HOLDS (155 states) | FORBIDDEN (0/5) | 0 / 20 | not measured | **+49%** |
| **acquire load** | **HOLDS** (235 states) | **FORBIDDEN** | **0 / 20** | **0, 0, 0** | **+0.4%** |

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
**ALLOWED**, and making the writer's RMW relaxed flips `LDAPR` back to
**ALLOWED** (`Sometimes 1 7`) — so the `FORBIDDEN` depends on the writer
genuinely publishing `objectUnlinked` before `currentEpoch`, and is not an
artifact of an over-constrained encoding.

### Open questions

These are recorded because they are not yet closed, not because they are
expected to fail:

* The non-LSE codegen path has been exercised on hardware, but that batch had no
  live sensitivity control, so under the rule below it currently proves nothing.
  (The non-LSE path *is* covered formally, by the composed litmus above.)
* One ARM batch reported every arm — including the two known-safe ones —
  terminating at a tight 42–56 s cluster. It ran with a finite `--rounds 1000000`
  where every other batch used the 200,000,000 default, and at the measured
  throughput that count *completes* in about that time; the same configuration
  reproduced on x86 exits cleanly with a zero status. So these are very likely
  normal completions counted as crashes rather than faults, and the quarantine
  counts above (`fullbarrier` and the acquire load at exactly zero) are hard to
  reconcile with them being real. It is listed here rather than discarded because
  the per-run exit codes have not yet been re-audited.

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
`freedPages` equals the round count exactly.

The sharpest example: tuning `--reclaimer-delay` to maximise how often the
reader is mid-dereference when a page is reclaimed looks like a 250x sensitivity
win, and is worthless. At `--reclaimer-delay 200` the reader is inside the page
on 99.9% of rounds (`sampledRounds=19,990,219`) and a *known-buggy* baseline
produces **zero** violations — the delay that maximises detector opportunity
also closes the epoch race window. Harness knobs must be tuned to maximise the
failure rate of the **control**, never the reach of the detector.

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

