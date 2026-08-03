# JIT disassembly dumps

Per-method x64 codegen captured with DOTNET_JitDisasm for each LightEpoch
variant. These back the codegen claims in the README: the CAS announce is a
single lock cmpxchg and the acquire load is a plain mov on x86.

## jit-acqload
```
   1: JIT compiled System.Guid:FormatGuidVector128Utf8(System.Guid,bool) [FullOpts with Synthesized PGO, IL size=304, code size=152]
   2: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:CreateAndCache(System.RuntimeType) [FullOpts with Synthesized PGO, IL size=165, code size=399]
   3: JIT compiled System.Buffers.SearchValues:TryGetSingleRange[char](System.ReadOnlySpan`1[char],byref,byref) [FullOpts, IL size=294, code size=386]
   4: JIT compiled System.Buffers.AsciiCharSearchValues`2[System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst]:IndexOfAny(System.ReadOnlySpan`1[char]) [FullOpts, IL size=30, code size=21]
   5: JIT compiled System.Buffers.IndexOfAnyAsciiSearcher:IndexOfAnyCore[int,System.Buffers.IndexOfAnyAsciiSearcher+DontNegate,System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst,System.Buffers.IndexOfAnyAsciiSearcher+IndexOfAnyResultMapper`1[short]](byref,int,byref) [FullOpts with Synthesized PGO, IL size=572, code size=491]
   6: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
   7: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   8: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   9: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  10: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
  11: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  12: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  13: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  14: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  15: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=26, code size=37]
  16: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  17: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  18: JIT compiled System.Threading.Thread:GetThreadStaticsBase() [FullOpts, IL size=18, code size=24]
  19: JIT compiled LightEpoch.Repro.Program:Main(System.String[]) [FullOpts, IL size=7, code size=16]
  20: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run(System.String[]) [FullOpts, IL size=180, code size=610]
  21: JIT compiled LightEpoch.Repro.Common.ReproRunner:Guarded(System.Func`1[int]) [FullOpts, IL size=32, code size=100]
  22: JIT compiled LightEpoch.Repro.Common.ReproRunner+<>c__DisplayClass0_0:<Run>b__1() [FullOpts, IL size=17, code size=29]
  23: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String[]) [FullOpts, IL size=1930, code size=6826]
  24: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryReadLong(System.String[],byref,byref) [FullOpts, IL size=25, code size=129]
  25: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryRead(System.String[],byref,byref) [FullOpts, IL size=29, code size=65]
  26: JIT compiled LightEpoch.Repro.Common.CoreTopology:Enumerate() [FullOpts, IL size=19, code size=6]
  27: JIT compiled LightEpoch.Repro.Common.CoreTopology:EnumerateWindows() [FullOpts, IL size=325, code size=943]
  28: JIT compiled LightEpoch.Repro.Common.CoreTopology:NumaNodesByLogicalProcessor() [FullOpts, IL size=220, code size=498]
  29: JIT compiled (dynamicClass):IL_STUB_PInvoke(int,nint,byref) [FullOpts, IL size=68, code size=186]
  30: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:.cctor() [FullOpts, IL size=12, code size=45]
  31: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:AddWithResize(LightEpoch.Repro.Common.CoreTopology+PhysicalCore) [FullOpts, IL size=39, code size=124]
  32: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:set_Capacity(int) [FullOpts, IL size=86, code size=124]
