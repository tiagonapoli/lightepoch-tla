# LightEpoch and the missing StoreLoad fence — a memory-model bug, proven five ways

This repository is a self-contained, reproducible study of a **memory-ordering
bug in an epoch-based safe-memory-reclamation (SMR) scheme** called
`LightEpoch`. The epoch *enter* (announce) path publishes a thread's current
epoch with a **plain store and no StoreLoad fence**. On a weakly-ordered CPU
(**ARM64**) this lets the reclaimer's "safe-to-reclaim" scan miss a live reader
and free memory that the reader is about to dereference.

The bug is demonstrated at five independent levels, all in this repo:

1. **A running C# repro** (`src/`) that links the epoch implementation
   unmodified and lets the epoch machinery *itself* free the object. On real
   ARM64 the buggy build faults within seconds, every run; the fixed builds run
   indefinitely. On x86-64 the same buggy build does **not** fault.
2. **Formal TLA+ models** (`tla/`) of the x86-TSO and ARM64 memory models, and
   of the epoch algorithm with each candidate fix. TLC exhaustively finds the
   use-after-free in the baseline and proves each fix closes it.
3. **The Store-Buffer litmus on the official ISA models** (`herd7/`) — the same
   race run through `herd7` against Intel's x86-TSO and Arm's AArch64 reference
   models, confirming the architects' own specs allow it on ARM64 and that a
   release store does not fix it.
4. **The actual JIT disassembly** (`disasm/`) of the announce path on x86-64 and
   AArch64, showing the single instruction each fix adds (`dmb ish` / `swpal` /
   `lock or` / `xchg`) — and that a release store would not have sufficed.
5. **A BenchmarkDotNet project** (`bench/`) measuring what each fix costs, so the
   choice of fix is informed by data, not folklore.

