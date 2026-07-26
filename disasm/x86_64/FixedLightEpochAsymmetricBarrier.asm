; Assembly listing for method Tsavorite.core.FixedLightEpochAsymmetricBarrier:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for X64 with AVX - Unix
; FullOpts code
; optimized code
; rbp based frame
; fully interruptible
; No PGO data
; 0 inlinees with PGO data; 1 single block inlinees; 0 inlinees without PGO data

G_M000_IG01:
       push     rbp
       push     rbx
       push     rax
       lea      rbp, [rsp+0x10]
       mov      rbx, rdi
 
G_M000_IG02:
       mov      rdi, 0xD1FFAB1E
       mov      rax, 0xD1FFAB1E
       call     rax
       cmp      dword ptr [rax+0x10], 5
       jl       SHORT G_M000_IG09
       mov      rsi, qword ptr [rax+0x18]
       mov      rsi, qword ptr [rsi+0x28]
       test     rsi, rsi
       je       SHORT G_M000_IG09
       mov      rax, bword ptr [rsi]
       add      rax, 16
 
G_M000_IG03:
       mov      rsi, gword ptr [rax+0x08]
       movsxd   rdi, dword ptr [rbx+0x48]
       lea      rsi, bword ptr [rsi+4*rdi+0x08]
       mov      rdi, qword ptr [rbx+0x28]
       movsxd   rax, dword ptr [rsi]
       shl      rax, 6
       mov      rcx, qword ptr [rbx+0x30]
       mov      qword ptr [rdi+rax], rcx
       cmp      dword ptr [rbx+0x44], 0
       jle      SHORT G_M000_IG05
 
G_M000_IG04:
       mov      rdi, qword ptr [rbx+0x28]
       movsxd   rsi, dword ptr [rsi]
       shl      rsi, 6
       mov      rsi, qword ptr [rdi+rsi]
       mov      rdi, rbx
       call     [Tsavorite.core.FixedLightEpochAsymmetricBarrier:Drain(long):this]
 
G_M000_IG05:
       cmp      dword ptr [rbx+0x40], 0
       jle      SHORT G_M000_IG08
 
G_M000_IG06:
       mov      rdi, rbx
 
G_M000_IG07:
       add      rsp, 8
       pop      rbx
       pop      rbp
       tail.jmp [Tsavorite.core.FixedLightEpochAsymmetricBarrier:SuspendResume():this]
 
G_M000_IG08:
       add      rsp, 8
       pop      rbx
       pop      rbp
       ret      
 
G_M000_IG09:
       mov      edi, 5
       call     CORINFO_HELP_GETSHARED_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 161

; Assembly listing for method Tsavorite.core.FixedLightEpochAsymmetricBarrier:ComputeNewSafeToReclaimEpoch(long):long:this (FullOpts)
; Emitting BLENDED_CODE for X64 with AVX - Unix
; FullOpts code
; optimized code
; rbp based frame
; fully interruptible
; No PGO data

G_M000_IG01:
       push     rbp
       push     r15
       push     rbx
       lea      rbp, [rsp+0x10]
       mov      rbx, rdi
       mov      r15, rsi
 
G_M000_IG02:
       call     [Tsavorite.core.AsymmetricBarrier:FullBarrierAllCores()]
       mov      eax, 1
       mov      rcx, qword ptr [rbx+0x28]
       align    [0 bytes for IG03]
 
G_M000_IG03:
       movsxd   rdx, eax
       shl      rdx, 6
       mov      rdx, qword ptr [rcx+rdx]
       test     rdx, rdx
       je       SHORT G_M000_IG05
 
G_M000_IG04:
       cmp      rdx, r15
       jge      SHORT G_M000_IG05
       mov      r15, rdx
 
G_M000_IG05:
       inc      eax
       cmp      eax, 128
       jle      SHORT G_M000_IG03
 
G_M000_IG06:
       dec      r15
       mov      qword ptr [rbx+0x38], r15
       mov      rax, qword ptr [rbx+0x38]
 
G_M000_IG07:
       pop      rbx
       pop      r15
       pop      rbp
       ret      
 
; Total bytes of code 79