Resume + Refresh repro  impl=casannounce  rounds=1  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
  33: JIT compiled System.Runtime.CompilerServices.DefaultInterpolatedStringHandler:AppendFormatted[int](int) [FullOpts, IL size=257, code size=183]
  34: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:Replace(System.RuntimeType,System.__Canon) [FullOpts with Synthesized PGO, IL size=152, code size=336]
  35: JIT compiled LightEpoch.Repro.Common.CoreTopology:Describe() [FullOpts, IL size=202, code size=843]
  36: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:System.Collections.Generic.IEnumerable<T>.GetEnumerator() [FullOpts, IL size=30, code size=160]
  37: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:MoveNext() [FullOpts, IL size=105, code size=126]
  38: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Current() [FullOpts, IL size=7, code size=21]
  39: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:Dispose() [FullOpts, IL size=1, code size=1]
  40: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Count() [FullOpts, IL size=7, code size=4]
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
  41: JIT compiled LightEpoch.Repro.Common.ReproRunner:WarnIfSamePhysicalCore(System.Collections.Generic.IReadOnlyList`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore],int,int) [FullOpts, IL size=155, code size=769]
pair 0: cores(reclaimer=0,reader=2)
  42: JIT compiled LightEpoch.Repro.Common.ReproRunner:RunSingle[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String,long,int,int,int,bool,bool,int,bool,int[]) [FullOpts, IL size=251, code size=953]
  43: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:.ctor(long,int,int,int,bool,int,bool,int[]) [FullOpts, IL size=159, code size=257]
  44: JIT compiled System.Activator:CreateInstance[LightEpoch.Core.CasAnnounceOps]() [FullOpts, IL size=67, code size=83]
  45: JIT compiled LightEpoch.Core.CasAnnounceOps:.ctor() [FullOpts, IL size=12, code size=55]
  46: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.ctor() [FullOpts, IL size=173, code size=447]
  47: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:SelectInstance() [FullOpts, IL size=111, code size=437]
  48: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.cctor() [FullOpts, IL size=96, code size=236]
  49: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Run() [FullOpts, IL size=856, code size=4154]
ops = cas-announce (FixedLightEpochWithCasAnnounce)
  50: JIT compiled LightEpoch.Repro.Common.PlatformNative:Alloc(nuint) [FullOpts, IL size=92, code size=138]
  51: JIT compiled LightEpoch.Repro.Common.PlatformNative:.cctor() [FullOpts, IL size=26, code size=1]
  52: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint,uint,uint) [FullOpts, IL size=71, code size=181]
  53: JIT compiled LightEpoch.Repro.Common.PlatformNative:Pin(int) [FullOpts, IL size=299, code size=640]
  54: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint) [FullOpts, IL size=51, code size=164]
  55: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReaderLoop() [FullOpts, IL size=100, code size=1658]
  56: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReclaimerLoop() [FullOpts, IL size=247, code size=1757]
  57: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch(System.Action) [FullOpts, IL size=327, code size=781]
  58: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch() [FullOpts, IL size=42, code size=60]
  59: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:ComputeNewSafeToReclaimEpoch(long) [FullOpts, IL size=66, code size=51]
  60: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long) [FullOpts, IL size=191, code size=181]
  61: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2+<>c__DisplayClass32_0[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:<Run>b__0() [FullOpts, IL size=18, code size=17]
  62: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Quarantine(long) [FullOpts, IL size=51, code size=33]
Completed 1 rounds in 0.0s with NO violation. sampledRounds=0 drains=1 quarantined=1 sink=0
```

## jit-acquire-cas
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:TryAcquireEntry(byref,long):bool:this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
 
G_M000_IG02:                ;; offset=0x0001
       mov      rax, qword ptr GS:[0x0058]
       mov      r10, qword ptr [rax+0x50]
       add      r10, 640
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002E
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       G_M000_IG13
 
G_M000_IG04:                ;; offset=0x0041
       movzx    rax, word  ptr [r10+0x14]
       movzx    r9, word  ptr [r10+0x16]
       mov      word  ptr [r10+0x14], r9w
       mov      word  ptr [r10+0x16], ax
       mov      dword ptr [rdx], r9d
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG05
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG05:                ;; offset=0x0079
       mov      r9d, 256
       align    [1 bytes for IG06]
 
G_M000_IG06:                ;; offset=0x0080
       inc      word  ptr [r10+0x14]
       movzx    rax, word  ptr [r10+0x14]
       cmp      eax, 128
       jle      SHORT G_M000_IG08
 
G_M000_IG07:                ;; offset=0x0091
       add      eax, -128
       mov      word  ptr [r10+0x14], ax
 
G_M000_IG08:                ;; offset=0x0099
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r11, qword ptr [rcx+0x28]
       movsxd   rbx, dword ptr [rdx]
       shl      rbx, 6
       cmp      qword ptr [r11+rbx], 0
       jne      SHORT G_M000_IG10
 
G_M000_IG09:                ;; offset=0x00B2
       add      r11, rbx
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r11], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG10:                ;; offset=0x00C1
       dec      r9d
       jne      SHORT G_M000_IG06
 
G_M000_IG11:                ;; offset=0x00C6
       xor      eax, eax
       mov      dword ptr [rdx], eax
 
G_M000_IG12:                ;; offset=0x00CA
       pop      rbx
       ret      
 
G_M000_IG13:                ;; offset=0x00CC
       mov      rax, qword ptr [rcx+0x28]
       movsxd   rcx, dword ptr [rdx]
       shl      rcx, 6
       mov      edx, dword ptr [r10+0x10]
       mov      dword ptr [rax+rcx+0x08], edx
       mov      eax, 1
 
G_M000_IG14:                ;; offset=0x00E4
       pop      rbx
       ret      
 
; Total bytes of code 230

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-acquire-fence
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:TryAcquireEntry(byref,long):bool:this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
 
G_M000_IG02:                ;; offset=0x0001
       mov      rax, qword ptr GS:[0x0058]
       mov      r10, qword ptr [rax+0x50]
       add      r10, 640
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002E
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       G_M000_IG15
 
G_M000_IG04:                ;; offset=0x0041
       movzx    rax, word  ptr [r10+0x14]
       movzx    r9, word  ptr [r10+0x16]
       mov      word  ptr [r10+0x14], r9w
       mov      word  ptr [r10+0x16], ax
       mov      dword ptr [rdx], r9d
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG05
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       SHORT G_M000_IG14
 
G_M000_IG05:                ;; offset=0x0079
       mov      r9d, 256
       align    [1 bytes for IG06]
 
G_M000_IG06:                ;; offset=0x0080
       inc      word  ptr [r10+0x14]
       movzx    rax, word  ptr [r10+0x14]
       cmp      eax, 128
       jle      SHORT G_M000_IG08
 
G_M000_IG07:                ;; offset=0x0091
       add      eax, -128
       mov      word  ptr [r10+0x14], ax
 
G_M000_IG08:                ;; offset=0x0099
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r11, qword ptr [rcx+0x28]
       movsxd   rbx, dword ptr [rdx]
       shl      rbx, 6
       cmp      qword ptr [r11+rbx], 0
       jne      SHORT G_M000_IG10
 
G_M000_IG09:                ;; offset=0x00B2
       add      r11, rbx
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r11], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG10:                ;; offset=0x00C1
       dec      r9d
       jne      SHORT G_M000_IG06
 
G_M000_IG11:                ;; offset=0x00C6
       xor      eax, eax
       mov      dword ptr [rdx], eax
 
