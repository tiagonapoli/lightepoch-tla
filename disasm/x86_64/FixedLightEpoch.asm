; Assembly listing for method Tsavorite.core.FixedLightEpoch:ProtectAndDrain():this (FullOpts)
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
       cmp      dword ptr [rax+0x10], 3
       jl       SHORT G_M000_IG09
       mov      rsi, qword ptr [rax+0x18]
       mov      rsi, qword ptr [rsi+0x18]
       test     rsi, rsi
       je       SHORT G_M000_IG09
       mov      rax, bword ptr [rsi]
       add      rax, 16
 
G_M000_IG03:
       mov      rsi, gword ptr [rax]
       movsxd   rdi, dword ptr [rbx+0x48]
       lea      rsi, bword ptr [rsi+4*rdi+0x08]
       mov      rdi, qword ptr [rbx+0x28]
       movsxd   rax, dword ptr [rsi]
       shl      rax, 6
       mov      rcx, qword ptr [rbx+0x30]
       mov      qword ptr [rdi+rax], rcx
       lock     
       or       dword ptr [rsp], 0
       cmp      dword ptr [rbx+0x44], 0
       jle      SHORT G_M000_IG05
 
G_M000_IG04:
       mov      rdi, qword ptr [rbx+0x28]
       movsxd   rsi, dword ptr [rsi]
       shl      rsi, 6
       mov      rsi, qword ptr [rdi+rsi]
       mov      rdi, rbx
       call     [Tsavorite.core.FixedLightEpoch:Drain(long):this]
 
G_M000_IG05:
       cmp      dword ptr [rbx+0x40], 0
       jle      SHORT G_M000_IG08
 
G_M000_IG06:
       mov      rdi, rbx
 
G_M000_IG07:
       add      rsp, 8
       pop      rbx
       pop      rbp
       tail.jmp [Tsavorite.core.FixedLightEpoch:SuspendResume():this]
 
G_M000_IG08:
       add      rsp, 8
       pop      rbx
       pop      rbp
       ret      
 
G_M000_IG09:
       mov      edi, 3
       call     CORINFO_HELP_GETSHARED_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 165

; Assembly listing for method Tsavorite.core.FixedLightEpoch:ComputeNewSafeToReclaimEpoch(long):long:this (FullOpts)
; Emitting BLENDED_CODE for X64 with AVX - Unix
; FullOpts code
; optimized code
; rbp based frame
; fully interruptible
; No PGO data

G_M000_IG01:
       push     rbp
       mov      rbp, rsp
 
G_M000_IG02:
       mov      eax, 1
       mov      rcx, qword ptr [rdi+0x28]
       align    [0 bytes for IG03]
 
G_M000_IG03:
       movsxd   rdx, eax
       shl      rdx, 6
       mov      rdx, qword ptr [rcx+rdx]
       test     rdx, rdx
       je       SHORT G_M000_IG05
 
G_M000_IG04:
       cmp      rdx, rsi
       jge      SHORT G_M000_IG05
       mov      rsi, rdx
 
G_M000_IG05:
       inc      eax
       cmp      eax, 128
       jle      SHORT G_M000_IG03
 
G_M000_IG06:
       dec      rsi
       mov      qword ptr [rdi+0x38], rsi
       mov      rax, qword ptr [rdi+0x38]
 
G_M000_IG07:
       pop      rbp
       ret      
 
; Total bytes of code 59

