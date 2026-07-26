# JIT disassembly — the fence, in the actual machine code

This folder shows the **native code the .NET JIT emits** for the epoch
announce/reclaim path of each variant, on **x86-64** and **AArch64**. It is the
most concrete view of the bug and the fixes: you can point at the single
instruction each fix adds (or fails to add) in the generated assembly.

* `x86_64/` — one `.asm` per variant, disassembled on an x64 runtime.
* `arm64/`  — one `.asm` per variant, disassembled on an AArch64 runtime.

Each file contains two methods:

* **`ProtectAndDrain`** — its first statement is the announce store
  `localCurrentEpoch = CurrentEpoch`. This is where the baseline, full-barrier,
  and interlocked variants differ.
* **`ComputeNewSafeToReclaimEpoch`** — the reclaimer's safe-epoch scan. This is
  where the *asymmetric* variant places its process-wide barrier (the announce
  store stays plain, like the baseline).

## The announce store, on AArch64 (the arch where the bug is live)

The relevant fragment of `ProtectAndDrain`, from `arm64/*.asm`:

| Variant | Announce instruction(s) | StoreLoad ordered? |
|---|---|---|
| **baseline** (`LightEpoch`) | `str x2, [x0]` → *(next: `ldr` of the object)* | **No** — plain store, the reader's load can pass it. **This is the bug.** |
| **full barrier** (`FixedLightEpoch`) | `str x2, [x0]` then `dmb ish` | **Yes** — `dmb ish` is a full StoreLoad fence (`Interlocked.MemoryBarrier()`). |
| **interlocked** (`FixedLightEpochWithInterlockedExchange`) | `swpal x2, x0, [x0]` | **Yes** — a sequentially-consistent atomic swap replaces the plain store and carries the ordering (`Interlocked.Exchange`). |
| **asymmetric** (`FixedLightEpochAsymmetricBarrier`) | `str x2, [x0]` (plain, like baseline) | Ordering moved to the reclaimer — see below. |

```asm
; baseline  Tsavorite.core.LightEpoch:ProtectAndDrain      (arm64)
        ldr     x2, [x19, #0x30]      ; x2 = CurrentEpoch
        str     x2, [x0]              ; announce: localCurrentEpoch = CurrentEpoch   <-- plain store
        ldr     x0, [x19, #0x28]      ; ...proceed straight to the next load. NO FENCE.

; full barrier  Tsavorite.core.FixedLightEpoch:ProtectAndDrain      (arm64)
        ldr     x2, [x19, #0x30]
        str     x2, [x0]              ; announce
        dmb     ish                   ; <-- StoreLoad fence (Interlocked.MemoryBarrier)

; interlocked  ...FixedLightEpochWithInterlockedExchange:ProtectAndDrain   (arm64)
        ldr     x2, [x19, #0x30]
        swpal   x2, x0, [x0]          ; <-- seq-cst swap = announce + fence in one op
```

The key negative result of the whole study is visible here too: the fix is
**not** a store-release. A `Volatile.Write` would emit `stlr` (store-release),
which still lets the following `ldr` reorder above it — exactly why
`SB+rel-aarch64` in `herd7/` stays *Allowed*. Only `dmb ish` or the seq-cst
`swpal` closes it.

### The asymmetric barrier, on AArch64

The asymmetric variant keeps the reader's announce a cheap plain `str` and puts
the ordering on the *reclaimer*, at the very top of the scan:

```asm
; asymmetric  ...FixedLightEpochAsymmetricBarrier:ComputeNewSafeToReclaimEpoch  (arm64)
G_M000_IG02:
        movz    x0, ...               ; address of the process-wide barrier thunk
        ldr     x0, [x0]
        blr     x0                    ; <-- call AsymmetricBarrier.FullBarrierAllCores()
        ...                           ;     (FlushProcessWriteBuffers / membarrier)
G_M000_IG03:                          ; only now does the slot scan begin
        ldr     x2, [x1, x2]
        cbz     x2, ...
```

## The same, on x86-64

x86-TSO already orders everything except StoreLoad, so the *only* difference
between variants is again the announce instruction:

| Variant | Announce instruction(s) |
|---|---|
| **baseline** | `mov qword ptr [rcx+rax], r8` — plain store, no fence |
| **full barrier** | `mov ...` then `lock or dword ptr [rsp], 0` — the locked no-op is how the JIT emits a StoreLoad fence on x86 |
| **interlocked** | `xchg qword ptr [rcx], rax` — `xchg` to memory is implicitly `lock`ed, so it is a full fence |
| **asymmetric** | `mov ...` (plain), and `call [AsymmetricBarrier:FullBarrierAllCores()]` at the top of the scan |

```asm
; baseline (x64)          mov  qword ptr [rcx+rax], r8      ; announce, then cmp drainCount — no fence
; full barrier (x64)      mov  qword ptr [rcx+rax], r8
                          lock or dword ptr [rsp], 0        ; <-- StoreLoad fence
; interlocked (x64)       xchg qword ptr [rcx], rax         ; <-- implicitly locked = fence + store
```

Note the important subtlety the x86 code makes concrete: an ordinary x86 `mov`
store *already* has release semantics, yet the baseline is still unordered w.r.t.
the following load — because release does not constrain StoreLoad. Only the
`lock`ed forms (`lock or`, `xchg`, or `mfence`) do. This is why "make it
`volatile`" is not a fix on either architecture.

## Reproducing

The listings are produced by the JIT's own disassembler
(`DOTNET_JitDisasm`), so they are exactly what the runtime executes. The
emulated arm64 runtime JITs real AArch64 machine code, so the disassembly is
identical to what a physical ARM64 CPU runs — the emulation affects *execution*,
not *code generation*.

```bash
docker build -f disasm/Dockerfile -t lightepoch-disasm .

# writes disasm/x86_64/*.asm
docker run --rm --platform linux/amd64 -v "$PWD/disasm/x86_64:/out" lightepoch-disasm
# writes disasm/arm64/*.asm
docker run --rm --platform linux/arm64 -v "$PWD/disasm/arm64:/out"  lightepoch-disasm
```

`tool/` is the tiny console app that invokes each variant's `ProtectAndDrain`
(through a delegate, to stop the JIT inlining it away) and `BumpCurrentEpoch`
(which drives `ComputeNewSafeToReclaimEpoch`) so both methods get compiled.
`capture.sh` sets `DOTNET_TieredCompilation=0` (compile straight to FullOpts),
`DOTNET_JitDisasm` to the two method names, and `DOTNET_JitDisasmDiffable=1`
(stable, address-free output), then splits the dump into one file per variant.