G_M000_IG12:                ;; offset=0x00CA
       pop      rbx
       ret      
 
G_M000_IG13:                ;; offset=0x00CC
       lock     
       or       dword ptr [rsp], 0
       jmp      SHORT G_M000_IG16
 
G_M000_IG14:                ;; offset=0x00D3
       lock     
       or       dword ptr [rsp], 0
       jmp      SHORT G_M000_IG16
 
G_M000_IG15:                ;; offset=0x00DA
       lock     
       or       dword ptr [rsp], 0
 
G_M000_IG16:                ;; offset=0x00DF
       mov      rax, qword ptr [rcx+0x28]
       movsxd   rcx, dword ptr [rdx]
       shl      rcx, 6
       mov      edx, dword ptr [r10+0x10]
       mov      dword ptr [rax+rcx+0x08], edx
       mov      eax, 1
 
G_M000_IG17:                ;; offset=0x00F7
       pop      rbx
       ret      
 
; Total bytes of code 249

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-acquire2-cas
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:TryAcquireEntry(byref,long):bool:this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
 
G_M000_IG02:                ;; offset=0x0001
       mov      rax, qword ptr GS:[0x0058]
       mov      r10, qword ptr [rax+0x50]
       add      r10, 640
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002E
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       G_M000_IG13
 
G_M000_IG04:                ;; offset=0x0041
       movzx    rax, word  ptr [r10+0x14]
       movzx    r9, word  ptr [r10+0x16]
       mov      word  ptr [r10+0x14], r9w
       mov      word  ptr [r10+0x16], ax
       mov      dword ptr [rdx], r9d
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG05
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG05:                ;; offset=0x0079
       mov      r9d, 256
       align    [1 bytes for IG06]
 
G_M000_IG06:                ;; offset=0x0080
       inc      word  ptr [r10+0x14]
       movzx    rax, word  ptr [r10+0x14]
       cmp      eax, 128
       jle      SHORT G_M000_IG08
 
G_M000_IG07:                ;; offset=0x0091
       add      eax, -128
       mov      word  ptr [r10+0x14], ax
 
G_M000_IG08:                ;; offset=0x0099
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r11, qword ptr [rcx+0x28]
       movsxd   rbx, dword ptr [rdx]
       shl      rbx, 6
       cmp      qword ptr [r11+rbx], 0
       jne      SHORT G_M000_IG10
 
G_M000_IG09:                ;; offset=0x00B2
       add      r11, rbx
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r11], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG10:                ;; offset=0x00C1
       dec      r9d
       jne      SHORT G_M000_IG06
 
G_M000_IG11:                ;; offset=0x00C6
       xor      eax, eax
       mov      dword ptr [rdx], eax
 
G_M000_IG12:                ;; offset=0x00CA
       pop      rbx
       ret      
 
G_M000_IG13:                ;; offset=0x00CC
       mov      rax, qword ptr [rcx+0x28]
       movsxd   rcx, dword ptr [rdx]
       shl      rcx, 6
       mov      edx, dword ptr [r10+0x10]
       mov      dword ptr [rax+rcx+0x08], edx
       mov      eax, 1
 
G_M000_IG14:                ;; offset=0x00E4
       pop      rbx
       ret      
 
; Total bytes of code 230

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-acquire2-fence
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:TryAcquireEntry(byref,long):bool:this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
 
G_M000_IG02:                ;; offset=0x0001
       mov      rax, qword ptr GS:[0x0058]
       mov      r10, qword ptr [rax+0x50]
       add      r10, 640
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002E
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       G_M000_IG15
 
G_M000_IG04:                ;; offset=0x0041
       movzx    rax, word  ptr [r10+0x14]
       movzx    r9, word  ptr [r10+0x16]
       mov      word  ptr [r10+0x14], r9w
       mov      word  ptr [r10+0x16], ax
       mov      dword ptr [rdx], r9d
       mov      r9, qword ptr [rcx+0x28]
       movsxd   r11, dword ptr [rdx]
       shl      r11, 6
       cmp      qword ptr [r9+r11], 0
       jne      SHORT G_M000_IG05
       add      r9, r11
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r9], r8
       test     rax, rax
       je       SHORT G_M000_IG14
 
G_M000_IG05:                ;; offset=0x0079
       mov      r9d, 256
       align    [1 bytes for IG06]
 
G_M000_IG06:                ;; offset=0x0080
       inc      word  ptr [r10+0x14]
       movzx    rax, word  ptr [r10+0x14]
       cmp      eax, 128
       jle      SHORT G_M000_IG08
 
G_M000_IG07:                ;; offset=0x0091
       add      eax, -128
       mov      word  ptr [r10+0x14], ax
 
G_M000_IG08:                ;; offset=0x0099
       movzx    rax, word  ptr [r10+0x14]
       mov      dword ptr [rdx], eax
       mov      r11, qword ptr [rcx+0x28]
       movsxd   rbx, dword ptr [rdx]
       shl      rbx, 6
       cmp      qword ptr [r11+rbx], 0
       jne      SHORT G_M000_IG10
 
G_M000_IG09:                ;; offset=0x00B2
       add      r11, rbx
       xor      eax, eax
       lock     
       cmpxchg  qword ptr [r11], r8
       test     rax, rax
       je       SHORT G_M000_IG13
 
G_M000_IG10:                ;; offset=0x00C1
       dec      r9d
       jne      SHORT G_M000_IG06
 
