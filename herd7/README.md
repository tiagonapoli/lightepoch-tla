# herd7 — the bug on the official hardware memory models

This folder proves the same StoreLoad bug a fourth, maximally authoritative way:
by running the **Store-Buffer (SB) litmus test** through
[`herd7`](https://github.com/herd/herdtools7), the memory-model simulator whose
`.cat` models for **x86-TSO** and **AArch64** are the reference formalizations
vetted by Intel and Arm respectively. There is no hand-written model here (unlike
`tla/`, which is our own abstraction) — herd7 uses the *architects' own* models,
so the outcomes are as close to "what the ISA guarantees" as a tool can get.

## The mapping to the LightEpoch bug

Every test is the classic SB shape, which is exactly the enter-path race
(see the top-level README §1.3):

```
location x = the reader's announce slot (localCurrentEpoch)
location y = the object's linked flag   (curPage != 0)

P0 = reader     : STORE x   (announce) ; then LOAD y   (is it still linked?)
P1 = reclaimer  : STORE y   (unlink)   ; then LOAD x   (the safe-epoch scan)

forbidden-under-SC outcome:  both loads read 0
  => reader missed the unlink (derefs) AND reclaimer missed the announce (frees)
  => reclaim-while-reading
```

`herd7` enumerates every execution the model permits and reports whether that
`exists` outcome is reachable: **`Sometimes`** = the model *allows* it (the bug
is possible), **`Never`** = the model *forbids* it (the fix closes it).

## The tests and what they prove

| File | Arch / model | Barrier on the store→load edge | Outcome | Meaning |
|---|---|---|---|---|
| `SB-x86.litmus` | X86 / x86tso | none | **Sometimes** | Even strong x86 allows StoreLoad — the window is real (just rarely hit). |
| `SB+mfence-x86.litmus` | X86 / x86tso | `MFENCE` | **Never** | A full fence (or a locked RMW) closes it on x86. |
| `SB+xchg-x86.litmus` | X86 / x86tso | `XCHG` (implicitly-locked seq-cst RMW) | **Never** | `Interlocked.Exchange` closes it on x86. |
| `SB-aarch64.litmus` | AArch64 / arm | none (plain `STR`) | **Sometimes** | The plain announce — the bug is genuinely reachable on ARM64. |
| `SB+rel-aarch64.litmus` | AArch64 / arm | store-release `STLR` | **Sometimes** | **Release / `Volatile.Write` is NOT a fix** — it does not order a later load. |
| `SB+dmb-aarch64.litmus` | AArch64 / arm | `DMB ISH` (full barrier) | **Never** | `Interlocked.MemoryBarrier()` closes it on ARM64. |
| `SB+swpal-aarch64.litmus` | AArch64 / arm | `SWPAL` (seq-cst RMW) | **Never** | `Interlocked.Exchange` closes it on ARM64. |
| `SB+tsavorite-x86.litmus` | X86 / x86tso | none (two plain announce stores) | **Sometimes** | Tsavorite's per-op *double* announce is still a StoreLoad window on x86-TSO. |
| `SB+tsavorite-aarch64.litmus` | AArch64 / arm | none (two plain announce stores) | **Sometimes** | The exact call sequence Tsavorite ships (`Resume`+`Refresh` per op) reproduces the bug. |
| `SB+tsavorite-dmb-aarch64.litmus` | AArch64 / arm | `DMB ISH` after the announces | **Never** | Fencing both announce sites closes the shipped path. |

The last three model **Tsavorite's default `BasicContext` per-operation
sequence**, which issues *two* announce stores before the operation's load —
`Resume()`/`Acquire` (`LightEpoch.cs` ~527) then `InternalRefresh()`/
`ProtectAndDrain` (~304) — see the top-level README §8. Doubling the announce
does not change the memory-model verdict (the two same-value stores collapse):
the bug is still reachable on AArch64 with no barrier, and a `DMB ISH` before the
load still closes it. They exist to prove the outcome against the *actual shipped
call shape*, not just a single bare announce.

### Which test corresponds to which repo variant

| Repo variant | herd7 test(s) | Outcome |
|---|---|---|
| `LightEpoch` (buggy, plain store) | `SB-x86`, `SB-aarch64` | **Sometimes** (window is real) |
| `FixedLightEpoch` (`Interlocked.MemoryBarrier` → `DMB ISH` / `MFENCE`) | `SB+mfence-x86`, `SB+dmb-aarch64` | **Never** |
| `FixedLightEpochWithInterlockedExchange` (`Interlocked.Exchange` → seq-cst RMW) | `SB+xchg-x86`, `SB+swpal-aarch64` | **Never** |
| `FixedLightEpochAsymmetricBarrier` (process-wide barrier on the reclaimer) | *see note below* | — |
| *Tsavorite default API* (`BasicContext`: `Resume`+`Refresh`+`Suspend` per op) | `SB+tsavorite-x86`, `SB+tsavorite-aarch64` | **Sometimes** (bug ships) |
| *Tsavorite default API, fixed* (fence at both announce sites) | `SB+tsavorite-dmb-aarch64` | **Never** |
| *(anti-fix demonstration: `Volatile.Write` release store)* | `SB+rel-aarch64` | **Sometimes** (insufficient) |

> **Why the asymmetric-barrier variant has no dedicated `.litmus` file.**
> `FixedLightEpochAsymmetricBarrier` keeps the reader's announce a *plain* store
> and instead makes the **reclaimer** issue a process-wide barrier
> (`FlushProcessWriteBuffers` / `sys_membarrier`) before its scan. That barrier
> is a **runtime / OS mechanism** — it sends an inter-processor interrupt that
> forces every other core to execute a fence — **not** a CPU memory-ordering
> *instruction* that appears in the reader's own instruction stream. herd7 models
> the ISA (the instructions a thread executes), so it has no primitive for
> "remotely force a fence onto another hart," and this pattern cannot be written
> as a litmus test. Its *correctness*, however, reduces to exactly the edge that
> **is** already proven here: the asymmetric barrier's net effect is to guarantee
> a full StoreLoad fence on the reader's store→load edge at the moment the
> reclaimer scans — i.e. the same ordering `SB+dmb-aarch64.litmus` proves closes
> the window (**Never**). The only difference is *which thread pays for the
> fence* (the reclaimer, rarely, instead of the reader on every enter), which is
> a **performance** property invisible to a memory-model checker. This variant is
> instead validated by the TLA+ model
> (`tla/FixedLightEpochWithAsymmetricBarrier.tla`) and the runtime repro.

The two headline lessons of this whole study fall straight out of the table:

1. **The bug is a real ARM64 hazard** (`SB-aarch64` → Sometimes), and only
   *incidentally* invisible on x86 despite x86 also technically allowing it
   (`SB-x86` → Sometimes, but the store buffer drains in a few cycles in
   practice).
2. **You cannot fix it with a release store** (`SB+rel-aarch64` → Sometimes).
   Only a full StoreLoad barrier / seq-cst RMW works (`SB+dmb-aarch64`,
   `SB+mfence-x86` → Never).

## Running it

```bash
docker build -f herd7/Dockerfile -t lightepoch-herd7 herd7
docker run --rm lightepoch-herd7
```

`run.sh` runs each `.litmus` file through `herd7` (letting it pick the
architecture's default reference model from the file's arch header) and checks
the observed `Observation ... Never|Sometimes` against the predictions above.
Expected output:

```
TEST                               EXPECT     OBSERVED   RESULT
SB-x86.litmus                      Sometimes  Sometimes  OK
SB+mfence-x86.litmus               Never      Never      OK
SB+xchg-x86.litmus                 Never      Never      OK
SB+tsavorite-x86.litmus            Sometimes  Sometimes  OK
SB-aarch64.litmus                  Sometimes  Sometimes  OK
SB+rel-aarch64.litmus              Sometimes  Sometimes  OK
SB+dmb-aarch64.litmus              Never      Never      OK
SB+swpal-aarch64.litmus            Never      Never      OK
SB+tsavorite-aarch64.litmus        Sometimes  Sometimes  OK
SB+tsavorite-dmb-aarch64.litmus    Never      Never      OK
```

To inspect one test's full execution set:

```bash
docker run --rm --entrypoint herd7 lightepoch-herd7 SB-aarch64.litmus
```

## How this complements the other three proofs

| Layer | What it is | Model source |
|---|---|---|
| `src/` + Dockerfiles | the bug faulting on **real silicon** | the actual CPU |
| `tla/memory-models/` | our TLA+ store-buffer abstraction | hand-written (this repo) |
| **`herd7/`** | the SB litmus on the **reference ISA models** | **Intel / Arm (via herdtools7)** |
| `tla/LightEpoch*.tla` | the full algorithm + each fix | hand-written (this repo) |

herd7 is the bridge between "we modeled it ourselves" and "it happens on
hardware": it shows the *architecture's own specification* already declares the
unfenced pattern reorderable on AArch64 and un-fixable by release alone.