> Terminology note: throughout, "fault" / "memory fault" / `0xC0000005` /
> exit 134 all mean the process touched memory that had been unmapped — the
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
  - [3.3 Asymmetric barrier (best for read-heavy workloads)](#33-asymmetric-barrier-best-for-read-heavy-workloads)
- [4. Repository layout](#4-repository-layout)
- [5. Running it](#5-running-it)
  - [5.1 The C# repro](#51-the-c-repro)
  - [5.2 The TLA+ models](#52-the-tla-models)
  - [5.3 The benchmarks](#53-the-benchmarks)
  - [5.4 The herd7 litmus tests](#54-the-herd7-litmus-tests)
  - [5.5 The JIT disassembly](#55-the-jit-disassembly)
- [6. How the repro works](#6-how-the-repro-works)
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
the buggy build runs to completion — see `Dockerfile.x86`. This is why the defect
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

| Variant | File | What changes | Reader hot-path cost | Reclaim cost |
|---|---|---|---|---|
| **baseline** (buggy) | `LightEpoch.cs` | plain announce store | none | none |
| **full barrier** | `FixedLightEpoch.cs` | `Interlocked.MemoryBarrier()` after each announce | one `dmb ish` per enter | none |
| **interlocked exchange** | `FixedLightEpochWithInterlockedExchange.cs` | announce via `Interlocked.Exchange` (seq-cst RMW) | one atomic RMW per enter | none |
| **asymmetric barrier** | `FixedLightEpochAsymmetricBarrier.cs` | announce stays a plain store; reclaimer issues a **process-wide** barrier before the scan | **none** | one `FlushProcessWriteBuffers` / `membarrier` per reclaim |

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
StoreLoad ordering. One instruction instead of a store followed by a barrier;
often cheaper than `str; dmb ish` on ARM64.

### 3.3 Asymmetric barrier (best for read-heavy workloads)

Keep the reader announce a cheap plain store and move **all** the ordering cost
to the *rare* reclaimer. Before the safe-epoch scan, the reclaimer issues a
**process-wide** barrier that forces every other core to drain its store buffer:

* Windows: `FlushProcessWriteBuffers()`
* Linux: `membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED)`

Readers pay **nothing** on the hot path; the reclaimer pays a heavy inter-processor
interrupt, amortized because reclamation is batched. This is exactly the technique
used by RCU and by managed-runtime garbage collectors. See
`src/LightEpoch.Implementations/AsymmetricBarrier.cs`.

All three fixes are proven safe in `tla/` (`FixedLightEpoch`,
`FixedLightEpochWithInterlocked`, `FixedLightEpochWithAsymmetricBarrier` all →
`NoUseAfterFree` HOLDS).

---

## 4. Repository layout

```
.
├── README.md
├── Dockerfile.arm64                 # runs the repro on real ARM64 (faults on baseline)
├── Dockerfile.x86                   # control: same source does NOT fault on x86-64
├── src/
│   ├── LightEpoch.Implementations/  # the 4 epoch variants (shared library)
│   │   ├── LightEpoch.cs                              # baseline (buggy)
│   │   ├── FixedLightEpoch.cs                         # full barrier
│   │   ├── FixedLightEpochWithInterlockedExchange.cs  # seq-cst RMW announce
│   │   ├── FixedLightEpochAsymmetricBarrier.cs        # reclaimer-side barrier
│   │   ├── AsymmetricBarrier.cs                       # FlushProcessWriteBuffers / membarrier
│   │   ├── IEpochAccessor.cs · UtilityShim.cs · EpochOps.cs
│   └── LightEpoch.Repro/            # the litmus workload (self-judging)
│       ├── Program.cs · Plat.cs     # --pattern bare|tsavorite|refresh
├── bench/
│   ├── LightEpoch.Bench/            # BenchmarkDotNet: cost of each fix
│   └── results/                     # checked-in ARM64 + x86 benchmark reports
└── tla/
    ├── memory-models/               # the memory models themselves
    │   ├── X86TSO.tla · ARM64.tla
    ├── LightEpoch.tla                              # buggy   -> VIOLATED
    ├── FixedLightEpoch.tla                         # fix 1   -> HOLDS
    ├── FixedLightEpochWithInterlocked.tla          # fix 2   -> HOLDS
    ├── FixedLightEpochWithAsymmetricBarrier.tla    # fix 3   -> HOLDS
    ├── LightEpochTsavorite.tla                     # Tsavorite per-op API, buggy -> VIOLATED
    ├── FixedLightEpochTsavorite.tla                # Tsavorite per-op API, fixed -> HOLDS
    ├── run.sh · Dockerfile
└── herd7/                           # SB litmus on the OFFICIAL x86-TSO / AArch64 models
    ├── SB-x86.litmus · SB+mfence-x86.litmus · SB+xchg-x86.litmus
    ├── SB-aarch64.litmus · SB+rel-aarch64.litmus · SB+dmb-aarch64.litmus · SB+swpal-aarch64.litmus
    ├── SB+tsavorite-x86.litmus · SB+tsavorite-aarch64.litmus · SB+tsavorite-dmb-aarch64.litmus
    ├── run.sh · Dockerfile · README.md
└── disasm/                          # JIT-native disassembly of the announce path
    ├── x86_64/*.asm · arm64/*.asm   # one .asm per variant, per architecture
    ├── tool/ · capture.sh · Dockerfile · README.md
```

---

## 5. Running it

### 5.1 The C# repro

The harness is **self-judging**: it never decides to free anything. It hands each
retired page to the real `BumpCurrentEpoch(onDrain)` API and the epoch
implementation itself decides — via `ComputeNewSafeToReclaimEpoch` + `Drain` —
when to invoke `onDrain` (which unmaps the page). A fault therefore means the
epoch freed an object while a protected reader that had seen it linked was still
reading it.

```bash
# On real ARM64 hardware:
docker build -f Dockerfile.arm64 -t lightepoch-repro:arm64 .

docker run --rm lightepoch-repro:arm64 --impl baseline    --rounds 200000000   # faults in seconds (exit 134)
docker run --rm lightepoch-repro:arm64 --impl fullbarrier --rounds 200000000   # runs to completion (exit 0)
docker run --rm lightepoch-repro:arm64 --impl interlocked --rounds 200000000   # exit 0
docker run --rm lightepoch-repro:arm64 --impl asymmetric  --rounds 200000000   # exit 0

# x86-64 control — even the baseline completes (exit 0):
docker build -f Dockerfile.x86 -t lightepoch-repro:x86 .
docker run --rm lightepoch-repro:x86 --impl baseline --rounds 200000000
```

Or without Docker (from `src/LightEpoch.Repro`):

```bash
DOTNET_gcServer=1 dotnet run -c Release -- --impl baseline --rounds 200000000
```

Exit code `0` = survived (no reclaim while a protected reader held the page);
a non-zero / aborted exit (`134`) = a fault was observed.

**Modelling how Tsavorite actually calls the epoch (`--pattern`).** By default the
reader does a bare `Resume()` … read … `Suspend()` per round. The `--pattern`
flag reshapes the reader's per-operation call sequence to match real Tsavorite
usage (see §8):

| `--pattern` | Reader does, per round | Models | ARM64 baseline |
|---|---|---|---|
| `bare` (default) | `Resume()`; read; `Suspend()` | a single bare announce (the Acquire site) | **faults** |
| `tsavorite` | `Resume()`; `Refresh()`; read; `Suspend()` | `BasicContext`'s `UnsafeResumeThread`(`Resume`+`InternalRefresh`) … `UnsafeSuspendThread` — the **exact default API** | **faults** |
| `refresh` | `Resume()` once; `{ Refresh(); read }` loop; `Suspend()` once | the amortized `UnsafeContext` idiom | survives* |

```bash
docker run --rm lightepoch-repro:arm64 --impl baseline --pattern tsavorite --rounds 200000000   # faults (exit 134)
docker run --rm lightepoch-repro:arm64 --impl baseline --pattern refresh   --rounds 200000000   # survives* (see note)
```

\* The `refresh` pattern did **not** fault in a 200 s ARM64 run. This is not a
general safety guarantee — it is a property of *this harness's access pattern*:
after the one-time `Resume()`, the announce only ever advances **monotonically**
(`localCurrentEpoch` never resets to `0`), and this harness always dereferences
an object retired at the *same* epoch it is currently announcing, so a stale
(buffered) announce only makes the reclaimer **more** conservative. The per-op
`tsavorite`/`bare` patterns, by contrast, reset the slot to `0` on every
`Suspend()` and so **re-open the "absent reader" (`lce == 0`) window on every
single operation** — which is exactly why the shipped default API reproduces the
fault so readily. See §8.3.

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

### 5.3 The benchmarks

```bash
cd bench/LightEpoch.Bench
dotnet run -c Release -- --filter '*'            # all workloads, default job (tight CIs)
dotnet run -c Release -- --filter '*EnterExit*'  # reader hot-path cost of each fix
dotnet run -c Release -- --filter '*FenceMicro*' # the isolated fence cost, no type confound
dotnet run -c Release -- --filter '*Tsavorite*'  # Tsavorite's per-op default API (§8)
```

Run these on an ARM64 host to see the numbers that matter: the full-barrier and
interlocked variants add a per-enter cost, while the asymmetric variant is free
on enter and expensive only on the (rare) reclaim.

**Measured** (ARM64 Neoverse-N2 / Cobalt-100, BenchmarkDotNet **default job**;
`Mean ± Error`, where Error is half the 99.9 % CI — full tables, StdDev, the x86
control, and a per-claim significance analysis are in
[`bench/results/`](bench/results/README.md)):

| Variant | Enter/Exit (reader) | Reclaim |
|---|---:|---:|
| baseline (incorrect) | 14.40 ± 0.007 ns (1.00×) | 131.0 ± 0.49 ns (1.00×) |
| full-barrier | 17.28 ± 0.007 ns (**1.20×**) | 135.8 ± 0.71 ns (1.04×) |
| interlocked-exchange | 17.49 ± 0.022 ns (**1.21×**) | 141.7 ± 0.95 ns (1.08×) |
| asymmetric | 14.51 ± 0.026 ns (**1.01×, ≈ free**) | 947.0 ± 6.87 ns (**7.23×**) |

The full/interlocked fixes tax every reader ~20 % on ARM64; the asymmetric fix
charges readers essentially nothing (a 0.11 ns, layout-level difference) and
moves the whole cost to the rare, batched reclaim.

**How confident is that ~20 %?** On ARM64 the baseline and full-barrier 99.9 %
confidence intervals are separated by ~2.88 ns — about **200× the combined
error** — so it is not measurement noise. The x86 story is subtler: the raw
baseline→full delta there is ~10 %, but roughly half of that is a cross-variant
**layout** artifact (the plain-store `asymmetric` variant, whose reader code is
identical to baseline, is itself ~5 % "slower"; and full-barrier's x86 *reclaim*
even comes out *faster* than baseline — an impossibility that exposes the
artifact). The **fence-attributable** x86 cost is ~5 % (~0.78 ns), and an
isolated micro-benchmark (`FenceMicro`, same type, only the barrier differs) puts
one bare fence at **~4.4 ns on ARM64 (`dmb ish`)** vs **~7.6 ns on the
virtualized x86 (`lock or`)** — almost none of which lands on the x86 enter path
because it already runs a `lock cmpxchg` (see §2.1, §8). Full details, tables,
and the significance verdicts: [`bench/results/README.md`](bench/results/README.md).

**On Tsavorite's *actual* default API.** The tables above isolate a single
`Resume()`/`Suspend()`. Tsavorite's `BasicContext` instead runs
`Resume()` + `ProtectAndDrain()` + `Suspend()` **per operation** (§8), which
announces **twice** — so a fix pays *two* announce fences per op. Benchmarks
mirroring that exact sequence (`*Tsavorite*`) and the cheap amortized idiom
(`*AmortizedRefresh*`):

| Variant | Tsavorite per-op (ARM64) | Tsavorite per-op (x86) |
|---|---:|---:|
| baseline (incorrect) | 16.04 ± 0.010 ns (1.00×) | 19.33 ± 0.072 ns (1.00×) |
| full-barrier | 20.90 ± 0.017 ns (**1.30×**) | 20.59 ± 0.204 ns (1.06×) |
| interlocked-exchange | 22.98 ± 0.021 ns (**1.43×**) | 19.17 ± 0.048 ns (≈ noise) |
| asymmetric | 16.08 ± 0.014 ns (**1.00×, ≈ free**) | 19.34 ± 0.054 ns (1.00×) |

Two announce fences double the ARM64 tax to **+30 % (full) / +43 %
(interlocked)**, while the **asymmetric fix stays free on the reader (1.00×)**. On
x86-TSO the fix is ~6 % / noise (the Acquire path's `lock cmpxchg` already
fences). Separately, the per-op API costs **~2.7× the amortized `ProtectAndDrain`
idiom** on ARM64 (16.0 ns vs 6.0 ns baseline) — acquire/release machinery, not
the fence, dominates; adopting the `UnsafeContext`/refresh idiom saves far more
than the fence ever costs. Full tables (both arches, StdDev, significance):
[`bench/results/README.md`](bench/results/README.md).

### 5.4 The herd7 litmus tests

```bash
docker build -f herd7/Dockerfile -t lightepoch-herd7 herd7
docker run --rm lightepoch-herd7     # runs SB on the official x86-TSO / AArch64 models
```

This runs the Store-Buffer litmus through `herd7` using Intel's and Arm's own
reference memory models. Expected: `SB-x86`, `SB-aarch64`, `SB+tsavorite-x86`
and `SB+tsavorite-aarch64` **Sometimes** (allowed), `SB+rel-aarch64`
**Sometimes** (release is not enough), and `SB+mfence-x86`, `SB+xchg-x86`,
`SB+dmb-aarch64`, `SB+swpal-aarch64`, `SB+tsavorite-dmb-aarch64` **Never**
(fenced — the full-barrier and interlocked-exchange fixes both close the window).
The three `SB+tsavorite-*` tests model Tsavorite's default per-operation *double*
announce (`Resume`/Acquire then `Refresh`/ProtectAndDrain, §8). See
[`herd7/README.md`](herd7/README.md).

### 5.5 The JIT disassembly

```bash
docker build -f disasm/Dockerfile -t lightepoch-disasm .
docker run --rm --platform linux/amd64 -v "$PWD/disasm/x86_64:/out" lightepoch-disasm
docker run --rm --platform linux/arm64 -v "$PWD/disasm/arm64:/out"  lightepoch-disasm
```

Captured `.asm` files are already checked in under `disasm/x86_64/` and
`disasm/arm64/`. They show the announce store for each variant: on AArch64 the
baseline emits a plain `str` with no following barrier, the full-barrier variant
adds `dmb ish`, the interlocked variant uses `swpal`, and the asymmetric variant
calls the process-wide barrier at the top of the scan. See
[`disasm/README.md`](disasm/README.md).

---

## 6. How the repro works

The repro (`src/LightEpoch.Repro`) is deliberately the *smallest* program that
turns the abstract Store-Buffer race into a real, hard memory fault — and it is
**self-judging**: the harness never decides to free anything. It only wires the
two real epoch operations into an SB shape and lets the epoch implementation
itself pull the trigger. If the process faults, the epoch algorithm freed a live
object; if it exits `0`, it didn't. There is no oracle to argue with.

### 6.1 The two threads

Two threads are pinned to two distinct physical cores (`Plat.Pin`, via
`SetThreadAffinityMask` / `sched_setaffinity`) so their store buffers are
genuinely separate hardware:

* **Reader** (`ReaderLoop`) — the *protected* accessor:
  ```
  ops.Resume();        // STORE announce:  localCurrentEpoch = CurrentEpoch   (the unfenced store under test)
  long p = curPage;    // LOAD  the object pointer
  if (p != 0)          // only dereference something that still looked linked
      read pg[0..deref] // <-- faults here if the page was unmapped
  ops.Suspend();
  ```
* **Reclaimer** (`ReclaimerLoop`) — links, unlinks, and retires a page each round:
  ```
  page = Plat.Alloc(4096);          // a real OS page (VirtualAlloc / mmap)
  Volatile.Write(ref curPage, page);// link/publish the object
  --- round barrier ---
  curPage = 0;                      // STORE unlink (plain, like removing from a list)
  ops.BumpCurrentEpoch(() => Plat.Free(page));  // hand the retired page to the epoch
  ```

Mapped onto the memory-model primer in §1.3, this is exactly the SB litmus:
each thread does *store-then-load of the other's location*. The forbidden
outcome — reader still sees `curPage != 0` **and** reclaimer's scan misses the
announce — is precisely a reclaim-while-reading, i.e. a fault.

### 6.2 Why a fault is a *real* use-after-free, not a segfault trick

`Plat.Alloc` maps a **whole OS page** and `Plat.Free` **fully unmaps** it
(`VirtualFree(MEM_RELEASE)` / `munmap`). So the freed page's virtual addresses
become invalid at the hardware level — a subsequent read is a genuine access
violation (`0xC0000005` on Windows, `SIGSEGV`→exit `134` on Linux), not a
poisoned-value check we could get wrong. The page is 4 KB and the reader touches
`pg[k & 511]` (the first 512 longs), so any read after unmap lands in the hole.

### 6.3 Why the epoch — not the harness — does the freeing

This is the crux of "self-judging". The reclaimer does **not** call `Plat.Free`
directly. It passes the unmap as the `onDrain` callback to the real public API
`BumpCurrentEpoch(onDrain)`. Inside the unmodified implementation, the page is
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
  was reading → the process aborts (exit `134` / access violation). This is the
  bug, and on ARM64 the `baseline` build hits it within seconds, every run.
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
  (the C# repro), with the performance trade-offs measured (BenchmarkDotNet).

---

## 8. How Tsavorite actually uses LightEpoch

The performance section (§5.3) measures the cost of a fix *per epoch enter*. That
only matters in proportion to **how often Tsavorite enters the epoch** — so it is
worth being precise about the call pattern, because it is not the cheapest one
available.

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
* **The per-operation pattern is what makes the bug reproduce so readily on
  ARM64 — not the amortized one.** `Suspend()`/`Release()` resets the slot to
  `kInvalidIndex` and `localCurrentEpoch` to `0` at the end of *every* operation,
  and the next `Resume()`/`Acquire()` re-announces `0 → CurrentEpoch`. That
  `0 → E` transition is the dangerous one: while it is buffered, the reclaimer's
  scan reads `lce == 0` and treats the reader as **absent**, computing a safe
  epoch straight past a live reader. The default `BasicContext` API therefore
  **re-opens the "absent reader" window on every single operation** — which is
  exactly why both the `bare` and `tsavorite` repro patterns fault within seconds
  on ARM64 (§8.5). By contrast, the `ProtectAndDrain()` announce on the amortized
  path is a *monotonic advance* (`E → E'`, never back to `0`); a buffered such
  announce only ever makes the reclaimer **more** conservative, so — for the
  same-epoch access this repro performs — the `refresh` pattern did **not** fault
  in a 200 s run. The naked `ProtectAndDrain()` store is still not *correctly*
  ordered in the abstract (a thread that advances its epoch and then dereferences
  an object safe only under the *older* epoch would still need the fence, which
  is why `FixedLightEpoch` fences that site too), but the recurring, easily-hit
  hazard lives on the **per-operation acquire path the default API uses**.
* **The fix's relative cost is smaller than §5.3 suggests for this API.** On the
  default path each operation *already* pays a slot-reservation `lock cmpxchg`
  plus two announce stores plus a release. Adding one `dmb ish` / `lock or`
  (the full-barrier fix) is a small increment on top of machinery that is already
  locked-RMW-heavy — which is consistent with the measured ~5–10% on the
  micro-path and even less inside a real operation. Conversely, moving Tsavorite
  to the amortized `UnsafeContext` idiom would cut far more cost (a whole
  acquire/release per op) than shaving the announce fence ever could.

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

The default `BasicContext` sequence is exercised end-to-end by every layer of
this repo, so the claims above are checked, not asserted:

* **Repro (`--pattern tsavorite`).** The reader runs the exact
  `UnsafeResumeThread`(`Resume()`+`Refresh()`) … `UnsafeSuspendThread` sequence
  per operation. On ARM64 Neoverse-N2 the baseline **faults with
  `System.AccessViolationException` (exit 134)**; all three fixes run
  indefinitely. Measured matrix (200 s cap; `134` = use-after-free, `124` =
  survived to timeout):

  | `--pattern` | baseline | fullbarrier | interlocked | asymmetric |
  |---|---|---|---|---|
  | `bare` | **134 (fault)** | 124 | 124 | 124 |
  | `tsavorite` | **134 (fault)** | 124 | 124 | 124 |
  | `refresh` | 124 (survived\*) | — | — | — |

  \* See §8.3: `refresh` announces monotonically and this harness accesses a
  same-epoch object, so a buffered announce is only ever more conservative.

* **TLA+ (`LightEpochTsavorite` / `FixedLightEpochTsavorite`).** The per-op
  `Acquire`-announce → `ProtectAndDrain`-announce → operation-load → `Release`
  sequence, model-checked exhaustively: the unfenced spec is **VIOLATED**, and
  fencing both announce sites **HOLDS**.
* **herd7 (`SB+tsavorite-*`).** The double-announce store shape on the official
  x86-TSO and AArch64 models: **Sometimes** with no barrier (bug reachable for
  the shipped call sequence), **Never** with `DMB ISH` before the load.

### 8.6 Optimization: drop the redundant second announce (`ProtectAndDrainWithoutAnnounce`)

Because `UnsafeResumeThread` runs `Resume()` (Acquire) and `InternalRefresh()`
(`ProtectAndDrain()`) **back-to-back**, the two announce stores are almost
always redundant with each other: Acquire publishes `localCurrentEpoch =
CurrentEpoch`, and — with no epoch bump in between — `ProtectAndDrain` writes the
same value again. On the *original* code that redundant plain store is nearly
free, so nobody noticed. On a **fixed** implementation it is not free: the fix
puts a `StoreLoad` fence after *each* announce, so the per-op path pays **two**
fences — the source of the ARM64 **+30 % (full-barrier) / +43 % (interlocked)**
in §5.3 (vs ~+20 % for a single announce).

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
recovering one of the two per-op fences — pulling the ARM64 cost back from ~+30 %
toward the single-announce ~+20 %, with no change to the reclaimer.

**Proved, not asserted.** `tla/FixedLightEpochTsavoriteNoAnnounce.tla` models
exactly this — Acquire announces + fences, the refresh performs no announce — and
`NoUseAfterFree` **HOLDS** exhaustively. A negative control (removing the Acquire
fence as well) makes the same spec **VIOLATE**, confirming the single Acquire
fence is precisely what closes the window and the dropped second announce/fence
was pure overhead. This applies only when the refresh immediately follows a
`Resume()`; a standalone `ProtectAndDrain()` on an already-protected thread (the
amortized `UnsafeContext` idiom) still needs its own fence, because there is no
preceding fenced Acquire in that path.