G_M000_IG11:                ;; offset=0x00C6
       xor      eax, eax
       mov      dword ptr [rdx], eax
 
G_M000_IG12:                ;; offset=0x00CA
       pop      rbx
       ret      
 
G_M000_IG13:                ;; offset=0x00CC
       lock     
       or       dword ptr [rsp], 0
       jmp      SHORT G_M000_IG16
 
G_M000_IG14:                ;; offset=0x00D3
       lock     
       or       dword ptr [rsp], 0
       jmp      SHORT G_M000_IG16
 
G_M000_IG15:                ;; offset=0x00DA
       lock     
       or       dword ptr [rsp], 0
 
G_M000_IG16:                ;; offset=0x00DF
       mov      rax, qword ptr [rcx+0x28]
       movsxd   rcx, dword ptr [rdx]
       shl      rcx, 6
       mov      edx, dword ptr [r10+0x10]
       mov      dword ptr [rax+rcx+0x08], edx
       mov      eax, 1
 
G_M000_IG17:                ;; offset=0x00F7
       pop      rbx
       ret      
 
; Total bytes of code 249

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-baseline
```
Resume + Refresh repro  impl=baseline  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = baseline (LightEpoch, no fence)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-cas-acqload
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-cas-fence
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-cas-plain
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-cas-release
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core-fullbarrier
```
Resume + Refresh repro  impl=fullbarrier  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = full-barrier (FixedLightEpochWithMemoryBarrier)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-baseline
```
Resume + Refresh repro  impl=baseline  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = baseline (LightEpoch, no fence)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-cas-acqload
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-cas-fence
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-cas-plain
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-cas-release
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-core2-fullbarrier
```
Resume + Refresh repro  impl=fullbarrier  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = full-barrier (FixedLightEpochWithMemoryBarrier)
Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-fence
```
   1: JIT compiled System.Guid:FormatGuidVector128Utf8(System.Guid,bool) [FullOpts with Synthesized PGO, IL size=304, code size=152]
   2: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:CreateAndCache(System.RuntimeType) [FullOpts with Synthesized PGO, IL size=165, code size=399]
   3: JIT compiled System.Buffers.SearchValues:TryGetSingleRange[char](System.ReadOnlySpan`1[char],byref,byref) [FullOpts, IL size=294, code size=386]
   4: JIT compiled System.Buffers.AsciiCharSearchValues`2[System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst]:IndexOfAny(System.ReadOnlySpan`1[char]) [FullOpts, IL size=30, code size=21]
   5: JIT compiled System.Buffers.IndexOfAnyAsciiSearcher:IndexOfAnyCore[int,System.Buffers.IndexOfAnyAsciiSearcher+DontNegate,System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst,System.Buffers.IndexOfAnyAsciiSearcher+IndexOfAnyResultMapper`1[short]](byref,int,byref) [FullOpts with Synthesized PGO, IL size=572, code size=491]
   6: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
   7: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   8: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   9: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  10: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
  11: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  12: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  13: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  14: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  15: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=26, code size=37]
  16: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  17: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  18: JIT compiled System.Threading.Thread:GetThreadStaticsBase() [FullOpts, IL size=18, code size=24]
  19: JIT compiled LightEpoch.Repro.Program:Main(System.String[]) [FullOpts, IL size=7, code size=16]
  20: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run(System.String[]) [FullOpts, IL size=180, code size=610]
  21: JIT compiled LightEpoch.Repro.Common.ReproRunner:Guarded(System.Func`1[int]) [FullOpts, IL size=32, code size=100]
  22: JIT compiled LightEpoch.Repro.Common.ReproRunner+<>c__DisplayClass0_0:<Run>b__1() [FullOpts, IL size=17, code size=29]
  23: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String[]) [FullOpts, IL size=1930, code size=6826]
  24: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryReadLong(System.String[],byref,byref) [FullOpts, IL size=25, code size=129]
  25: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryRead(System.String[],byref,byref) [FullOpts, IL size=29, code size=65]
  26: JIT compiled LightEpoch.Repro.Common.CoreTopology:Enumerate() [FullOpts, IL size=19, code size=6]
  27: JIT compiled LightEpoch.Repro.Common.CoreTopology:EnumerateWindows() [FullOpts, IL size=325, code size=943]
  28: JIT compiled LightEpoch.Repro.Common.CoreTopology:NumaNodesByLogicalProcessor() [FullOpts, IL size=220, code size=498]
  29: JIT compiled (dynamicClass):IL_STUB_PInvoke(int,nint,byref) [FullOpts, IL size=68, code size=186]
  30: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:.cctor() [FullOpts, IL size=12, code size=45]
  31: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:AddWithResize(LightEpoch.Repro.Common.CoreTopology+PhysicalCore) [FullOpts, IL size=39, code size=124]
  32: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:set_Capacity(int) [FullOpts, IL size=86, code size=124]
