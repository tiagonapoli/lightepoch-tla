# herd7 checks of the emitted machine code

This is the **second** herd7 suite in this repository, and it differs from its
sibling in `../` in one specific way that is the whole reason it exists.

The suite in `../` is hand-written: each `.litmus` file encodes the instruction
sequence we *believed* RyuJIT emits, and the belief was justified separately by
dumping and disassembling emitted bytes. That is sound, but the litmus files and
the disassembly are two artifacts that can drift apart, and the mapping between
them lives in prose.

This suite inverts that. It starts from the **actual RyuJIT dump**, committed
verbatim in `jit/`, and every instruction in every test is traceable back to a
labelled block in it. `REDUCTION.md` accounts for each line that was removed and
argues why the removal cannot change the result. If you doubt a test, you can
check it against the dump rather than against an argument.

It also widens the coverage: the sibling suite is AArch64-only, while this one
covers both architectures, which is what makes the x86-vs-ARM dissociations in
`memory-ordering-bugs-found.md` statements about emitted code rather than about
idealised models.

The other two layers remain what they were: the TLA+ specs in `../../tla/` check
the *algorithm*, and the harnesses in `../../src/` check whether the bug shows up
on real hardware. Neither says anything about what the JIT emits.

```
docker build -t lightepoch-herd herd/jit-derived
docker run --rm lightepoch-herd
```

The container exits non-zero if any result differs from its expectation. As
with the TLA+ runner, an optional substring selects which rows to run:

```
docker run --rm lightepoch-herd arm64-refresh
```

To run outside Docker you need `herd7` on `PATH` (`opam install herdtools7`):

```
bash herd/jit-derived/run.sh
```

## Results

| Test | Expected | Meaning |
| --- | --- | --- |
| `x86-announce-sb-main` | Sometimes | the shipped bug, under x86-TSO |
| `x86-announce-sb-fixed` | Never | closed by the CAS-carried announce |
| `arm64-announce-sb-main` | Sometimes | same bug, under `aarch64.cat` |
| `arm64-announce-sb-fixed` | Never | closed by the CAS-carried announce |
| `x86-refresh-mp-main` | Never | load-load, so x86 was never exposed |
| `x86-refresh-mp-fixed` | Never | the acquire load is free on x86 |
| `arm64-refresh-mp-main` | Sometimes | **ARM-only**: `CurrentEpoch` is read by a plain `LDP` |
| `arm64-refresh-mp-fixed` | Never | closed by `LDAPR` |
| `arm64-release-plainstore` | Sometimes | counterfactual: `STR` in place of the `STLR` |
| `arm64-release-fixed` | Never | `STLR` orders the handover |
| `arm64-release-loadstore-main` | Sometimes | **ARM-only bug**: the slot clear can precede the dereference |
| `arm64-release-loadstore-fixed` | Never | `STLR` is ordered after the dereference |
| `x86-release-loadstore-main` | Never | TSO preserves Load→Store |
| `x86-composed-main` | Sometimes | the whole sequence, unfixed |
| `x86-composed-fixed` | Never | the whole sequence, fixed |
| `arm64-composed-main` | Sometimes | the whole sequence, unfixed |
| `arm64-composed-fixed` | Never | the whole sequence, fixed |

Each `Never` row is paired with a row that must be violated, for the same
reason the TLA+ suite pairs its rows: a suite that cannot detect the bug it
reports absent has established nothing.

The last four rows are the ones that matter most. Everything above them is a
single hazard shape studied in isolation, which is how the shapes are
*understood* but not on its own an argument that the program is correct. The
composed rows run `Acquire` → `ProtectAndDrain` → critical section → `Release`
against a full reclaimer, with every memory access of the reduced listing
present, and say that no execution of the fixed sequence frees an object under
a live reader.

`memory-ordering-bugs-found.md` explains each finding, including the two that
only exist on AArch64, the earlier claim this pass retracts, and a false
positive the first composed encoding produced.

