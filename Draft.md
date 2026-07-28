# LightEpoch memory-ordering study — full report

This is the analysis behind the hardware results in **[README.md](README.md)**, which
also covers [how to run the repros](README.md#reproducing-the-numbers).

---

## Table of contents

Results and methodology live in [README.md](README.md); this report is the analysis
behind them.

- [1. The algorithm and the bug](#1-the-algorithm-and-the-bug)
  - [1.1 What an epoch protects](#11-what-an-epoch-protects)
  - [1.2 The enter path (the announce store)](#12-the-enter-path-the-announce-store)
  - [1.3 The race, as a Store-Buffer (SB) litmus](#13-the-race-as-a-store-buffer-sb-litmus)
- [2. Memory models: why x86 is harder to reproduce](#2-memory-models-why-x86-is-harder-to-reproduce)
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
- [Appendix A. Why the unmap-based repro cannot fault on x86 (TLB shootdown)](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown)
  - [A.1 The observation](#a1-the-observation)
  - [A.2 The cause: `VirtualFree` forces a TLB shootdown](#a2-the-cause-virtualfree-forces-a-tlb-shootdown-and-on-x86-that-serializes-the-reader)
  - [A.3 Secondary x86 suppressors in the same loop](#a3-secondary-x86-suppressors-in-the-same-loop)
  - [A.4 What this does *not* mean](#a4-what-this-does-not-mean)
  - [A.5 Observing it on x86: the fenceless detection mode](#a5-observing-it-on-x86-the-fenceless-detection-mode)
  - [A.6 Result: the bug does reproduce on x86-64](#a6-result-the-bug-does-reproduce-on-x86-64)
  - [A.7 Validating the detector](#a7-validating-the-detector)

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

## 2. Memory models: why x86 is harder to reproduce

The forbidden SB outcome is only *forbidden under sequential consistency*. Real
CPUs are not sequentially consistent: every mainstream architecture has
**per-core store buffers**, so a core can execute a later load before its own
earlier store has become globally visible. This single relaxation — **StoreLoad
reordering** — is exactly what the bug needs.

### 2.1 x86-64 (TSO — Total Store Order)

x86 is *strong*: its store buffer is **FIFO**, and the **only** reordering it
permits is StoreLoad. So the bug's window **does exist** on x86 in principle.
Whether a finite hardware test observes it depends on microarchitecture,
contention, scheduling, generated code, and whether the store propagates before
the reclaimer finishes its longer path. A locked instruction would close the
window only if it occurred after the announcement and before the protected
load; unrelated runtime activity may perturb timing but is not a correctness
mechanism.

In the Windows x86-64 runs performed for this study, the buggy build completed
without an observed fault **in the unmap-based harness** — but that turned out to
be an artifact of the harness, not a property of the hardware. The `VirtualFree`
used to detect the fault triggers a TLB-shootdown IPI that serializes the reader
and drains its store buffer every round. With a detection mode that keeps the
kernel out of the race loop, the **buggy build does reproduce on x86-64**, on both
an i7-12700K and a Xeon 8272CL, while every fixed build stays clean. See
[Appendix A](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown).

**Nearby locked operations may affect timing, but they do not fix the bug.**
Every *enter* goes through `TryAcquireEntry`, which claims the thread's slot with
an `Interlocked.CompareExchange` on `threadId` (`lock cmpxchg`), and every
reclaim advances the global epoch with `Interlocked.Increment`
(`BumpCurrentEpoch`, a locked `xadd`). The JIT places the reservation CAS before
the plain announcement store:

```asm
lock cmpxchg  dword ptr [slot.threadId], threadId
     mov      qword ptr [slot.localCurrentEpoch], currentEpoch
     mov      ..., qword ptr [sharedObject]
```

The locked CAS is a full fence around operations ordered before and after the
CAS itself, but the announcement is **after** it. It therefore does not order
the announcement before the subsequent shared-object load. These locked
operations, allocator activity, scheduling, and x86 store-buffer behavior may
change how often the narrow window is observed, but the JIT output cannot prove
that any of them closes it. The only defensible conclusion from a clean x86 run
is that the allowed outcome was not observed during that run.

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

ARM64 is covered by the hardware repro (§5.1, §7) rather than by a TLA+ litmus.
The formal models use the x86-TSO store buffer, which is the *stronger* of the
two: an ordering violation reachable under TSO is reachable under ARM64 as well,
so modeling on TSO is the conservative choice.

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
| **full barrier** | `FixedLightEpochWithMemoryBarrier.cs` | `Interlocked.MemoryBarrier()` after each announce |
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

All three fixes are proven safe in `tla/` (`FixedLightEpochWithMemoryBarrier`,
`FixedLightEpochWithInterlocked`, `FixedLightEpochWithAsymmetricBarrier` all →
`NoUseAfterFree` HOLDS).

---

## 4. Repository layout

```
.
├── README.md                        # hardware results and how to run the repros
├── Draft.md                         # this document: the analysis behind the results
├── src/
│   ├── LightEpoch.Implementations/  # the 4 epoch variants (shared library)
│   │   ├── LightEpoch.cs                              # baseline (buggy)
│   │   ├── FixedLightEpochWithMemoryBarrier.cs        # full barrier
│   │   ├── FixedLightEpochWithInterlockedExchange.cs  # seq-cst RMW announce
│   │   ├── FixedLightEpochAsymmetricBarrier.cs        # reclaimer-side barrier
│   │   ├── AsymmetricBarrier.cs                       # FlushProcessWriteBuffers / membarrier
│   │   ├── UtilityShim.cs · EpochOps.cs
│   ├── LightEpoch.Repro.Common/     # shared, self-judging litmus harness
│   │   ├── ReproRunner.cs                             # CLI, the two epoch patterns, core selection, pair orchestration
│   │   ├── Litmus.cs                                  # unmap detection (ARM64 path)
│   │   ├── QuarantineLitmus.cs                        # poison-sentinel detection (x86 path)
│   │   ├── CoreTopology.cs                            # physical cores, SMT siblings, NUMA nodes
│   │   ├── WindowsNative.cs                           # VirtualAlloc/VirtualFree, thread pinning
│   └── LightEpoch.Repro/            # the executable (--pattern bare|resume-and-refresh)
├── tla/
│   ├── memory-models/               # the memory model itself
│   │   ├── X86TSO.tla
│   ├── epoch/                       # the epoch algorithm
│   │   ├── LightEpoch.tla                              # buggy   -> VIOLATED
│   │   ├── LightEpochResumeAndRefresh.tla              # Tsavorite per-op API, buggy -> VIOLATED
│   │   └── fixes/
│   │       ├── FixedLightEpochWithMemoryBarrier.tla        # fix 1 -> HOLDS
│   │       ├── FixedLightEpochWithInterlocked.tla          # fix 2 -> HOLDS
│   │       ├── FixedLightEpochWithAsymmetricBarrier.tla    # fix 3 -> HOLDS
│   │       └── FixedLightEpochResumeAndRefresh.tla         # per-op API, fixed -> HOLDS
│   └── run.sh · Dockerfile
```

---

## 5. Running it

### 5.1 The C# repro

The repro uses a **self-judging** harness: it never decides to free anything. It hands each
retired page to the real `BumpCurrentEpoch(onDrain)` API and the epoch
implementation itself decides — via `ComputeNewSafeToReclaimEpoch` + `Drain` —
when to invoke `onDrain` (which unmaps the page, or poisons it under
`--quarantine`). A violation therefore means the epoch freed an object while a
protected reader that had seen it linked was still reading it.

`--pattern` selects the epoch sequence the reader runs immediately before the
shared access; everything else is identical:

| `--pattern` | Reader sequence per operation | Purpose |
|---|---|---|
| `bare` (default) | `Resume()` → access → `Suspend()` | Minimal reproduction of the Acquire announce bug |
| `resume-and-refresh` | `Resume()` → `InternalRefresh()`/`ProtectAndDrain()` → access → `Suspend()` | Epoch portion of a normal Tsavorite `BasicContext` operation |

Run on Windows with a .NET 10 SDK:

```bash
DOTNET_gcServer=1 dotnet run --project src/LightEpoch.Repro -c Release -- \
  --impl baseline --rounds 200000000
DOTNET_gcServer=1 dotnet run --project src/LightEpoch.Repro -c Release -- \
  --pattern resume-and-refresh --impl baseline --rounds 200000000
```

Exit code `0` = survived (no reclaim while a protected reader held the page);
an access-violation termination (`0xC0000005`) = a fault was observed. On
Windows ARM64,
both baseline repros fault; the fixed implementations survive. **On x86-64 add
`--quarantine`** — the default unmap mode cannot observe the window there, for
reasons explained in [Appendix A](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown).
In that mode the verdict is `USE-AFTER-FREE` on stderr and a nonzero exit rather
than a hardware fault. See §8 for the Tsavorite call sequence.

**Core selection and concurrency flags:**

| Flag | Meaning |
|---|---|
| `--pattern bare\|resume-and-refresh` | Epoch sequence the reader runs per operation (table above). Defaults to `bare`. |
| `--pairs N` | Run N concurrent litmus pairs on 2N distinct physical cores. Defaults to 2 when ≥4 physical cores are available — a single pair can run for minutes on Neoverse-N1 without faulting, while two pairs fault in seconds. More is not better: 3 pairs de-aligns the per-round barrier and takes longer to fault, or does not fault at all. |
| `--seed N` | Shuffle which physical cores are used, to vary core-pair placement between runs. |
| `--cross-numa` | Force each pair's reader and reclaimer onto **different NUMA nodes**. |
| `--reader-core N --reclaimer-core N` | Manual pinning; only valid with `--pairs 1`. Warns if the two logical processors are SMT siblings. |
| `--quarantine` | Use the x86 detection mode (pooled pages + poison sentinel, no syscall in the race loop) instead of unmapping. Required to observe the bug on x86-64. |
| `--self-test` | Poison unconditionally to prove the `--quarantine` detector can fire. |

Core selection always picks **one logical processor per physical core**, preferring
the highest efficiency class (P-cores over E-cores). SMT siblings are never paired:
they share a store buffer, so the Store-Buffer window cannot open and a clean run
would prove nothing.

See [Methodology](README.md#methodology) for what each detection mode does and why the two
architectures need different ones.

### 5.2 The TLA+ models

```bash
docker build -f tla/Dockerfile -t lightepoch-tla tla
docker run --rm lightepoch-tla        # checks all 12 specs and prints expected vs. actual
```

Expected outcomes. Note the **Models** column: every spec whose name starts with
`Fixed` describes a **proposed change to Tsavorite**, not how Tsavorite behaves
today. Tsavorite as shipped is `LightEpoch` / `LightEpochResumeAndRefresh`, and
both are VIOLATED.

| Spec | Config | Models | Result |
|---|---|---|---|
| `X86TSO` | no fence | hardware litmus | VIOLATED |
| `X86TSO` | MFENCE | hardware litmus | HOLDS |
| `LightEpoch` | — | **Tsavorite as shipped** | **VIOLATED** |
| `FixedLightEpochWithMemoryBarrier` | — | proposed fix | HOLDS |
| `FixedLightEpochWithInterlocked` | — | proposed fix | HOLDS |
| `FixedLightEpochWithAsymmetricBarrier` | — | proposed fix | HOLDS |
| `LightEpochResumeAndRefresh` (per-op `Resume`+`Refresh`+`Suspend`) | — | **Tsavorite as shipped** | **VIOLATED** |
| `FixedLightEpochResumeAndRefresh` (both announce sites fenced) | — | proposed fix | HOLDS |

The last two model **Tsavorite's default per-operation API** (§8). The buggy
spec — the one that matches the code Tsavorite ships — issues both announce
stores (Acquire and ProtectAndDrain) with no fence and is VIOLATED; fencing both
announce sites HOLDS.

A `HOLDS` on a `Fixed*` spec therefore means "this fix works", **never**
"Tsavorite is already correct".

---

## 6. How the repros work

The shared harness (`src/LightEpoch.Repro.Common`) is deliberately the smallest
program that turns the abstract Store-Buffer race into an observable use-after-free — and it is
**self-judging**: the harness never decides to free anything. It only wires the
two real epoch operations into an SB shape and lets the epoch implementation
itself pull the trigger. If the process faults, the epoch algorithm freed a live
object; if it exits `0`, it didn't. There is no oracle to argue with.

This section describes the default **unmap** mode, which is the one used on ARM64.
`--quarantine` keeps everything below identical except how the free is made
observable — see [Methodology](README.md#methodology) and
[Appendix A](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown).

### 6.1 The two threads

Each litmus pair is a reader and a reclaimer pinned to two distinct **physical**
cores (`WindowsNative.Pin`, via `SetThreadAffinityMask`) so their store buffers are
genuinely separate hardware. `--pairs N` runs N such pairs concurrently on 2N
physical cores; SMT siblings are never paired, since siblings share a store buffer:

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

* **Devirtualized dispatch.** `Litmus<TOps, TPattern>` is generic over a
  `struct, IEpochOps` adapter (`BaselineOps`, `FullBarrierOps`, …). The JIT specializes the generic
  per struct and inlines `Resume`/`Suspend`/`BumpCurrentEpoch` down to the
  concrete epoch calls, so there is no virtual-call barrier or indirection
  sitting between the announce store and the object load.
* **A two-phase reusable barrier** (`StartBarrier`/`EndBarrier`) realigns
  the two threads every round so their store/load windows overlap on real
  hardware — without this the two loops drift and the window is rarely hit. The
  barrier brackets the race region; it is *outside* the announce→deref window, so
  it doesn't add ordering to the accesses under test.

### 6.5 What each exit means

* **Reader faults mid-dereference** → the epoch freed a page a protected reader
  was reading → the process terminates with access violation `0xC0000005`. This
  is the bug, and on Windows ARM64 the `baseline` build hits it within seconds
  once enough pairs are running (one pair suffices on Neoverse-N2; Neoverse-N1
  needs two).
* **Loop completes all rounds** → prints `Completed N rounds ... with NO fault`
  and returns `0`. This is what all three fixes do — indefinitely — and what
  even the `baseline` does on x86-64 in this mode. On x86 that last part is a
  property of the *harness*, not the hardware: the unmap used to detect the fault
  forces a TLB-shootdown IPI that serializes the reader, so this mode cannot
  observe the window on x86 no matter how long it runs. Use `--quarantine` there.
  See [Appendix A](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown).

Selecting the implementation is just `--impl baseline|fullbarrier|interlocked|asymmetric`;
everything else (page size, dereference count, core selection, detection mode) is
identical across variants, so the *only* thing that changes between a faulting run and a
clean run is whether the announce store carries a StoreLoad fence.

---

## 7. Summary

* The epoch **enter** path publishes the announce with a plain store and no
  StoreLoad fence, while the algorithm's correctness depends on that announce
  being visible to the reclaimer's scan.
* This is a Store-Buffer race. It is a **memory-model bug**, not a logic bug:
  the code is correct under sequential consistency but **wrong on ARM64**, where
  the buggy build faults within seconds, and **also wrong on x86-64**, where the
  window is far narrower but still observable once the harness stops serializing
  the reader (see [Appendix A](#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown)).
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

* **A locked RMW occurs near the announcement on every default operation.**
  Each `BasicContext` operation runs `TryAcquireEntry`'s
  `Interlocked.CompareExchange` immediately before the announcement. This may
  perturb the timing of an executable x86 reproduction, but it is not the
  required fence: because the announcement follows the RMW, the later
  shared-object load can still pass that announcement under x86-TSO.
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

* **Repros.** `--pattern resume-and-refresh` runs the epoch-critical
  `UnsafeResumeThread` (`Resume()` + `InternalRefresh()`/`ProtectAndDrain()`) …
  `UnsafeSuspendThread` sequence per operation. `--pattern bare` omits
  only the refresh to isolate the original Acquire announce. On ARM64 both
  baselines **fault with `System.AccessViolationException` (`0xC0000005`)**; all
  three fixes run indefinitely:

  | `--pattern` | baseline | fullbarrier | interlocked | asymmetric |
  |---|---|---|---|---|
  | `bare` | **access violation** | survives | survives | survives |
  | `resume-and-refresh` | **access violation** | survives | survives | survives |

  The extra `ProtectAndDrain()` announce does make the window harder to hit:
  `resume-and-refresh` needs 2 pairs to fault where `bare` faults with 1 on
  Neoverse-N2 (29 s vs 19 s), and 96 s vs 15 s on the 8-core Neoverse-N1. That is
  expected — the second announce re-publishes the same value, so it gives the
  reclaimer's scan a second chance to observe a non-zero slot — but it is only a
  probability change, not ordering: both announces are plain stores, so neither
  provides the missing StoreLoad fence, and the fault still happens.

* **TLA+ (`LightEpochResumeAndRefresh` / `FixedLightEpochResumeAndRefresh`).** The per-op
  `Acquire`-announce → `ProtectAndDrain`-announce → operation-load → `Release`
  sequence, model-checked exhaustively: the unfenced spec is **VIOLATED**, and
  fencing both announce sites **HOLDS**.

---

## Appendix A. Why the unmap-based repro cannot fault on x86 (TLB shootdown)

### A.1 The observation

Running the `baseline` build with progressively more concurrency produced a sharp
architectural split:

| Host | Topology | Config | Result |
|---|---|---|---|
| Ampere Altra (Neoverse-N1) | 4 cores, no SMT | 2 threads | no fault in 120 s |
| Ampere Altra (Neoverse-N1) | 8 cores, no SMT | 4 threads (2 pairs) | **fault @ 15 s** |
| Ampere Altra (Neoverse-N1) | 8 cores, no SMT | 6 threads (3 pairs) | **fault @ 113 s** |
| Cobalt 100 (Neoverse-N2) | 4 cores, no SMT | 2 threads | **fault @ 19 s** |
| Intel i7-12700K | 12 phys cores, 1 NUMA node | 6 threads on distinct P-cores | no fault in 300 s |
| Intel Xeon 8272CL | 32 phys cores, **2 NUMA nodes** | 16 threads, pairs **same** NUMA node | no fault in 300 s |
| Intel Xeon 8272CL | 32 phys cores, **2 NUMA nodes** | 16 threads, pairs **straddling** NUMA nodes | no fault in 300 s |

The cross-NUMA run is the interesting negative. The intuition was that placing the
reader and the reclaimer on different sockets would keep the announce store buffered
much longer — a remote read-for-ownership over the socket interconnect costs hundreds
of nanoseconds instead of tens — and so widen the SB window. It made no measurable
difference: cross-socket and same-socket behaved identically.

That is a strong hint that **something is closing the window on x86 regardless of how
long the store would otherwise sit in the store buffer**.

### A.2 The cause: `VirtualFree` forces a TLB shootdown, and on x86 that serializes the reader

Section 6.2 explains that the harness deliberately uses a *real* unmap
(`VirtualFree(MEM_RELEASE)`) so that a fault is an unambiguous `0xC0000005` rather
than a poisoned-value heuristic. That choice is what makes the ARM64 demo so clean —
and it is also what makes the x86 experiment impossible.

Unmapping a page requires removing it from **every core's TLB**, and the two
architectures do that in fundamentally different ways:

* **x86-64 has no architectural broadcast TLB invalidation.** `INVLPG` is
  core-local. To invalidate a mapping globally the kernel performs a *TLB
  shootdown*: it sends an **inter-processor interrupt (IPI)** to every core that may
  have cached the translation, and each target core services the interrupt and
  invalidates locally. Crucially, **taking an interrupt on x86 is a serializing
  event** — the interrupted core's store buffer is drained before the handler runs
  (Intel SDM Vol. 3, "Serializing Instructions" / "Memory Ordering"; entering an
  interrupt handler has the ordering effect of a full barrier).
* **ARM64 broadcasts TLB maintenance in hardware.** `TLBI VAE1IS` (and friends)
  propagate across the inner-shareable domain via the interconnect, followed by
  `DSB ISH` on the *issuing* core only. Other cores' TLBs are invalidated **without
  taking any interrupt** — they never trap, never serialize, and their store buffers
  are untouched.

The consequence for this repro is direct. Every round, the reclaimer calls
`VirtualFree`. On x86 that means the kernel IPIs the reader's core, the reader traps,
and its store buffer is flushed — **the operating system injects, into the reader
thread, exactly the `MFENCE` that the bug requires to be absent.** The announce store
is forced to global visibility every iteration, so the reclaimer's scan can never
observe the stale-empty slot. On ARM64 no such interrupt occurs, the announce stays
in the store buffer, and the window stays open.

This is an observer effect: **the mechanism used to detect the bug destroys the
condition being detected — but only on x86.**

### A.3 Secondary x86 suppressors in the same loop

The shootdown is the dominant effect, but three smaller ones push the same way:

* **`VirtualAlloc`/`VirtualFree` are syscalls in the hot loop.** Kernel transitions
  add hundreds of cycles of jitter between the barrier release and the announce. The
  x86 SB window is on the order of tens of cycles, so the two threads must align far
  more precisely than on ARM64, where the window is wide enough to absorb the noise.
* **The drain callback allocates.** `ops.BumpCurrentEpoch(() => WindowsNative.Free(...))`
  captures `pageAddress`, so a closure and display class are allocated every round.
  The resulting GCs suspend the runtime, and .NET's suspension uses
  `FlushProcessWriteBuffers`, which is itself a process-wide store-buffer flush.
* **`BumpCurrentEpoch` does `Interlocked.Increment(ref CurrentEpoch)`.** This is a
  full fence — but on the *reclaimer*, and it is seq-cst on both architectures, so it
  is not the x86/ARM64 differentiator. It is noted here only to rule it out: the bug
  needs the **reader's** announce delayed, and nothing in the reader's own code
  fences it. Only the OS does, and only on x86.

### A.4 What this does *not* mean

It does **not** mean x86-TSO forbids the reordering. It does not:

* x86-TSO explicitly permits StoreLoad reordering — a store may sit in the store
  buffer while a later load from a different address completes. That is the one
  relaxation TSO allows, and it is precisely the SB shape of §1.3.
* The repository's own model confirms it: running `LightEpoch.tla` under the
  `X86TSO` memory-model configuration with no fence yields **VIOLATED**. The bug is
  reachable on x86 in the model.

So the correct claim is narrower than "x86 is safe":

> The buggy announce is **incorrect on x86-64**, but the *unmap-based* harness cannot
> observe it there, because the unmap itself serializes the reader. x86 is quiet in
> these runs as an artifact of the measurement, not as a property of the hardware.

Sections 2.1 and 6.5 carry this caveat inline.

### A.5 Observing it on x86: the fenceless detection mode

To test x86 honestly the *detection* mechanism has to change while the race stays
identical — no kernel involvement in the hot loop:

1. **Replace unmapping with quarantine.** Pre-allocate a pool of pages up front
   (1024) and recycle them. "Freeing" writes a poison sentinel
   (`0xDEADBEEFDEADBEEF`) over the page instead of calling `VirtualFree`. No
   page-table edit, therefore no shootdown, therefore no IPI and no serialized
   reader.
2. **Detect the violation logically.** The reader checks every value it reads
   inside its critical section. Observing poison in a page it was protecting is a
   use-after-free by the algorithm's own definition — established purely through
   memory, with no fault.
3. **Remove the per-round allocation** so no GC — and therefore no
   `FlushProcessWriteBuffers` — occurs. Note that simply caching *one* `Action` is
   wrong: `BumpCurrentEpoch` defers the drain, so the callback must stay bound to
   the page that was actually retired. The implementation pre-builds one delegate
   per pool slot (see [A.7](#a7-validating-the-detector)).

The trade-off is deliberate: the unmap mode gives an unforgeable hardware verdict and
is the right default for ARM64; the quarantine mode gives a weaker (software) verdict
but is the only way to sample the window on x86. Both exercise the same unfenced
announce in the same epoch implementation.

This is implemented as a **separate** litmus class rather than a branch inside the
existing one: `Litmus` (unmap, the ARM64 path) is untouched, and
`QuarantineLitmus` (`--quarantine`) is the x86 path.

### A.6 Result: the bug does reproduce on x86-64

With the kernel removed from the race loop, the window becomes observable on x86 —
on two different Intel parts, and only for the buggy build:

| Host | Config | Impl | Pairs violating | Total use-after-free reads |
|---|---|---|---|---|
| i7-12700K | 8 runs × 5 pairs | `baseline` | **5 / 40** | **59** |
| i7-12700K | 8 runs × 5 pairs | `fullbarrier` | 0 / 40 | 0 |
| i7-12700K | 8 runs × 5 pairs | `interlocked` | 0 / 40 | 0 |
| i7-12700K | 8 runs × 5 pairs | `asymmetric` | 0 / 40 | 0 |
| Xeon 8272CL | 6 runs × 5 pairs, **cross-NUMA** | `baseline` | **3 / 30** | **6** |
| Xeon 8272CL | 6 runs × 5 pairs, **same-NUMA** | `baseline` | **1 / 30** | **4** |
| Xeon 8272CL | 6 runs × 5 pairs, cross-NUMA | `fullbarrier` | 0 / 30 | 0 |
| Xeon 8272CL | 6 runs × 5 pairs, same-NUMA | `fullbarrier` | 0 / 30 | 0 |

So the empirical picture now matches the TLA+ result exactly: `X86TSO` with no fence
is **VIOLATED** in the model, and violated on the hardware too. The earlier clean x86
runs measured the harness, not the architecture.

Two secondary conclusions:

* **Cross-NUMA is not the lever.** Straddling sockets is at best a mild amplifier
  (3/30 vs 1/30 pairs; 6 vs 4 events — well within noise at this sample size), not
  the order-of-magnitude effect originally hypothesised. The TLB shootdown, not
  interconnect latency, was what had been suppressing the race.
* **x86 remains far rarer than ARM64.** Tens of events across tens of pair-runs on
  x86, versus a hard fault in 15–113 s on Ampere Altra. The ordering is architectural
  on ARM64 and a narrow timing window on x86 — but a narrow window is still a bug.

### A.7 Validating the detector

A logical detector that never fires is indistinguishable from a correct program, so
`--self-test` poisons the page unconditionally every round, simulating an epoch that
always decides wrongly. Any reader that captured the pointer must then observe
poison. It reports thousands of violations on every machine tested; a run where it
stays silent means the detector is broken and no `--quarantine` result should be
trusted.

This matters because the first version of this mode was silent for the wrong reason.
`BumpCurrentEpoch(onDrain)` **defers** the callback until the epoch decides the
retired epoch is safe, which can be several rounds later. An initial implementation
stored the page to poison in a single shared field to avoid a per-round allocation,
so by the time the callback ran it poisoned whichever page was current — not the one
that had been retired. It never flagged anything, including on ARM64 where the bug
is known to reproduce. The fix is a pre-built array of one delegate per pool slot,
each closing over its own page: correct binding, still no allocation in the loop.
The `sampledRounds` counter in the output guards the related failure mode — it
reports how often the reader actually captured a live pointer before the reclaimer
unlinked it, so a clean run with `sampledRounds=0` can be recognised as "never
sampled the window" rather than "no violation".