Resume + Refresh repro  impl=casannounce  rounds=1  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
  33: JIT compiled System.Runtime.CompilerServices.DefaultInterpolatedStringHandler:AppendFormatted[int](int) [FullOpts, IL size=257, code size=183]
  34: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:Replace(System.RuntimeType,System.__Canon) [FullOpts with Synthesized PGO, IL size=152, code size=336]
  35: JIT compiled LightEpoch.Repro.Common.CoreTopology:Describe() [FullOpts, IL size=202, code size=843]
  36: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:System.Collections.Generic.IEnumerable<T>.GetEnumerator() [FullOpts, IL size=30, code size=160]
  37: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:MoveNext() [FullOpts, IL size=105, code size=126]
  38: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Current() [FullOpts, IL size=7, code size=21]
  39: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:Dispose() [FullOpts, IL size=1, code size=1]
  40: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Count() [FullOpts, IL size=7, code size=4]
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
  41: JIT compiled LightEpoch.Repro.Common.ReproRunner:WarnIfSamePhysicalCore(System.Collections.Generic.IReadOnlyList`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore],int,int) [FullOpts, IL size=155, code size=769]
pair 0: cores(reclaimer=0,reader=2)
  42: JIT compiled LightEpoch.Repro.Common.ReproRunner:RunSingle[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String,long,int,int,int,bool,bool,int,bool,int[]) [FullOpts, IL size=251, code size=953]
  43: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:.ctor(long,int,int,int,bool,int,bool,int[]) [FullOpts, IL size=159, code size=257]
  44: JIT compiled System.Activator:CreateInstance[LightEpoch.Core.CasAnnounceOps]() [FullOpts, IL size=67, code size=83]
  45: JIT compiled LightEpoch.Core.CasAnnounceOps:.ctor() [FullOpts, IL size=12, code size=55]
  46: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.ctor() [FullOpts, IL size=173, code size=447]
  47: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:SelectInstance() [FullOpts, IL size=111, code size=437]
  48: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.cctor() [FullOpts, IL size=96, code size=236]
  49: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Run() [FullOpts, IL size=856, code size=4154]
ops = cas-announce (FixedLightEpochWithCasAnnounce)
  50: JIT compiled LightEpoch.Repro.Common.PlatformNative:Alloc(nuint) [FullOpts, IL size=92, code size=138]
  51: JIT compiled LightEpoch.Repro.Common.PlatformNative:.cctor() [FullOpts, IL size=26, code size=1]
  52: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint,uint,uint) [FullOpts, IL size=71, code size=181]
  53: JIT compiled LightEpoch.Repro.Common.PlatformNative:Pin(int) [FullOpts, IL size=299, code size=640]
  54: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint) [FullOpts, IL size=51, code size=164]
  55: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReaderLoop() [FullOpts, IL size=100, code size=1658]
  56: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReclaimerLoop() [FullOpts, IL size=247, code size=1757]
  57: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch(System.Action) [FullOpts, IL size=327, code size=791]
  58: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch() [FullOpts, IL size=42, code size=60]
  59: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:ComputeNewSafeToReclaimEpoch(long) [FullOpts, IL size=66, code size=51]
  60: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long) [FullOpts, IL size=191, code size=181]
  61: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2+<>c__DisplayClass32_0[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:<Run>b__0() [FullOpts, IL size=18, code size=17]
  62: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Quarantine(long) [FullOpts, IL size=51, code size=33]
Completed 1 rounds in 0.0s with NO violation. sampledRounds=0 drains=1 quarantined=1 sink=0
```

## jit-plain
```
   1: JIT compiled System.Guid:FormatGuidVector128Utf8(System.Guid,bool) [FullOpts with Synthesized PGO, IL size=304, code size=152]
   2: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:CreateAndCache(System.RuntimeType) [FullOpts with Synthesized PGO, IL size=165, code size=399]
   3: JIT compiled System.Buffers.SearchValues:TryGetSingleRange[char](System.ReadOnlySpan`1[char],byref,byref) [FullOpts, IL size=294, code size=386]
   4: JIT compiled System.Buffers.AsciiCharSearchValues`2[System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst]:IndexOfAny(System.ReadOnlySpan`1[char]) [FullOpts, IL size=30, code size=21]
   5: JIT compiled System.Buffers.IndexOfAnyAsciiSearcher:IndexOfAnyCore[int,System.Buffers.IndexOfAnyAsciiSearcher+DontNegate,System.Buffers.IndexOfAnyAsciiSearcher+Default,System.Buffers.SearchValues+FalseConst,System.Buffers.IndexOfAnyAsciiSearcher+IndexOfAnyResultMapper`1[short]](byref,int,byref) [FullOpts with Synthesized PGO, IL size=572, code size=491]
   6: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
   7: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   8: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
   9: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Level(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  10: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=28]
  11: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  12: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Object,ptr) [FullOpts, IL size=25, code size=27]
  13: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Version(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  14: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Keywords(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=41]
  15: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Message(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=26, code size=37]
  16: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Task(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  17: JIT compiled (dynamicClass):InvokeStub_EventAttribute.set_Opcode(System.Object,System.Span`1[System.Object]) [FullOpts, IL size=36, code size=40]
  18: JIT compiled System.Threading.Thread:GetThreadStaticsBase() [FullOpts, IL size=18, code size=24]
  19: JIT compiled LightEpoch.Repro.Program:Main(System.String[]) [FullOpts, IL size=7, code size=16]
  20: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run(System.String[]) [FullOpts, IL size=180, code size=610]
  21: JIT compiled LightEpoch.Repro.Common.ReproRunner:Guarded(System.Func`1[int]) [FullOpts, IL size=32, code size=100]
  22: JIT compiled LightEpoch.Repro.Common.ReproRunner+<>c__DisplayClass0_0:<Run>b__1() [FullOpts, IL size=17, code size=29]
  23: JIT compiled LightEpoch.Repro.Common.ReproRunner:Run[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String[]) [FullOpts, IL size=1930, code size=6826]
  24: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryReadLong(System.String[],byref,byref) [FullOpts, IL size=25, code size=129]
  25: JIT compiled LightEpoch.Repro.Common.ReproRunner:TryRead(System.String[],byref,byref) [FullOpts, IL size=29, code size=65]
  26: JIT compiled LightEpoch.Repro.Common.CoreTopology:Enumerate() [FullOpts, IL size=19, code size=6]
  27: JIT compiled LightEpoch.Repro.Common.CoreTopology:EnumerateWindows() [FullOpts, IL size=325, code size=943]
  28: JIT compiled LightEpoch.Repro.Common.CoreTopology:NumaNodesByLogicalProcessor() [FullOpts, IL size=220, code size=498]
  29: JIT compiled (dynamicClass):IL_STUB_PInvoke(int,nint,byref) [FullOpts, IL size=68, code size=186]
  30: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:.cctor() [FullOpts, IL size=12, code size=45]
  31: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:AddWithResize(LightEpoch.Repro.Common.CoreTopology+PhysicalCore) [FullOpts, IL size=39, code size=124]
  32: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:set_Capacity(int) [FullOpts, IL size=86, code size=124]
Resume + Refresh repro  impl=casannounce  rounds=1  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
  33: JIT compiled System.Runtime.CompilerServices.DefaultInterpolatedStringHandler:AppendFormatted[int](int) [FullOpts, IL size=257, code size=183]
  34: JIT compiled System.RuntimeType+IGenericCacheEntry`1[System.__Canon]:Replace(System.RuntimeType,System.__Canon) [FullOpts with Synthesized PGO, IL size=152, code size=336]
  35: JIT compiled LightEpoch.Repro.Common.CoreTopology:Describe() [FullOpts, IL size=202, code size=843]
  36: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:System.Collections.Generic.IEnumerable<T>.GetEnumerator() [FullOpts, IL size=30, code size=160]
  37: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:MoveNext() [FullOpts, IL size=105, code size=126]
  38: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Current() [FullOpts, IL size=7, code size=21]
  39: JIT compiled System.Collections.Generic.List`1+Enumerator[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:Dispose() [FullOpts, IL size=1, code size=1]
  40: JIT compiled System.Collections.Generic.List`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore]:get_Count() [FullOpts, IL size=7, code size=4]
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
  41: JIT compiled LightEpoch.Repro.Common.ReproRunner:WarnIfSamePhysicalCore(System.Collections.Generic.IReadOnlyList`1[LightEpoch.Repro.Common.CoreTopology+PhysicalCore],int,int) [FullOpts, IL size=155, code size=769]
pair 0: cores(reclaimer=0,reader=2)
  42: JIT compiled LightEpoch.Repro.Common.ReproRunner:RunSingle[LightEpoch.Repro.Common.ResumeAndRefreshReproPattern](System.String,long,int,int,int,bool,bool,int,bool,int[]) [FullOpts, IL size=251, code size=953]
  43: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:.ctor(long,int,int,int,bool,int,bool,int[]) [FullOpts, IL size=159, code size=257]
  44: JIT compiled System.Activator:CreateInstance[LightEpoch.Core.CasAnnounceOps]() [FullOpts, IL size=67, code size=83]
  45: JIT compiled LightEpoch.Core.CasAnnounceOps:.ctor() [FullOpts, IL size=12, code size=55]
  46: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.ctor() [FullOpts, IL size=173, code size=447]
  47: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:SelectInstance() [FullOpts, IL size=111, code size=437]
  48: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:.cctor() [FullOpts, IL size=96, code size=236]
  49: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Run() [FullOpts, IL size=856, code size=4154]
ops = cas-announce (FixedLightEpochWithCasAnnounce)
  50: JIT compiled LightEpoch.Repro.Common.PlatformNative:Alloc(nuint) [FullOpts, IL size=92, code size=138]
  51: JIT compiled LightEpoch.Repro.Common.PlatformNative:.cctor() [FullOpts, IL size=26, code size=1]
  52: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint,uint,uint) [FullOpts, IL size=71, code size=181]
  53: JIT compiled LightEpoch.Repro.Common.PlatformNative:Pin(int) [FullOpts, IL size=299, code size=640]
  54: JIT compiled (dynamicClass):IL_STUB_PInvoke(nint,nuint) [FullOpts, IL size=51, code size=164]
  55: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReaderLoop() [FullOpts, IL size=100, code size=1658]
  56: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:ReclaimerLoop() [FullOpts, IL size=247, code size=1757]
  57: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch(System.Action) [FullOpts, IL size=327, code size=781]
  58: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:BumpCurrentEpoch() [FullOpts, IL size=42, code size=60]
  59: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:ComputeNewSafeToReclaimEpoch(long) [FullOpts, IL size=66, code size=51]
  60: JIT compiled LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long) [FullOpts, IL size=191, code size=181]
  61: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2+<>c__DisplayClass32_0[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:<Run>b__0() [FullOpts, IL size=18, code size=17]
  62: JIT compiled LightEpoch.Repro.Common.QuarantineLitmus`2[LightEpoch.Core.CasAnnounceOps,LightEpoch.Repro.Common.ResumeAndRefreshReproPattern]:Quarantine(long) [FullOpts, IL size=51, code size=33]
Completed 1 rounds in 0.0s with NO violation. sampledRounds=0 drains=1 quarantined=1 sink=0
```

## jit-protect-acqload
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; partially interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
       sub      rsp, 32
       mov      rbx, rcx
 
G_M000_IG02:                ;; offset=0x0008
       mov      rcx, qword ptr GS:[0x0058]
       mov      rcx, qword ptr [rcx+0x50]
       cmp      dword ptr [rcx+0x238], 6
       jle      SHORT G_M000_IG09
       mov      rcx, gword ptr [rcx+0x240]
       mov      rax, bword ptr [rcx+0x30]
       test     rax, rax
       je       SHORT G_M000_IG09
 
G_M000_IG03:                ;; offset=0x002E
       mov      rcx, gword ptr [rax+0x10]
       add      rcx, 8
       mov      edx, dword ptr [rbx+0x48]
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce+InstanceIndexBuffer:GetRef(int):byref:this]
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      r8, qword ptr [rbx+0x30]
       mov      qword ptr [rdx+rcx], r8
       cmp      dword ptr [rbx+0x44], 0
       jle      SHORT G_M000_IG05
 
G_M000_IG04:                ;; offset=0x0058
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      rdx, qword ptr [rdx+rcx]
       mov      rcx, rbx
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long):this]
 
G_M000_IG05:                ;; offset=0x0070
       cmp      dword ptr [rbx+0x40], 0
       jg       SHORT G_M000_IG07
 
G_M000_IG06:                ;; offset=0x0076
       add      rsp, 32
       pop      rbx
       ret      
 
G_M000_IG07:                ;; offset=0x007C
       mov      rcx, rbx
 
G_M000_IG08:                ;; offset=0x007F
       add      rsp, 32
       pop      rbx
       tail.jmp [LightEpoch.Core.FixedLightEpochWithCasAnnounce:SuspendResume():this]
 
G_M000_IG09:                ;; offset=0x008A
       mov      ecx, 6
       call     CORINFO_HELP_GETDYNAMIC_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 150

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-protect-fence
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; partially interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
       sub      rsp, 32
       mov      rbx, rcx
 
G_M000_IG02:                ;; offset=0x0008
       mov      rcx, qword ptr GS:[0x0058]
       mov      rcx, qword ptr [rcx+0x50]
       cmp      dword ptr [rcx+0x238], 6
       jle      SHORT G_M000_IG09
       mov      rcx, gword ptr [rcx+0x240]
       mov      rax, bword ptr [rcx+0x30]
       test     rax, rax
       je       SHORT G_M000_IG09
 
G_M000_IG03:                ;; offset=0x002E
       mov      rcx, gword ptr [rax+0x10]
       add      rcx, 8
       mov      edx, dword ptr [rbx+0x48]
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce+InstanceIndexBuffer:GetRef(int):byref:this]
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      r8, qword ptr [rbx+0x30]
       mov      qword ptr [rdx+rcx], r8
       lock     
       or       dword ptr [rsp], 0
       cmp      dword ptr [rbx+0x44], 0
       jle      SHORT G_M000_IG05
 
G_M000_IG04:                ;; offset=0x005D
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      rdx, qword ptr [rdx+rcx]
       mov      rcx, rbx
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long):this]
 
G_M000_IG05:                ;; offset=0x0075
       cmp      dword ptr [rbx+0x40], 0
       jg       SHORT G_M000_IG07
 
G_M000_IG06:                ;; offset=0x007B
       add      rsp, 32
       pop      rbx
       ret      
 
G_M000_IG07:                ;; offset=0x0081
       mov      rcx, rbx
 
G_M000_IG08:                ;; offset=0x0084
       add      rsp, 32
       pop      rbx
       tail.jmp [LightEpoch.Core.FixedLightEpochWithCasAnnounce:SuspendResume():this]
 
G_M000_IG09:                ;; offset=0x008F
       mov      ecx, 6
       call     CORINFO_HELP_GETDYNAMIC_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 155

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-protect-plain
```
Resume + Refresh repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; partially interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rbx
       sub      rsp, 32
       mov      rbx, rcx
 
G_M000_IG02:                ;; offset=0x0008
       mov      rcx, qword ptr GS:[0x0058]
       mov      rcx, qword ptr [rcx+0x40]
       cmp      dword ptr [rcx+0x238], 6
       jle      SHORT G_M000_IG09
       mov      rcx, gword ptr [rcx+0x240]
       mov      rax, bword ptr [rcx+0x30]
       test     rax, rax
       je       SHORT G_M000_IG09
 
G_M000_IG03:                ;; offset=0x002E
       mov      rcx, gword ptr [rax+0x10]
       add      rcx, 8
       mov      edx, dword ptr [rbx+0x48]
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce+InstanceIndexBuffer:GetRef(int):byref:this]
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      r8, qword ptr [rbx+0x30]
       mov      qword ptr [rdx+rcx], r8
       cmp      dword ptr [rbx+0x44], 0
       jle      SHORT G_M000_IG05
 
