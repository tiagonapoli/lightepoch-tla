# 16-core ARM64 soak results

Repro runs of the `LightEpoch` missing-StoreLoad-fence bug on two Azure ARM64 VMs,
both **16 physical cores, no SMT, 1 NUMA node**, Windows 11 ARM64 (10.0.26200),
.NET 10 self-contained `win-arm64` build of `LightEpoch.Repro`.

Detection is the default unmap mode: `VirtualFree(MEM_RELEASE)` driven by the epoch's
own `BumpCurrentEpoch` → `ComputeNewSafeToReclaimEpoch` drain decision. A fault is a
genuine hardware `0xC0000005` that terminates the process.

## Hardware under test

| VM | Azure size | CPU | Microarch | Phys cores | SMT | NUMA |
|---|---|---|---|---|---|---|
| `tiagonapoli-arm64-test-n1` | `Standard_D16ps_v5` | Ampere Altra | Neoverse-N1 | 16 | no | 1 |
| `tiagonapoli-arm64-test-n2` | `Standard_D16ps_v6` | Microsoft Cobalt 100 | Neoverse-N2 | 16 | no | 1 |

## Core count matters

The same two machines were first tested at **4 physical cores** (`D4ps_v5` /
`D4ps_v6`), then resized to 16. Concurrency is the dominant factor in how quickly the
race window opens: every additional pair is another independent chance per unit time
for the reclaimer's scan to run before the reader's unfenced announce becomes visible.

| CPU | Cores | Pattern | Pairs | `baseline` |
|---|---|---|---|---|
| Cobalt 100 / N2 | 4 | `bare` | 1 | SURVIVED 120 s |
| Cobalt 100 / N2 | 4 | `bare` | 2 | **FAULT @ 8 s** |
| Cobalt 100 / N2 | 16 | `bare` | 2 | **FAULT @ 36 s** |
| Cobalt 100 / N2 | 16 | `bare` | 4 | SURVIVED 120 s |
| Cobalt 100 / N2 | 16 | `bare` | 8 | **FAULT @ 7 s** |
| Cobalt 100 / N2 | 16 | `resume-and-refresh` | 4 | **FAULT @ 73 s** |
| Ampere Altra / N1 | 4 | `bare` | 1 | SURVIVED 120 s |
| Ampere Altra / N1 | 4 | `bare` | 2 | SURVIVED 120 s |
| Ampere Altra / N1 | 16 | `bare` | 2 | SURVIVED 120 s |
| Ampere Altra / N1 | 16 | `bare` | 4 | SURVIVED 120 s |
| Ampere Altra / N1 | 16 | `bare` | 8 | SURVIVED 120 s |
| Ampere Altra / N1 | 16 | `resume-and-refresh` | 4 | **FAULT @ 72 s** |

Two things stand out:

* **Neoverse-N1 never faulted under `bare` at any pair count tested.** It only
  reproduces under `resume-and-refresh`, the epoch sequence a real Tsavorite
  `BasicContext` operation performs. N2 reproduces under both.
* **N1 at 4 cores produced no fault at all**; going to 16 cores is what made it
  reproducible.

## The fix holds

`fullbarrier` was run for a full **300 s** on each machine, using the exact
configuration that faults the baseline on that machine.

| VM | Config | `fullbarrier` |
|---|---|---|
| n1 (Altra / N1) | `resume-and-refresh`, 4 pairs | **SURVIVED 300 s** |
| n2 (Cobalt / N2) | `bare`, 8 pairs | **SURVIVED 300 s** |

## Back-to-back soak — 50 faults

Each attempt runs the `baseline` build until it faults or a 300 s cap is reached.
A capped run is a `MISS`; the process is killed and the next attempt starts.

### n2 — Cobalt 100 / Neoverse-N2, `bare`, 8 pairs — COMPLETE

