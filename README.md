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
2. **Formal TLA+ models** (`tla/`) of the x86-TSO (total store order) and ARM64 memory models, and
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
`BasicContext` operation ([§8](FullReport.md#8-how-tsavorite-actually-uses-lightepoch)).

### Hardware under test

| Machine | Architecture | CPU | Microarch | Phys cores / LPs | SMT | NUMA nodes |
|---|---|---|---|---|---|---|
| Azure `D4ps_v5` | **ARM64** | Ampere Altra | Neoverse-N1 | 4 / 4 | no | 1 |
| Azure `D4ps_v6` | **ARM64** | Microsoft Cobalt 100 | Neoverse-N2 | 4 / 4 | no | 1 |
| Azure `D8ps_v5` | **ARM64** | Ampere Altra | Neoverse-N1 | 8 / 8 | no | 1 |
| local workstation | **x86-64** | Intel i7-12700K | Alder Lake | 12 / 20 | yes (P-cores) | 1 |
| Azure `D64s_v4` | **x86-64** | Intel Xeon Platinum 8272CL | Cascade Lake | 32 / 64 | yes | **2** |

Threads are always pinned one per **physical** core; SMT siblings are never paired
(they share a store buffer, so the race window cannot open at all).

### ARM64 — hardware access violation (`0xC0000005`)

Detection is a genuine unmapped-page fault. "Time to fault" is wall-clock from
process start; `SURVIVED` means the run was killed at the cap with no fault.

| CPU (phys cores) | Repro | Threads (pairs) | `baseline` (buggy) | `fullbarrier` (fixed) |
|---|---|---|---|---|
| Cobalt 100 / N2 (4) | `bare` | 2 (1 pair) | **FAULT @ 19 s** | SURVIVED 600 s |
| Cobalt 100 / N2 (4) | `resume-and-refresh` | 4 (2 pairs) | **FAULT @ 29 s** | SURVIVED 300 s |
| Ampere Altra / N1 (4) | `bare` | 2 (1 pair) | no fault in 120 s | SURVIVED 600 s |
| Ampere Altra / N1 (4) | `resume-and-refresh` | 4 (2 pairs) | no fault in 300 s | — |
| Ampere Altra / N1 (8) | `bare` | 4 (2 pairs) | **FAULT @ 15 s** | SURVIVED 300 s |
| Ampere Altra / N1 (8) | `bare` | 6 (3 pairs) | **FAULT @ 113 s** | SURVIVED 300 s |
| Ampere Altra / N1 (8) | `resume-and-refresh` | 4 (2 pairs) | **FAULT @ 96 s** | SURVIVED 300 s |
| Ampere Altra / N1 (8) | `resume-and-refresh` | 6 (3 pairs) | no fault in 300 s | — |

Faulting stack, every time — the reader dereferencing a page the epoch already freed:

```
Fatal error.
System.AccessViolationException: Attempted to read or write protected memory.
   at LightEpoch.Repro.Common.Litmus`2[[LightEpoch.Core.BaselineOps, ...],
                                       [LightEpoch.Repro.Common.BareReproPattern, ...]].ReaderLoop()
   at System.Threading.Thread.StartCallback()
```

### x86-64 — logical use-after-free detection

x86 needs a different detection mechanism, because the memory unmap used on ARM64
forces a TLB-shootdown IPI that introduces a memory barrier on the reader and
destroys the very window under test
(the full explanation is
[Appendix A](FullReport.md#appendix-a-why-the-unmap-based-repro-cannot-fault-on-x86-tlb-shootdown)).
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
  result (`X86TSO` and `ARM64` with no fence both **VIOLATED**).
* **Every fix was clean under the conditions that broke the baseline.**
  `fullbarrier` was run on every machine and every configuration in the tables above
  and never faulted or violated; `interlocked` and `asymmetric` were additionally
  clean across all x86-64 quarantine runs. The buggy build failed on both
  architectures under exactly the same conditions.

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
validated with `--self-test` — see [Appendix A.7](FullReport.md#a7-validating-the-detector).

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

## Full report

The analysis behind these results — the algorithm and the bug, the x86-TSO and ARM64
memory models, each candidate fix, how the repros detect a use-after-free, how
Tsavorite actually drives the epoch, and the TLA+ models — is in
**[FullReport.md](FullReport.md)**.