G_M000_IG04:                ;; offset=0x0058
       mov      rdx, qword ptr [rbx+0x28]
       movsxd   rcx, dword ptr [rax]
       shl      rcx, 6
       mov      rdx, qword ptr [rdx+rcx]
       mov      rcx, rbx
       call     [LightEpoch.Core.FixedLightEpochWithCasAnnounce:Drain(long):this]
 
G_M000_IG05:                ;; offset=0x0070
       cmp      dword ptr [rbx+0x40], 0
       jg       SHORT G_M000_IG07
 
G_M000_IG06:                ;; offset=0x0076
       add      rsp, 32
       pop      rbx
       ret      
 
G_M000_IG07:                ;; offset=0x007C
       mov      rcx, rbx
 
G_M000_IG08:                ;; offset=0x007F
       add      rsp, 32
       pop      rbx
       tail.jmp [LightEpoch.Core.FixedLightEpochWithCasAnnounce:SuspendResume():this]
 
G_M000_IG09:                ;; offset=0x008A
       mov      ecx, 6
       call     CORINFO_HELP_GETDYNAMIC_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 150

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-reserve-cas
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:ReserveEntryForThread(byref,long):this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rdi
       push     rsi
       push     rbp
       push     rbx
       sub      rsp, 40
       mov      rbx, rcx
       mov      rsi, rdx
       mov      rdi, r8
 