```
faults    = 50 / 50
attempts  = 51
hit rate  = 98 %
time to fault: avg 40 s, min 1 s, max 158 s
elapsed:  01:08:27Z -> 01:51:43Z  (~43 min for 50 faults)
```

Only one attempt (#30) reached the 300 s cap without faulting.

Per-attempt time to fault, in order (seconds):

```
122, 45, 72, 10, 10, 39, 35, 44, 102, 2, 5, 8, 86, 84, 24, 20, 36, 51, 18, 5,
81, 44, 8, 98, 158, 47, 2, 3, 4, MISS, 29, 6, 3, 2, 19, 24, 2, 2, 78, 4,
8, 32, 2, 31, 5, 8, 1, 122, 122, 146, 89
```

### n1 — Ampere Altra / Neoverse-N1, `resume-and-refresh` — first attempt at 4 pairs

Abandoned after 21 attempts: the hit rate was too low to reach 50 faults in reasonable
wall-clock time. Kept because the numbers are themselves a result — N1 is far more
resistant to this race than N2.

```
faults    = 6 / 50
attempts  = 21
hit rate  = 29 %
time to fault: avg 61 s, min 20 s, max 143 s
elapsed:  ~90 min  (projected ~12 h to reach 50)
```

Per-attempt time to fault, in order (seconds):

```
28, MISS, MISS, 44, MISS, 20, 57, MISS, MISS, MISS, MISS, MISS, MISS, MISS,
MISS, MISS, 76, 143, MISS, MISS, MISS
```

The race is bursty rather than uniformly distributed: nine consecutive misses
(attempts 8-16) were followed immediately by two faults.

### n1 — Ampere Altra / Neoverse-N1, `resume-and-refresh`, 8 pairs — IN PROGRESS

Restarted using all 16 cores (8 pairs instead of 4) with the per-attempt cap lowered
to 120 s, so a miss costs 2 min rather than 5. `fullbarrier` was re-validated at this
pair count first and again **SURVIVED 300 s**.

```
faults    = 8 / 50
attempts  = 24
hit rate  = 33 %
time to fault: avg 47 s, min 7 s, max 94 s
elapsed:  ~39 min  (projected ~4.1 h to reach 50)
```

Per-attempt time to fault, in order (seconds):

```
MISS, 41, MISS, 94, 7, MISS, 53, MISS, MISS, MISS, 50, 11, MISS, MISS,
MISS, MISS, MISS, MISS, MISS, 59, MISS, MISS, MISS, 61
```

Doubling the pairs halved the cost of a miss (120 s vs 300 s), but the hit rate has
settled back to roughly what 4 pairs gave once the sample grew — 33 % over 24 attempts
against 29 % over 21. The burstiness persists: seven consecutive misses
(attempts 13-19) sit between clusters of faults. N1 is simply far more resistant to
this race than N2, which hit 98 %.

## Faulting stack

Identical on every fault, on both machines — the reader dereferencing a page the
epoch already unmapped:

```
Fatal error.
System.AccessViolationException: Attempted to read or write protected memory.
   at LightEpoch.Repro.Common.Litmus`2[[LightEpoch.Core.BaselineOps, ...],
                                       [LightEpoch.Repro.Common.BareReproPattern, ...]].ReaderLoop()
   at System.Threading.Thread.StartCallback()
```

Under `resume-and-refresh` the second type argument is
`LightEpoch.Repro.Common.ResumeAndRefreshReproPattern` instead.

## How these runs were driven

```powershell
dotnet publish src/LightEpoch.Repro -c Release -r win-arm64 --self-contained true

$env:DOTNET_gcServer = 1
LightEpoch.Repro.exe --pattern bare               --impl baseline    --pairs 8 --rounds 100000000000
LightEpoch.Repro.exe --pattern resume-and-refresh --impl baseline    --pairs 4 --rounds 100000000000
LightEpoch.Repro.exe --pattern bare               --impl fullbarrier --pairs 8 --rounds 100000000000
```
