# Benchmark results — what each fix costs (with variance + confidence)

Measured with **BenchmarkDotNet 0.14.0, default job** (auto-tuned: ~15
pilot/actual iterations after warmup), .NET 8. The default job — *not*
`--job short` — is used deliberately so the confidence intervals are tight enough
to make statistical claims. Every table below reports:

* **Mean** — arithmetic mean of all measured iterations.
* **Error** — *half* of the **99.9 %** confidence interval of the mean
  (BenchmarkDotNet's definition). Two means whose `Mean ± Error` intervals **do
  not overlap** differ at well beyond p < 0.001.
* **StdDev** — standard deviation of the per-iteration measurements (the
  run-to-run spread, i.e. the variance).

> These supersede the earlier `--job short` (3-iteration) numbers, whose Error
> bars were *larger than the differences themselves* and therefore could not
> support a claim like "5 % slower." See
> [How statistically confident are these claims?](#how-statistically-confident-are-these-claims)

Machines:

* **ARM64** — Azure `Standard_D4ps_v6` (Arm Neoverse-N2 / Cobalt-100), Ubuntu
  24.04, `Arm64 RyuJIT AdvSIMD`, bare-metal-class (not emulated). **These are the
  numbers that matter** — this is where the bug is real and where the fences
  actually emit work (`dmb ish` / `swpal`).
* **x86-64** — Windows 11 on a **Hyper-V VM**, `X64 RyuJIT AVX2`. A control.
  Note the virtualization caveat in the confidence section — it inflates
  locked-instruction latency.

Workloads:

* **EnterExit** — `Resume()` + `Suspend()`: the read-mostly hot path taken on
  every protected operation. This is what a fix *charges the common case*.
* **Reclaim** — `Resume()` + `BumpCurrentEpoch()` + `Suspend()`: runs the
  safe-epoch scan. Where the asymmetric fix moves its cost.
* **FenceMicro** — the *isolated* cost of one announce fence, same type, same
  store→load shape, differing only by an `Interlocked.MemoryBarrier()`. Zero
  type/layout confound — the cleanest measurement of the fence itself.
* **Tsavorite** — `Resume()` + `ProtectAndDrain()` + `Suspend()`: the **exact
  per-operation sequence Tsavorite's default `BasicContext` API pays** on every
  `Read`/`Upsert`/`RMW` (`UnsafeResumeThread` = `Resume` + `InternalRefresh`, then
  `UnsafeSuspendThread`). Two announce stores + a slot-reservation CAS + a release,
  per op. See the top-level README §8.
* **AmortizedRefresh** — a single `ProtectAndDrain()` with the thread already
  protected (`Resume` once in setup, `Suspend` once in cleanup): the cheap
  `UnsafeContext` idiom. The gap between this and **Tsavorite** is exactly the
  acquire/release machinery the default API adds on every operation.

---

## ARM64 (Neoverse-N2 — the meaningful platform)

### Enter/Exit — the reader hot path

| Variant | Mean | Error (99.9% CI/2) | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline (no fence — **incorrect**) | 14.40 ns | ±0.007 | 0.006 | 1.00× |
| full-barrier (`dmb ish`) | 17.28 ns | ±0.007 | 0.006 | **1.20×** |
| interlocked-exchange (`swpal`) | 17.49 ns | ±0.022 | 0.019 | **1.21×** |
| asymmetric (reader side) | 14.51 ns | ±0.026 | 0.025 | **1.01× (≈ free)** |

### Reclaim — the safe-epoch scan

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline | 131.0 ns | ±0.49 | 0.45 | 1.00× |
| full-barrier | 135.8 ns | ±0.71 | 0.67 | 1.04× |
| interlocked-exchange | 141.7 ns | ±0.95 | 0.84 | 1.08× |
| asymmetric (reclaimer side) | 947.0 ns | ±6.87 | 6.09 | **7.23×** |

### FenceMicro — the isolated fence cost

| Variant | Mean | Error | StdDev |
|---|---:|---:|---:|
| `store; load` (no fence) | 0.0514 ns | ±0.0009 | 0.0008 |
| `store; MemoryBarrier; load` (`dmb ish`) | 4.4258 ns | ±0.0048 | 0.0040 |

**Isolated `dmb ish` ≈ 4.37 ns.** Of that, ~2.88 ns lands on the enter-path
critical path (the full-barrier's +20 % above); the rest is hidden by surrounding
work / out-of-order execution.

### Tsavorite (default API) — per-op `Resume`+`Refresh`+`Suspend`

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline (no fence — **incorrect**) | 16.04 ns | ±0.010 | 0.010 | 1.00× |
| full-barrier (`dmb ish` ×2) | 20.90 ns | ±0.017 | 0.015 | **1.30×** |
| interlocked-exchange (`swpal` ×2) | 22.98 ns | ±0.021 | 0.018 | **1.43×** |
| asymmetric (reader side) | 16.08 ns | ±0.014 | 0.013 | **1.00× (≈ free)** |

The default API announces **twice** per op (Acquire + ProtectAndDrain), so the
full-barrier fix pays **two** `dmb ish` (≈ +4.86 ns, 30 %) and interlocked pays
two `swpal` (+6.94 ns, 43 %) — roughly double the single-announce EnterExit cost
above, as expected. The asymmetric fix is still free on the reader.

### AmortizedRefresh — protect once, `ProtectAndDrain` per op

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline (no fence — **incorrect**) | 6.013 ns | ±0.0210 | 0.019 | 1.00× |
| full-barrier (`dmb ish`) | 7.844 ns | ±0.0132 | 0.012 | **1.30×** |
| interlocked-exchange (`swpal`) | 7.201 ns | ±0.0084 | 0.008 | **1.20×** |
| asymmetric (reader side) | 6.149 ns | ±0.0044 | 0.004 | **1.02× (≈ free)** |

A single naked `ProtectAndDrain` is **6.01 ns** vs the per-op default's
**16.04 ns** — i.e. the default API's acquire/release adds **~10 ns per op** on
ARM64 (a 2.7× multiplier) that has nothing to do with the fence. Here the
full-barrier fix is a single `dmb ish` (+1.83 ns).

## x86-64 (Hyper-V VM — control)

### Enter/Exit

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline | 16.11 ns | ±0.043 | 0.038 | 1.00× |
| full-barrier | 17.79 ns | ±0.066 | 0.059 | 1.10× |
| interlocked-exchange | 17.57 ns | ±0.106 | 0.094 | 1.09× |
| asymmetric (reader side) | 17.01 ns | ±0.040 | 0.038 | 1.06× |

### Reclaim

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline | 176.7 ns | ±0.97 | 0.86 | 1.00× |
| full-barrier | 159.5 ns | ±3.12 | 2.92 | 0.90× |
| interlocked-exchange | 160.6 ns | ±3.20 | 3.93 | 0.91× |
| asymmetric (reclaimer side) | 757.9 ns | ±10.10 | 7.88 | 4.29× |

### FenceMicro

| Variant | Mean | Error | StdDev |
|---|---:|---:|---:|
| `store; load` (no fence) | 0.0130 ns | ±0.0031 | 0.0026 |
| `store; MemoryBarrier; load` (`lock or [rsp],0`) | 7.6345 ns | ±0.0181 | 0.0160 |

**Isolated `lock or` ≈ 7.62 ns** — higher than ARM's `dmb`, largely a
virtualization artifact (locked ops are expensive to trap under Hyper-V). Yet
almost none of it lands on the enter path (see below).

### Tsavorite (default API) — per-op `Resume`+`Refresh`+`Suspend`

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline | 19.33 ns | ±0.072 | 0.067 | 1.00× |
| full-barrier | 20.59 ns | ±0.204 | 0.191 | 1.06× |
| interlocked-exchange | 19.17 ns | ±0.048 | 0.045 | 0.99× |
| asymmetric (reader side) | 19.34 ns | ±0.054 | 0.051 | 1.00× |

On x86-TSO the two announce fences add only ~6 % (full-barrier) and interlocked
is *within noise* of baseline — because the Acquire path already contains a
`lock cmpxchg` (the slot-reservation CAS), which is itself a full barrier, so an
extra `lock or` there is nearly redundant. This is the quantified basis for §8's
"x86 barely notices the fix" claim on the *real* API.

### AmortizedRefresh — protect once, `ProtectAndDrain` per op

| Variant | Mean | Error | StdDev | vs baseline |
|---|---:|---:|---:|---:|
| baseline | 8.231 ns | ±0.0257 | 0.024 | 1.00× |
| full-barrier | 7.940 ns | ±0.0948 | 0.089 | 0.96× |
| interlocked-exchange | 6.640 ns | ±0.0271 | 0.025 | 0.81× |
| asymmetric (reader side) | 8.210 ns | ±0.0205 | 0.019 | 1.00× |

⚠️ The "faster-than-baseline" ratios here (0.96×, 0.81×) are **layout artifacts,
not real speedups** — see [Caution 1](#caution-1--significant--caused-by-the-fence-cross-variant-layout-confound).
On this virtualized x86 box, sub-nanosecond cross-variant deltas are dominated by
code/field placement, not the fence. The honest x86 reading is "the fence is in
the noise."

---

## How statistically confident are these claims?

The bar used throughout: a difference is called **significant** only if the two
`Mean ± Error` (99.9 % CI) intervals do **not overlap** — a strong bar
(p < 0.001). But "significant" means only *"the two numbers really differ"*,
**not** *"the difference is caused by the fence"*; the two cautions below matter.

| Claim | Numbers | Non-overlapping 99.9% CIs? | Verdict |
|---|---|---|---|
| **ARM64: full-barrier ~20 % slower on hot path** | 17.28 vs 14.40 ns, gap 2.88 ns ≫ ±0.014 | **Yes**, by ~200× the combined error | **Rock-solid.** The headline read-path cost; not noise. |
| **ARM64: interlocked-exchange ≈ full-barrier (~21 %)** | 17.49 vs 17.28 ns | Yes (±0.022 / ±0.007) | Real; the RMW is a hair costlier than a bare `dmb`. |
| **ARM64: asymmetric reader is essentially free** | 14.51 vs 14.40 ns, +0.11 ns (+0.8 %) | Yes, *technically* | **Distinguishable but practically zero.** Reader code is byte-identical to baseline, so the 0.11 ns is layout, not fencing. Call it "free." |
| **ARM64: asymmetric reclaim 7.2× baseline** | 947 vs 131 ns | Yes, enormously | **Rock-solid and causal** (a real process-wide `membarrier` IPI). |
| **x86: full-barrier ~10 % slower** | 17.79 vs 16.11 ns | Yes | Significant **but misleading** — fence-attributable part is ~5 %, not 10 % (caution 1). |
| **x86: full-barrier reclaim 10 % *faster*** | 159.5 vs 176.7 ns | Yes | **Significant yet not real** — a fix cannot speed up reclaim. Textbook artifact (caution 1). |

### Caution 1 — "significant" ≠ "caused by the fence" (cross-variant layout confound)

Each variant is a **separate type**, so it gets its own JITted code at its own
address, its own field offsets, and its own cache placement — a per-variant
offset unrelated to fencing. Two measurements prove it is real and non-trivial:

* On **x86**, the `asymmetric` reader path has **no fence** and **byte-identical
  hot-path code to baseline**, yet measures **+0.90 ns (+5.6 %)** over baseline
  with non-overlapping CIs. That entire 0.90 ns is confound, not fencing.
* On **x86 Reclaim**, the full-barrier variant comes out **10 % faster** than
  baseline — impossible as a causal effect (its reclaim path is baseline's plus
  an enter fence). Another ~17 ns of pure cross-variant/scheduling artifact.

**Consequence for the "5 %" question:** on x86 the *raw* baseline→full delta is
1.68 ns (10.4 %), but ~0.9 ns of that is the layout offset visible in the
plain-store asymmetric variant. The **fence-attributable** cost is closer to
`full − asymmetric ≈ 0.78 ns (~4.8 %)`, consistent with the isolated micro result
being almost entirely hidden on x86 (the enter path already runs a `lock cmpxchg`
slot-reservation CAS that drains the store buffer — see main README §2.1 and §8).
So: **on x86 the honest fence cost is ~5 %, and even that is mostly measurement
scaffolding; on real hardware it is smaller still.**

On **ARM64** the confound is far smaller — the plain-store asymmetric reader is
+0.11 ns (not +0.9 ns) — so the ARM 20 % figure is clean and trustworthy.

### Caution 2 — the x86 box is virtualized

The x86 run is inside a Hyper-V VM, which inflates locked-instruction / fence
latency (the isolated `lock or` reads 7.6 ns here vs a typical ~3–5 ns on
bare-metal x86). It does **not** change the qualitative conclusion (x86 hides the
bug; the fence is nearly free in-path), but treat the absolute x86 fence numbers
as an upper bound.

### The one number to trust

If you want a single, confound-free figure: the **FenceMicro** rows. Same type,
same shape, only the barrier differs, tiny Error bars. Isolated fence cost:
**~4.4 ns on Neoverse-N2 (`dmb ish`)**, **~7.6 ns on the virtualized x86
(`lock or`)**. How much you actually pay depends entirely on how much independent
work surrounds the announce — on the ARM enter path ~2.9 ns of it lands (hence
+20 %); on the x86 enter path almost none does (hence ~5 %).

---

## Reading the numbers (bottom line)

* **On ARM64 the fence is real and measurable: ~20 % per `Resume()`/`Suspend()`**
  for the full-barrier or interlocked-exchange fix — airtight, not noise.
* **The asymmetric fix makes readers pay nothing** (1.01× — a 0.11 ns,
  layout-level difference), by keeping the plain announce store and moving all
  ordering to the reclaimer.
* **…at the cost of a much heavier reclaim** (7.2× on ARM64 from the process-wide
  `membarrier`). But reclaim is rare and batched, whereas enter/exit is on the
  critical path of every operation (and in Tsavorite's default API, *every*
  operation — see main README §8). So for read-heavy workloads the asymmetric
  barrier is the best trade; for balanced workloads the one-instruction
  interlocked/full-barrier fix (~1.20×) is the simplest safe choice.
* **On Tsavorite's *actual* default API (per-op `Resume`+`Refresh`+`Suspend`)**
  the fix costs **+30 % full-barrier / +43 % interlocked on ARM64** (two announce
  fences per op, not one) and **~6 % / noise on x86**. The **asymmetric fix is
  still free on the reader (1.00×)** even under this pattern. Separately, the
  per-op API itself costs **~2.7× the amortized `ProtectAndDrain` idiom** on ARM64
  (16.0 ns vs 6.0 ns) — the acquire/release machinery, not the fence, dominates.
  If Tsavorite is latency-sensitive, adopting the `UnsafeContext`/refresh idiom
  saves far more than the fence ever costs.

## Reproducing

```bash
cd bench/LightEpoch.Bench
dotnet run -c Release -- --filter '*'                    # full run, default job (what is shown here)
dotnet run -c Release -- --filter '*EnterExit*'          # just the reader hot path
dotnet run -c Release -- --filter '*FenceMicro*'         # just the isolated fence
dotnet run -c Release -- --filter '*Tsavorite*'          # Tsavorite default API (per-op)
dotnet run -c Release -- --filter '*AmortizedRefresh*'   # the cheap UnsafeContext idiom
```

Run on an **ARM64 host** for the numbers that matter. Do **not** use `--job
short` if you intend to make statistical claims — its 3-iteration Error bars are
wider than the effects being measured.