G_M000_IG02:                ;; offset=0x0011
       mov      rax, qword ptr GS:[0x0058]
       mov      rbp, qword ptr [rax+0x50]
       add      rbp, 640
       cmp      dword ptr [rbp+0x10], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002B
       call     System.Environment:get_CurrentManagedThreadId():int
       mov      dword ptr [rbp+0x10], eax
 
G_M000_IG04:                ;; offset=0x0033
       cmp      word  ptr [rbp+0x14], 0
       je       SHORT G_M000_IG06
 
G_M000_IG05:                ;; offset=0x003A
       cmp      word  ptr [(reloc 0x7ff976bbb112)], 0
       je       SHORT G_M000_IG07
 
G_M000_IG06:                ;; offset=0x0044
       mov      ecx, dword ptr [rbp+0x10]
       call     [LightEpoch.Core.Utility:Murmur3(int):int]
       mov      ecx, eax
       movzx    rax, word  ptr [(reloc 0x7ff976bbb112)]
       mov      edx, 128
       test     eax, eax
       cmovne   edx, eax
       movzx    r8, dx
       mov      eax, ecx
       xor      edx, edx
       div      edx:eax, r8d
       inc      edx
       mov      word  ptr [rbp+0x14], dx
       mov      eax, ecx
       shr      eax, 16
       xor      edx, edx
       div      edx:eax, r8d
       inc      edx
       mov      word  ptr [rbp+0x16], dx
 