## Layout

| Path | What it is |
| --- | --- |
| `jit/*.asm` | verbatim RyuJIT FullOpts dumps, x86-64 and AArch64, for `origin/main` and the fix |
| `jit/reduced/*.reduced.asm` | the same code cut down to what herd7 can parse |
| `REDUCTION.md` | every removal and substitution, and why none of them can change the result |
| `MODEL.md` | the protocol the tests encode and what each `exists` clause means operationally |
| `memory-ordering-bugs-found.md` | the findings, split by architecture |
| `litmus/` | the herd7 tests |
| `capture/` | the harness that produced the dumps |
| `run.sh`, `Dockerfile` | the matrix runner |

The raw dumps are committed deliberately. herd7 is only evidence about the code
that ships today — a future JIT may emit something else — so the reduced
listings have to be auditable against the thing they were reduced from.

## Regenerating the dumps

`capture/` is a standalone console app that news up a `LightEpoch` and drives
it. The epoch operations are wrapped in `[MethodImpl(NoInlining)]` methods
(`OpResume`, `OpSuspend`, `OpProtectAndDrain`, `OpBumpCurrentEpoch`) so each one
gets its own listing while everything inside it still inlines as it would at a
real call site — without those wrappers the whole thing collapses into `Main`.

Point `capture/Disasm.csproj` at the `LightEpoch.cs` you want, build Release,
and run the **apphost** (not `dotnet X.dll` — the environment variables below
leak into the CLI muxer otherwise):

```powershell
$env:DOTNET_TieredCompilation = '0'
$env:DOTNET_TieredPGO         = '0'
$env:DOTNET_ReadyToRun        = '0'
$env:DOTNET_JitDisasmDiffable = '1'
$env:DOTNET_JitDisasm         = 'OpResume OpProtectAndDrain OpSuspend BumpCurrentEpoch ComputeNewSafeToReclaimEpoch'
.\bin\Release\net10.0\Disasm.exe 2>&1 | Out-String | Set-Content jit\x86-fixed.asm
```

Two things that cost time the first go round:

- `DOTNET_JitDisasm` matches **bare method names, space-separated**. The
  `Class:Method` form silently matches nothing.
- `DOTNET_JitDisasmSummary=1` lists what was actually compiled and under what
  name. Reach for it the moment a filter produces no output.

That first point also corrects something recorded earlier in this study. The
disassembly in `../../artifacts/jit-dumps.md` was obtained by dumping emitted
bytes and disassembling them externally, because "the `DOTNET_JitDisasm` knobs
produced no output". They do work on a release runtime — the filter was simply
being given a form it does not match. The byte-dump route was more work than it
needed to be, and this suite uses the JIT's own listing instead.

`DOTNET_JitDisasmDiffable=1` replaces addresses and large immediates with
`0xD1FFAB1E`, which is what makes the committed dumps stable enough to diff
across runs.

For AArch64 the dumps in `jit/` were taken on an Azure `Standard_D8ps_v5`
(Ampere Altra) running Ubuntu 24.04 arm64 with the .NET 10 SDK — any AArch64
machine with the same SDK will do. Same environment variables, and set
`DOTNET_ROOT` if the SDK is not in the default location.

## Scope, honestly

herd7 checks emitted instructions against the *architecture's* memory model.
That is a different and weaker contract than the .NET memory model, and it says
nothing about codegen the JIT might produce tomorrow. The dumps are committed
precisely because the tests are only evidence about the code that ships today.

What this suite adds over the rest of the study is not a new verdict — the
sibling suite and the ARM64 hardware runs already established that the refresh
path needs an acquire load. It is that the verdict now rests on instructions
nobody transcribed by hand, and that the x86 side is covered too, which is what
turns "the acquire load is free on x86" from an expectation into an observation:
the two x86 `ProtectAndDrain` listings are byte-identical, and herd7 gives both
tests the same hash.
