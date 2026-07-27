# LightEpoch and the missing StoreLoad fence

This repository is a self-contained, reproducible study of a **memory-ordering
bug in an epoch-based safe-memory-reclamation (SMR) scheme** called
`LightEpoch`. The epoch *enter* (announce) path publishes a thread's current
epoch with a **plain store and no StoreLoad fence**. On a weakly-ordered CPU
(**ARM64**) this lets the reclaimer's "safe-to-reclaim" scan miss a live reader
and free memory that the reader is about to dereference.

The bug is demonstrated in two complementary ways:

1. **A running C# repro** (`src/`) that links the epoch implementation
   unmodified and lets the epoch machinery *itself* free the object. On real
   Windows ARM64 the buggy build faults within seconds, every run; the fixed builds run
   indefinitely. On x86-64 the same buggy build does **not** fault.
2. **Formal TLA+ models** (`tla/`) of the x86-TSO and ARM64 memory models, and
   of the epoch algorithm with each candidate fix. TLC exhaustively finds the
   use-after-free in the baseline and proves each fix closes it.

> Terminology note: throughout, "fault" / "memory fault" / `0xC0000005` all
> mean the process touched memory that had been unmapped — the
> observable symptom of reclaiming memory that is still in use.

## Table of contents

- [1. The algorithm and the bug](#1-the-algorithm-and-the-bug)
  - [1.1 What an epoch protects](#11-what-an-epoch-protects)
  - [1.2 The enter path (the announce store)](#12-the-enter-path-the-announce-store)
  - [1.3 The race, as a Store-Buffer (SB) litmus](#13-the-race-as-a-store-buffer-sb-litmus)
- [2. Memory models: why x86 hides it and ARM64 exposes it](#2-memory-models-why-x86-hides-it-and-arm64-exposes-it)
  - [2.1 x86-64 (TSO — Total Store Order)](#21-x86-64-tso--total-store-order)
  - [2.2 ARM64 (AArch64 — a weak model)](#22-arm64-aarch64--a-weak-model)
  - [2.3 Why emulation cannot reproduce it](#23-why-emulation-cannot-reproduce-it)
- [3. The fixes](#3-the-fixes)
  - [3.1 Full barrier (the straightforward fix)](#31-full-barrier-the-straightforward-fix)
  - [3.2 Interlocked exchange (fold store + fence into one op)](#32-interlocked-exchange-fold-store--fence-into-one-op)
  - [3.3 Asymmetric barrier (move ordering to the reclaimer)](#33-asymmetric-barrier-move-ordering-to-the-reclaimer)
- [4. Repository layout](#4-repository-layout)
- [5. Running it](#5-running-it)
  - [5.1 The C# repro](#51-the-c-repro)
  - [5.2 The TLA+ models](#52-the-tla-models)
- [6. How the repros work](#6-how-the-repros-work)
  - [6.1 The two threads](#61-the-two-threads)
  - [6.2 Why a fault is a *real* use-after-free, not a segfault trick](#62-why-a-fault-is-a-real-use-after-free-not-a-segfault-trick)
  - [6.3 Why the epoch — not the harness — does the freeing](#63-why-the-epoch--not-the-harness--does-the-freeing)
  - [6.4 Keeping the harness from perturbing the race](#64-keeping-the-harness-from-perturbing-the-race)
  - [6.5 What each exit means](#65-what-each-exit-means)
- [7. Summary](#7-summary)
- [8. How Tsavorite actually uses LightEpoch](#8-how-tsavorite-actually-uses-lightepoch)
  - [8.1 The default path: acquire + release on *every* operation](#81-the-default-path-acquire--release-on-every-operation)
  - [8.2 The cheap "protect-once, Refresh" path exists — but it is opt-in and manual](#82-the-cheap-protect-once-refresh-path-exists--but-it-is-opt-in-and-manual)
  - [8.3 What this means for the bug and the fix](#83-what-this-means-for-the-bug-and-the-fix)
  - [8.4 Why acquire + release on every operation? (theories)](#84-why-acquire--release-on-every-operation-theories)
  - [8.5 Reproducing and modelling the default API directly](#85-reproducing-and-modelling-the-default-api-directly)
  - [8.6 Optimization: drop the redundant second announce](#86-optimization-drop-the-redundant-second-announce-protectanddrainwithoutannounce)

---

## 1. The algorithm and the bug

### 1.1 What an epoch protects

Epoch-based reclamation lets many reader threads access shared objects without
per-object locks or reference counts. The scheme keeps a **global epoch counter**
and, for each thread, a **slot** holding the epoch that thread most recently
entered ("announced"). To retire an object, a writer:

1. unlinks it so *new* readers cannot find it,
2. bumps the global epoch and remembers the object was retired in epoch `E`,
3. computes a **safe-to-reclaim epoch** = one less than the *oldest epoch any
   thread is still announced in*, by scanning every thread slot,
4. frees the object once its retire epoch `E ≤ safe-to-reclaim`.

The safety argument is: *a reader that entered before the object was unlinked has
announced an epoch ≤ E, so the scan will see it and hold the safe epoch below E
until that reader leaves.* This argument silently assumes the reader's announce
is **visible to the scanning core** by the time the reader dereferences the
object. That assumption is what breaks.

### 1.2 The enter path (the announce store)

The reader announces its epoch like this (this is the real code, in
`src/LightEpoch.Implementations/LightEpoch.cs`, at **two** sites — `Acquire()`
and `ProtectAndDrain()`):

```csharp
// Protect CurrentEpoch by copying it to the instance-specific epoch table
// so that ComputeNewSafeToReclaimEpoch() will see it.
(*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;   // PLAIN store — no fence

// ... then the thread goes on to read shared objects ...
```

And the reclaimer scans:

```csharp
long ComputeNewSafeToReclaimEpoch(long currentEpoch)
{
    var oldestOngoingCall = currentEpoch;
    for (var index = 1; index <= kTableSize; index++)
    {
        var entry_epoch = (*(tableAligned + index)).localCurrentEpoch;  // LOAD each slot
        if (0 != entry_epoch)                    // 0 == "thread absent" — SKIPPED
            if (entry_epoch < oldestOngoingCall)
                oldestOngoingCall = entry_epoch;
    }
    SafeToReclaimEpoch = oldestOngoingCall - 1;
    return SafeToReclaimEpoch;
}
```

### 1.3 The race, as a Store-Buffer (SB) litmus

Line the two threads up and it is textbook **Dekker / Store-Buffer**:

```
Reader (enter):                         Reclaimer (retire):
  STORE  slot   := myEpoch    (announce)  STORE  object.linked := false  (unlink)
  LOAD   object.linked                    <full fence: Interlocked bump of epoch>
  if linked: DEREFERENCE object           LOAD   slot   (the scan)
                                          if slot missed: FREE object
```

Both threads do **store then load of the other's location**. The forbidden
(sequentially-consistent-impossible) outcome is **both loads miss the other's
store**:

* the reader's `LOAD object.linked` still sees the object **linked** (the
  unlink hasn't reached it), so it dereferences, **and**
* the reclaimer's `LOAD slot` (the scan) still sees **0 / stale** (the announce
  hasn't reached it), so it computes a safe epoch past the reader and **frees**.

Result: the reader dereferences freed memory → fault.

Crucially, **only one of the two sides is missing a fence**:

* The **reclaimer** side is already correctly ordered — the unlink is followed by
  `Interlocked.Increment(CurrentEpoch)` inside `BumpCurrentEpoch`, a full barrier
  that drains the reclaimer's store buffer before the scan.
* The **reader** side has **no fence** between its announce store and its load of
  the object. That is the whole bug.

So the minimal fix is a single StoreLoad fence after the announce (applied at
both textual announce sites).

---

## 2. Memory models: why x86 hides it and ARM64 exposes it

The forbidden SB outcome is only *forbidden under sequential consistency*. Real
CPUs are not sequentially consistent: every mainstream architecture has
**per-core store buffers**, so a core can execute a later load before its own
earlier store has become globally visible. This single relaxation — **StoreLoad
reordering** — is exactly what the bug needs.

### 2.1 x86-64 (TSO — Total Store Order)

x86 is *strong*: its store buffer is **FIFO**, and the **only** reordering it
permits is StoreLoad. So the bug's window **does exist** on x86 in principle.
In practice it is almost never observed because:

* the store buffer drains to cache in a handful of cycles, and
* any `lock`-prefixed instruction (and .NET emits plenty around allocation,
  GC write barriers, and interlocked operations) fully drains it immediately.

So on x86 the reader's announce is visible to the scan essentially instantly, and
the buggy build runs to completion on Windows x86-64. This is why the defect
can sit in code for years: **all the CI and dev machines are x86.**

**The epoch's own code accidentally fences it on x86.** This is worth spelling
out, because it is the concrete reason the missing barrier is invisible in
practice. Every *enter* goes through `TryAcquireEntry`, which claims the thread's
slot in the epoch table with an `Interlocked.CompareExchange` on
`threadId` — a `lock cmpxchg`, i.e. a full fence — and every *reclaim* advances
the global epoch with `Interlocked.Increment` (`BumpCurrentEpoch`, a `lock`ed
`xadd`). These sit on the very same hot path as the announce, only a few
instructions away, and the GC and allocator sprinkle in more `lock`-prefixed
operations still. The slot-reservation CAS actually runs *just before* the plain
announce store, so it does not, by the letter of the model, order that store
ahead of the reader's later load — but its constant presence, on top of TSO's
few-cycle FIFO drain, means the store buffer is never allowed to hold the
announce long enough for a reclaimer on another core to miss it. The plain store
is, in effect, fenced *by luck*. Take the luck away — a weak architecture with no
incidental drain and no fast FIFO commit — and the same code faults immediately.
(You can see this CAS at `TryAcquireEntry` and the increment at
`BumpCurrentEpoch` in `src/LightEpoch.Implementations/LightEpoch.cs`.)

A subtle and important corollary, confirmed by the model: **an x86 release store
does not help.** On TSO, ordinary stores *already* have release semantics, and
release ordering says nothing about a *later load*. Only `MFENCE` (or a `lock`ed
RMW) orders StoreLoad. So "just make the field `volatile`" is **not** a fix.

TLA+ model: [`tla/memory-models/X86TSO.tla`](tla/memory-models/X86TSO.tla).
* `X86TSO_NoFence.cfg` → `SequentiallyConsistent` **VIOLATED** (the StoreLoad
  window is real even on TSO).
* `X86TSO_Fence.cfg` → **HOLDS** (an `MFENCE` between store and load closes it).

### 2.2 ARM64 (AArch64 — a weak model)

ARM is *weak*: besides StoreLoad it also permits StoreStore, LoadLoad, and
LoadStore reordering, its store buffer is **not** FIFO, and it is not
multi-copy-atomic. Concretely for this bug:

* The plain announce compiles to a relaxed `str`. There is **no** incidental
  fast-drain: the store can sit in the buffer while the core races ahead to load
  the object pointer. The window is **wide and routinely hit** — the C# repro
  faults within seconds on Neoverse-N2 / Cobalt-100 silicon.
* A **release** store (`stlr`, what `Volatile.Write` emits) still does **not**
  order the announce before a *later* load — release only orders *earlier*
  accesses before the store. So `Volatile.Write` does not fix it either.
* Only a **full barrier** `dmb ish` (what `Interlocked.MemoryBarrier` emits) or a
  **sequentially-consistent RMW** (`swpal` / `ldaxr`-`stlxr`, what
  `Interlocked.Exchange` emits) drains the buffer before the load.

TLA+ model: [`tla/memory-models/ARM64.tla`](tla/memory-models/ARM64.tla).
* `ARM64_None.cfg` → **VIOLATED** (plain store).
* `ARM64_Release.cfg` → **VIOLATED** (release / `stlr` is *not enough*).
* `ARM64_Full.cfg` → **HOLDS** (`dmb ish` / seq-cst RMW).

### 2.3 Why emulation cannot reproduce it

QEMU and other portable emulators execute guest code in a way that is
effectively sequentially consistent (or at least far stronger than real ARM):
they do not model per-core store buffers. So the buggy build **will not fault
under emulation** — you need genuine ARM64 hardware. Any Apple-silicon Mac, AWS
Graviton, Ampere, or Azure Cobalt/`Dpsv6` instance works.

---

## 3. The fixes

| Variant | File | What changes |
|---|---|---|
| **baseline** (buggy) | `LightEpoch.cs` | plain announce store |
| **full barrier** | `FixedLightEpoch.cs` | `Interlocked.MemoryBarrier()` after each announce |
| **interlocked exchange** | `FixedLightEpochWithInterlockedExchange.cs` | announce via `Interlocked.Exchange` (seq-cst RMW) |
| **asymmetric barrier** | `FixedLightEpochAsymmetricBarrier.cs` | announce stays a plain store; reclaimer issues a **process-wide** barrier before the scan |

### 3.1 Full barrier (the straightforward fix)

```csharp
(*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;
System.Threading.Interlocked.MemoryBarrier();   // StoreLoad fence
```

Correct and self-contained. Costs a full barrier on **every** epoch enter, which
is the read-mostly hot path.

### 3.2 Interlocked exchange (fold store + fence into one op)

```csharp
System.Threading.Interlocked.Exchange(
    ref (*(tableAligned + entry)).localCurrentEpoch, CurrentEpoch);
```

A single sequentially-consistent RMW both publishes the announce and carries the
StoreLoad ordering.

### 3.3 Asymmetric barrier (move ordering to the reclaimer)

Keep the reader announce a cheap plain store and move **all** the ordering cost
to the *rare* reclaimer. Before the safe-epoch scan, the reclaimer issues a
**process-wide** barrier that forces every other core to drain its store buffer:

* Windows: `FlushProcessWriteBuffers()`

Readers perform no additional barrier on the hot path; the reclaimer issues the
inter-processor interrupt. This is the technique used by RCU and by
managed-runtime garbage collectors. See
`src/LightEpoch.Implementations/AsymmetricBarrier.cs`.

All three fixes are proven safe in `tla/` (`FixedLightEpoch`,
`FixedLightEpochWithInterlocked`, `FixedLightEpochWithAsymmetricBarrier` all →
`NoUseAfterFree` HOLDS).

---

## 4. Repository layout

```
.
├── README.md
├── src/
│   ├── LightEpoch.Implementations/  # the 4 epoch variants (shared library)
│   │   ├── LightEpoch.cs                              # baseline (buggy)
│   │   ├── FixedLightEpoch.cs                         # full barrier
│   │   ├── FixedLightEpochWithInterlockedExchange.cs  # seq-cst RMW announce
│   │   ├── FixedLightEpochAsymmetricBarrier.cs        # reclaimer-side barrier
│   │   ├── AsymmetricBarrier.cs                       # FlushProcessWriteBuffers / membarrier
│   │   ├── UtilityShim.cs · EpochOps.cs
│   ├── LightEpoch.Repro.Common/     # shared, self-judging litmus harness
│   ├── LightEpoch.Repro.Bare/       # Resume -> access -> Suspend
│   └── LightEpoch.Repro.Tsavorite/  # Tsavorite BasicContext epoch sequence
└── tla/
    ├── memory-models/               # the memory models themselves
    │   ├── X86TSO.tla · ARM64.tla
    ├── LightEpoch.tla                              # buggy   -> VIOLATED
    ├── FixedLightEpoch.tla                         # fix 1   -> HOLDS
    ├── FixedLightEpochWithInterlocked.tla          # fix 2   -> HOLDS
    ├── FixedLightEpochWithAsymmetricBarrier.tla    # fix 3   -> HOLDS
    ├── LightEpochTsavorite.tla                     # Tsavorite per-op API, buggy -> VIOLATED
    ├── FixedLightEpochTsavorite.tla                # Tsavorite per-op API, fixed -> HOLDS
    └── run.sh · Dockerfile
```

---

## 5. Running it

### 5.1 The C# repros

Both repros use the same **self-judging** harness: it never decides to free anything. It hands each
retired page to the real `BumpCurrentEpoch(onDrain)` API and the epoch
implementation itself decides — via `ComputeNewSafeToReclaimEpoch` + `Drain` —
when to invoke `onDrain` (which unmaps the page). A fault therefore means the
epoch freed an object while a protected reader that had seen it linked was still
reading it.

They differ only in the epoch sequence immediately before the shared access:

| Project | Reader sequence per operation | Purpose |
|---|---|---|
| `LightEpoch.Repro.Bare` | `Resume()` → access → `Suspend()` | Minimal reproduction of the Acquire announce bug |
| `LightEpoch.Repro.Tsavorite` | `Resume()` → `InternalRefresh()`/`ProtectAndDrain()` → access → `Suspend()` | Epoch portion of a normal Tsavorite `BasicContext` operation |

Run on Windows with a .NET 10 SDK:

```bash
DOTNET_gcServer=1 dotnet run --project src/LightEpoch.Repro.Bare -c Release -- \
  --impl baseline --rounds 200000000
DOTNET_gcServer=1 dotnet run --project src/LightEpoch.Repro.Tsavorite -c Release -- \
  --impl baseline --rounds 200000000
```

Exit code `0` = survived (no reclaim while a protected reader held the page);
an access-violation termination (`0xC0000005`) = a fault was observed. On
Windows ARM64,
both baseline repros fault; the fixed implementations survive. See §8 for the
Tsavorite call sequence.

### 5.2 The TLA+ models

```bash
docker build -f tla/Dockerfile -t lightepoch-tla tla
docker run --rm lightepoch-tla        # checks all 12 specs and prints expected vs. actual
```

Expected outcomes:

| Spec | Config | Result |
|---|---|---|
| `X86TSO` | no fence | VIOLATED |
| `X86TSO` | MFENCE | HOLDS |
| `ARM64` | none | VIOLATED |
| `ARM64` | release | VIOLATED |
| `ARM64` | full | HOLDS |
| `LightEpoch` | — | VIOLATED |
| `FixedLightEpoch` | — | HOLDS |
| `FixedLightEpochWithInterlocked` | — | HOLDS |
| `FixedLightEpochWithAsymmetricBarrier` | — | HOLDS |
| `LightEpochTsavorite` (per-op `Resume`+`Refresh`+`Suspend`) | — | VIOLATED |
| `FixedLightEpochTsavorite` (both announce sites fenced) | — | HOLDS |
| `FixedLightEpochTsavoriteNoAnnounce` (fence only Acquire; drop 2nd announce) | — | HOLDS |

The last three model **Tsavorite's default per-operation API** (§8): the buggy
spec issues both announce stores (Acquire and ProtectAndDrain) with no fence and
is VIOLATED; fencing both sites HOLDS; and — the optimization — fencing **only**
Acquire while dropping the redundant second announce (`ProtectAndDrainWithoutAnnounce`)
also HOLDS (§8.6). A negative control confirms the model has teeth: removing the
Acquire fence too makes `FixedLightEpochTsavoriteNoAnnounce` VIOLATE.

---

## 6. How the repros work

The shared harness (`src/LightEpoch.Repro.Common`) is deliberately the smallest
program that turns the abstract Store-Buffer race into a real, hard memory fault — and it is
**self-judging**: the harness never decides to free anything. It only wires the
two real epoch operations into an SB shape and lets the epoch implementation
itself pull the trigger. If the process faults, the epoch algorithm freed a live
object; if it exits `0`, it didn't. There is no oracle to argue with.

### 6.1 The two threads

Two threads are pinned to two distinct physical cores (`WindowsNative.Pin`, via
`SetThreadAffinityMask`) so their store buffers are
genuinely separate hardware:

* **Reader** (`ReaderLoop`) — the *protected* accessor. The bare repro executes:
  ```
  ops.Resume();        // STORE announce:  localCurrentEpoch = CurrentEpoch   (the unfenced store under test)
  long p = curPage;    // LOAD  the object pointer
  if (p != 0)          // only dereference something that still looked linked
      read pg[0..deref] // <-- faults here if the page was unmapped
  ops.Suspend();
  ```
  The Tsavorite repro inserts `ops.Refresh()` between `Resume()` and the pointer
  load, matching `UnsafeResumeThread`'s `Resume()` + `InternalRefresh()` epoch
  sequence. `InternalRefresh()` begins with `ProtectAndDrain()`, which performs
  the second announce represented by `ops.Refresh()`.
* **Reclaimer** (`ReclaimerLoop`) — links, unlinks, and retires a page each round:
  ```
  page = WindowsNative.Alloc(4096); // a real OS page (VirtualAlloc)
  Volatile.Write(ref curPage, page);// link/publish the object
  --- round barrier ---
  curPage = 0;                      // STORE unlink (plain, like removing from a list)
  ops.BumpCurrentEpoch(() => WindowsNative.Free(page)); // hand the retired page to the epoch
  ```

Mapped onto the memory-model primer in §1.3, this is exactly the SB litmus:
each thread does *store-then-load of the other's location*. The forbidden
outcome — reader still sees `curPage != 0` **and** reclaimer's scan misses the
announce — is precisely a reclaim-while-reading, i.e. a fault.

### 6.2 Why a fault is a *real* use-after-free, not a segfault trick

`WindowsNative.Alloc` maps a **whole OS page** and `WindowsNative.Free` **fully
unmaps** it (`VirtualFree(MEM_RELEASE)`). So the freed page's virtual addresses
become invalid at the hardware level — a subsequent read is a genuine access
violation (`0xC0000005`), not a
poisoned-value check we could get wrong. The page is 4 KB and the reader touches
`pg[k & 511]` (the first 512 longs), so any read after unmap lands in the hole.

### 6.3 Why the epoch — not the harness — does the freeing

This is the crux of "self-judging". The reclaimer does **not** call
`WindowsNative.Free` directly. It passes the unmap as the `onDrain` callback to
the real public API `BumpCurrentEpoch(onDrain)`. Inside the epoch implementation,
the page is
only unmapped when the epoch's own `ComputeNewSafeToReclaimEpoch` +
`Drain` logic decides the retire epoch is safe — i.e. when its scan of the
thread slots concludes no reader is still in an older epoch. So a fault can only
happen if that scan **missed the reader's announce**. The harness contributes no
reclamation policy of its own; it just exercises the algorithm's real decision.

The reclaimer side is *already* correctly fenced: `BumpCurrentEpoch` does an
`Interlocked.Increment(CurrentEpoch)`, a full barrier that orders the `curPage = 0`
unlink before the safe-epoch scan. So the only unordered access left in the whole
loop is the reader's announce store — which is exactly the fence the bug is
missing.

### 6.4 Keeping the harness from perturbing the race

Two design choices ensure the harness measures the epoch, not itself:

* **Devirtualized dispatch.** `Litmus<TOps>` is generic over a `struct, IEpochOps`
  adapter (`BaselineOps`, `FullBarrierOps`, …). The JIT specializes the generic
  per struct and inlines `Resume`/`Suspend`/`BumpCurrentEpoch` down to the
  concrete epoch calls, so there is no virtual-call barrier or indirection
  sitting between the announce store and the object load.
* **A two-phase sense-reversing barrier** (`StartBarrier`/`EndBarrier`) realigns
  the two threads every round so their store/load windows overlap on real
  hardware — without this the two loops drift and the window is rarely hit. The
  barrier brackets the race region; it is *outside* the announce→deref window, so
  it doesn't add ordering to the accesses under test.

### 6.5 What each exit means

* **Reader faults mid-dereference** → the epoch freed a page a protected reader
  was reading → the process terminates with access violation `0xC0000005`. This
  is the bug, and on Windows ARM64 the `baseline` build hits it within seconds,
  every run.
* **Loop completes all rounds** → prints `Completed N rounds ... with NO fault`
  and returns `0`. This is what all three fixes do — indefinitely — and what
  even the `baseline` does on x86-64 (its store buffer drains too fast for the
  window to be observed).

Selecting the implementation is just `--impl baseline|fullbarrier|interlocked|asymmetric`;
everything else (page size, dereference count, the two core ids) is identical
across variants, so the *only* thing that changes between a faulting run and a
clean run is whether the announce store carries a StoreLoad fence.

---

## 7. Summary

* The epoch **enter** path publishes the announce with a plain store and no
  StoreLoad fence, while the algorithm's correctness depends on that announce
  being visible to the reclaimer's scan.
* This is a Store-Buffer race. It is a **memory-model bug**, not a logic bug:
  the code is correct under sequential consistency and effectively correct on
  x86-TSO, but **wrong on ARM64**, where the buggy build faults within seconds.
* A **release store / `Volatile.Write` is not a fix** — only a full StoreLoad
  barrier, a seq-cst RMW, or an asymmetric reclaimer-side barrier is.
* All of this is checked mechanically (TLA+) and demonstrated on real hardware
  (the C# repro).

---

## 8. How Tsavorite actually uses LightEpoch

The safety impact depends on **how often Tsavorite enters the epoch** and which
announce path it uses, so it is worth being precise about the call pattern.

Tsavorite `BasicContext` brackets each normal read/upsert/RMW/delete with
`UnsafeResumeThread()`/`UnsafeSuspendThread()`. `UnsafeResumeThread()` calls
`epoch.Resume()` followed by `store.InternalRefresh(...)`, whose first epoch
operation is `epoch.ProtectAndDrain()`.

`LightEpoch` exposes two very different ways to protect work:

* **`Resume()` / `Suspend()`** — `Resume()` calls `Acquire()`, which *reserves a
  fresh slot* in the epoch table (`ReserveEntryForThread` → `TryAcquireEntry`, an
  `Interlocked.CompareExchange`) and then publishes the announce store.
  `Suspend()` calls `Release()`, which *gives the slot back* (clears
  `threadId`/`localCurrentEpoch` and resets the thread's entry to
  `kInvalidIndex`). This is the **heavy** path: a locked slot-reservation RMW plus
  an announce on the way in, and a teardown on the way out.
* **`ProtectAndDrain()`** — the **cheap refresh**: it assumes the thread is
  *already* protected (a slot is already reserved) and simply re-publishes the
  announce (`localCurrentEpoch = CurrentEpoch`) and drains pending actions. No
  slot reservation, no `Interlocked.CompareExchange`.

The intended high-throughput idiom is therefore: `Resume()` **once**, then run
many operations while calling `ProtectAndDrain()` (Refresh) periodically, then
`Suspend()` **once**. That amortizes the expensive acquire/release over many
operations.

### 8.1 The default path: acquire + release on *every* operation

Tsavorite's default, safe API — `BasicContext` — does **not** do that. Every
single `Read` / `Upsert` / `RMW` / `Delete` wraps the operation in a full
resume/suspend:

```csharp
// BasicContext<...>.Read (representative of every BasicContext operation)
public Status Read(TKey key, ref TInput input, ref TOutput output, TContext ctx = default)
{
    UnsafeResumeThread();                              // enter
    try     { return store.ContextRead(key, ref input, ref output, ctx, sessionFunctions); }
    finally { UnsafeSuspendThread(); }                 // exit
}
```

and `UnsafeResumeThread` is itself *more* than a bare `Resume()` — it acquires
**and immediately refreshes**:

```csharp
internal void UnsafeResumeThread(...)
{
    store.epoch.Resume();          // Acquire: slot-reservation CAS + announce store
    store.InternalRefresh(...);    // InternalRefresh -> epoch.ProtectAndDrain(): a SECOND announce + drain
}

internal void UnsafeSuspendThread() => store.epoch.Suspend();   // Release: give the slot back
```

So a single `BasicContext` operation pays, **every time**:

1. `epoch.Resume()` → `Acquire()` → `TryAcquireEntry`'s `Interlocked.CompareExchange`
   (a `lock cmpxchg` / `casal`) to reserve a slot, then the announce store;
2. `InternalRefresh()` → `epoch.ProtectAndDrain()` → a *second* announce store plus
   the drain check;
3. the actual operation;
4. `epoch.Suspend()` → `Release()` → tear the slot back down.

Because `Suspend()`/`Release()` resets the thread's entry to `kInvalidIndex` and
clears `threadId`, the **next** operation cannot reuse the reservation cheaply —
it must run `TryAcquireEntry`'s `Interlocked.CompareExchange` again. In other
words, the read-mostly hot loop pays the *acquire* machinery (including a locked
RMW) on **every** operation, not once per protected region. The same pattern
holds for `TsavoriteLog`, whose `Enqueue`/`Commit`/read entry points each wrap
their body in `epoch.Resume()` … `epoch.Suspend()`.

### 8.2 The cheap "protect-once, Refresh" path exists — but it is opt-in and manual

Tsavorite *does* offer the amortized idiom, via `UnsafeContext` (documented "for
advanced use only"). There you call `BeginUnsafe()` once, run many operations —
each of which merely asserts it is already protected and does **no**
resume/suspend — refresh periodically, and `EndUnsafe()` once:

```csharp
public void BeginUnsafe() => clientSession.UnsafeResumeThread(sessionFunctions);   // once
public Status Read(...)   { Debug.Assert(store.epoch.ThisInstanceProtected()); ... } // no Resume/Suspend
public void EndUnsafe()   => clientSession.UnsafeSuspendThread();                    // once
```

This is the pattern that would make the enter/exit cost — and therefore the cost
of *any* announce fix — a per-*batch* cost rather than a per-*operation* cost. But
it shifts the burden of correct epoch management (and periodic `Refresh`) onto
the caller, so it is not what the default API does.

### 8.3 What this means for the bug and the fix

Two consequences fall out of "the default path acquires and releases on every
operation":

* **The incidental x86 fence (§2.1) fires on every default operation.** Since
  each `BasicContext` operation runs `TryAcquireEntry`'s
  `Interlocked.CompareExchange` (a full fence on x86) right before the announce,
  the store buffer is drained on essentially every enter. That is a second,
  independent reason the missing StoreLoad fence is invisible on x86 in
  Tsavorite specifically — not just "store buffers drain fast," but "a locked RMW
  runs on the same hot path, every op."
* **The per-operation pattern reopens the vulnerable window on every command.**
  `Suspend()`/`Release()` resets the slot to
  `kInvalidIndex` and `localCurrentEpoch` to `0` at the end of *every* operation,
  and the next `Resume()`/`Acquire()` re-announces `0 → CurrentEpoch`. That
  `0 → E` transition is the dangerous one: while it is buffered, the reclaimer's
  scan reads `lce == 0` and treats the reader as **absent**, computing a safe
  epoch straight past a live reader. The default `BasicContext` API therefore
  **re-opens the "absent reader" window on every single operation** — which is
  why both dedicated baseline repros fault within seconds on ARM64 (§8.5). The
  additional `ProtectAndDrain()` announce in the Tsavorite sequence is another
  plain store; it does not provide the missing StoreLoad ordering.

### 8.4 Why acquire + release on every operation? (theories)

Nothing forces `BasicContext` to acquire and release per operation; the amortized
`UnsafeContext` path (§8.2) is strictly cheaper. So why is the *default* API the
expensive one? The Tsavorite source does not spell out the rationale, but the
following reasons are strongly implied by the code and the surrounding contracts:

1. **A self-contained, safe default.** `BasicContext` is the "just works" API. If
   each call acquires and releases, the caller never has to reason about epoch
   lifetime, never leaks protection, and cannot forget to `Refresh()`. Protection
   that spans exactly one call is trivially correct; protection that spans many
   calls is the caller's problem — which is precisely why the amortized version
   is quarantined behind `UnsafeContext` and documented "for advanced use only."
2. **Re-entrancy and async safety.** `Acquire()`'s own assert warns: *"Make sure
   you do not re-enter Tsavorite from callbacks or IDevice implementations. If
   using tasks, use `RunContinuationsAsynchronously`."* Holding a slot across
   operations means holding it across anything those operations call — I/O
   completions, user callbacks, `await` points. A slot pinned across an `await`
   that resumes on a **different thread** is a correctness bug (the epoch table is
   thread-indexed). Releasing at the end of every operation sidesteps that entire
   class of hazards.
3. **Reclamation progress / bounded epoch lag.** A thread that holds a slot pins
   the global safe-to-reclaim epoch at whatever it last announced. A long-lived
   `BasicContext` session that acquired once and never refreshed would **stall
   reclamation** for everyone. Releasing per operation guarantees the thread
   contributes no back-pressure between calls — its slot is simply absent, so the
   safe epoch can always advance.
4. **Composability of independent sessions.** The per-op model lets a thread
   freely interleave operations from different sessions/stores without tracking
   which epoch instances it currently holds — each op is a closed
   acquire→work→release transaction.

The irony the memory-model analysis exposes: the choice that makes the default
API *safe and simple* at the data-structure level (release every op) is exactly
the choice that makes the *missing hardware fence* bite on every op (re-opening
the `lce == 0` window each `Resume()`). The amortized path most people are told
**not** to use is, for this specific bug and access pattern, the one that hides
it best.

### 8.5 Reproducing and modelling the default API directly

The default `BasicContext` sequence is exercised by both the executable repro
and the formal model:

* **Repros.** `LightEpoch.Repro.Tsavorite` runs the epoch-critical
  `UnsafeResumeThread` (`Resume()` + `InternalRefresh()`/`ProtectAndDrain()`) …
  `UnsafeSuspendThread` sequence per operation. `LightEpoch.Repro.Bare` omits
  only the refresh to isolate the original Acquire announce. On ARM64
  Neoverse-N2 both baselines **fault with
  `System.AccessViolationException` (`0xC0000005`)**; all three fixes run
  indefinitely:

  | Project | baseline | fullbarrier | interlocked | asymmetric |
  |---|---|---|---|---|
  | `LightEpoch.Repro.Bare` | **access violation** | survives | survives | survives |
  | `LightEpoch.Repro.Tsavorite` | **access violation** | survives | survives | survives |

* **TLA+ (`LightEpochTsavorite` / `FixedLightEpochTsavorite`).** The per-op
  `Acquire`-announce → `ProtectAndDrain`-announce → operation-load → `Release`
  sequence, model-checked exhaustively: the unfenced spec is **VIOLATED**, and
  fencing both announce sites **HOLDS**.

### 8.6 Optimization: drop the redundant second announce (`ProtectAndDrainWithoutAnnounce`)

Because `UnsafeResumeThread` runs `Resume()` (Acquire) and `InternalRefresh()`
(`ProtectAndDrain()`) **back-to-back**, the two announce stores are almost
always redundant with each other: Acquire publishes `localCurrentEpoch =
CurrentEpoch`, and — with no epoch bump in between — `ProtectAndDrain` writes the
same value again. On the *original* code that redundant plain store is nearly
free. On a **fixed** implementation the fix puts a `StoreLoad` fence after each
announce, so the per-operation path unnecessarily pays for two fences.

The second fence is unnecessary. The only state that causes the use-after-free
is `localCurrentEpoch == 0` ("reader absent" → the reclaimer scans past it). That
state is created **only** by the `0 → E` transition in `Acquire`; the
`ProtectAndDrain` announce is a monotonic `E → E'` advance that never re-opens
the absent window, and a delayed `E → E'` store merely leaves the reclaimer
seeing the older `E ≤ E'` — *more* conservative, never less. So fencing
**Acquire alone** is sufficient, and the immediately-following refresh can skip
the announce entirely and only drive drain/progress:

```csharp
// FixedLightEpoch.cs
public void ProtectAndDrainWithoutAnnounce()
{
    ref var entry = ref Metadata.Entries.GetRef(instanceId);
    // Resume()/Acquire already published localCurrentEpoch behind a StoreLoad
    // fence; it is still this thread's newest announce, so no store/fence here.
    if (drainCount > 0)
        Drain((*(tableAligned + entry)).localCurrentEpoch);

    if (waiterCount > 0)
        SuspendResume();
}
```

A hot path that resumes-then-refreshes (Tsavorite's `UnsafeResumeThread`) would
call `Resume()` (fenced announce) + `ProtectAndDrainWithoutAnnounce()` (no fence),
eliminating one of the two per-operation fences with no change to the reclaimer.

**Proved, not asserted.** `tla/FixedLightEpochTsavoriteNoAnnounce.tla` models
exactly this — Acquire announces + fences, the refresh performs no announce — and
`NoUseAfterFree` **HOLDS** exhaustively. A negative control (removing the Acquire
fence as well) makes the same spec **VIOLATE**, confirming the single Acquire
fence is precisely what closes the window and the dropped second announce/fence
was pure overhead. This applies only when the refresh immediately follows a
`Resume()`; a standalone `ProtectAndDrain()` on an already-protected thread (the
amortized `UnsafeContext` idiom) still needs its own fence, because there is no
preceding fenced Acquire in that path.