G_M000_IG07:                ;; offset=0x0081
       mov      rcx, rbx
       mov      rdx, rsi
       mov      r8, rdi
 
G_M000_IG08:                ;; offset=0x008A
       add      rsp, 40
       pop      rbx
       pop      rbp
       pop      rsi
       pop      rdi
       tail.jmp [LightEpoch.Core.FixedLightEpochWithCasAnnounce:ReserveEntry(byref,long):this]
 
; Total bytes of code 152

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

## jit-reserve-fence
```
bare LightEpoch repro  impl=casannounce  rounds=2  deref=1  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
; Assembly listing for method LightEpoch.Core.FixedLightEpochWithCasAnnounce:ReserveEntryForThread(byref,long):this (FullOpts)
; Emitting BLENDED_CODE for generic X64 + VEX on Windows
; FullOpts code
; optimized code
; rsp based frame
; fully interruptible
; No PGO data

G_M000_IG01:                ;; offset=0x0000
       push     rdi
       push     rsi
       push     rbp
       push     rbx
       sub      rsp, 40
       mov      rbx, rcx
       mov      rsi, rdx
       mov      rdi, r8
 
G_M000_IG02:                ;; offset=0x0011
       mov      rax, qword ptr GS:[0x0058]
       mov      rbp, qword ptr [rax+0x50]
       add      rbp, 640
       cmp      dword ptr [rbp+0x10], 0
       jne      SHORT G_M000_IG04
 
G_M000_IG03:                ;; offset=0x002B
       call     System.Environment:get_CurrentManagedThreadId():int
       mov      dword ptr [rbp+0x10], eax
 
G_M000_IG04:                ;; offset=0x0033
       cmp      word  ptr [rbp+0x14], 0
       je       SHORT G_M000_IG06
 
G_M000_IG05:                ;; offset=0x003A
       cmp      word  ptr [(reloc 0x7ff976bab112)], 0
       je       SHORT G_M000_IG07
 
G_M000_IG06:                ;; offset=0x0044
       mov      ecx, dword ptr [rbp+0x10]
       call     [LightEpoch.Core.Utility:Murmur3(int):int]
       mov      ecx, eax
       movzx    rax, word  ptr [(reloc 0x7ff976bab112)]
       mov      edx, 128
       test     eax, eax
       cmovne   edx, eax
       movzx    r8, dx
       mov      eax, ecx
       xor      edx, edx
       div      edx:eax, r8d
       inc      edx
       mov      word  ptr [rbp+0x14], dx
       mov      eax, ecx
       shr      eax, 16
       xor      edx, edx
       div      edx:eax, r8d
       inc      edx
       mov      word  ptr [rbp+0x16], dx
 
G_M000_IG07:                ;; offset=0x0081
       mov      rcx, rbx
       mov      rdx, rsi
       mov      r8, rdi
 
G_M000_IG08:                ;; offset=0x008A
       add      rsp, 40
       pop      rbx
       pop      rbp
       pop      rsi
       pop      rdi
       tail.jmp [LightEpoch.Core.FixedLightEpochWithCasAnnounce:ReserveEntry(byref,long):this]
 
; Total bytes of code 152

Completed 2 rounds in 0.0s with NO violation. sampledRounds=0 drains=2 quarantined=2 sink=0
```

