; Assembly listing for method Tsavorite.core.LightEpoch:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for X64 with AVX - Unix
; FullOpts code
; optimized code
; rbp based frame
; fully interruptible
; No PGO data
; 0 inlinees with PGO data; 1 single block inlinees; 0 inlinees without PGO data
;
; ---------------------------------------------------------------------------
; What this method implements
; ---------------------------------------------------------------------------
; C# source, reduced to the operations visible here:
;
;   entry = Metadata.Entries[instanceId]
;   tableAligned[entry].localCurrentEpoch = CurrentEpoch   // announce
;   if (drainCount > 0)
;       Drain(tableAligned[entry].localCurrentEpoch)
;   if (waiterCount > 0)
;       SuspendResume()
;
; System V AMD64 calling convention and object-field map:
;   rdi on entry = this (the LightEpoch object)
;   rbx          = this, preserved across helper/method calls
;   [rbx+0x28]   = tableAligned, pointer to the epoch-entry table
;   [rbx+0x30]   = CurrentEpoch
;   [rbx+0x40]   = waiterCount
;   [rbx+0x44]   = drainCount
;   [rbx+0x48]   = instanceId
;
; Each epoch-table Entry is 64 bytes (one cache line). Its first 8 bytes are
; localCurrentEpoch. A value of 0 means that the table entry is not currently
; protected; a positive value announces the oldest epoch that may still be in
; use by that thread.
;
; Correctness-critical ordering point:
;   The "mov [rdi+rax], rcx" in IG03 is the reader's epoch announcement.
;   There is no MFENCE or locked instruction between that store and the later
;   loads. x86-TSO permits a younger load to execute before an older store has
;   become globally visible (StoreLoad reordering). Thus the reclaimer may miss
;   this announcement while the reader has already begun loading protected
;   data. This file is the intentionally broken baseline.

G_M000_IG01:
       push     rbp                         ; Save the caller's frame pointer.
       push     rbx                         ; Save callee-saved rbx.
       push     rax                         ; Reserve/alignment slot for calls.
       lea      rbp, [rsp+0x10]             ; Establish this method's frame.
       mov      rbx, rdi                    ; Keep "this" in rbx across calls.
 
G_M000_IG02:
       ; Resolve the current thread's GC thread-static storage. The diffable
       ; disassembler replaces runtime-specific handles/addresses with the
       ; recognizable 0xD1FFAB1E marker; it is not an epoch value.
       mov      rdi, 0xD1FFAB1E             ; Thread-static type/module handle.
       mov      rax, 0xD1FFAB1E             ; Fast TLS lookup helper address.
       call     rax                         ; rax = current thread's TLS data.
       cmp      dword ptr [rax+0x10], 2     ; Is the fast TLS layout initialized?
       jl       SHORT G_M000_IG09           ; No: use the runtime slow helper.
       mov      rsi, qword ptr [rax+0x18]   ; Load the thread-static block map.
       mov      rsi, qword ptr [rsi+0x10]   ; Load this type's block.
       test     rsi, rsi                    ; Was the block allocated?
       je       SHORT G_M000_IG09           ; No: ask the runtime to allocate it.
       mov      rax, bword ptr [rsi]        ; Base of LightEpoch.Metadata TLS.
       add      rax, 16                     ; Advance to Metadata.Entries storage.
 
G_M000_IG03:
       ; Find Metadata.Entries[instanceId], which contains this thread's table
       ; index for this particular LightEpoch instance.
       mov      rsi, gword ptr [rax+0x18]   ; rsi = Metadata.Entries backing data.
       movsxd   rdi, dword ptr [rbx+0x48]   ; rdi = sign-extended instanceId.
       lea      rsi, bword ptr [rsi+4*rdi+0x08]
                                             ; rsi = &Entries[instanceId].
                                             ; Each stored index is a 4-byte int.
       mov      rdi, qword ptr [rbx+0x28]   ; rdi = tableAligned.
       movsxd   rax, dword ptr [rsi]        ; rax = this thread's table index.
       shl      rax, 6                      ; Byte offset = index * 64-byte Entry.
       mov      rcx, qword ptr [rbx+0x30]   ; rcx = CurrentEpoch.
       mov      qword ptr [rdi+rax], rcx    ; ANNOUNCE: entry.localCurrentEpoch
                                             ;           = CurrentEpoch.
                                             ; Plain store: NO StoreLoad fence.
       cmp      dword ptr [rbx+0x44], 0     ; Volatile-read drainCount.
                                             ; This load may pass the announce
                                             ; while it is still buffered.
       jle      SHORT G_M000_IG05           ; No pending callbacks: skip Drain.
 
G_M000_IG04:
       ; A drain is pending. Reload the epoch just announced and pass it to
       ; Drain(nextEpoch). Drain scans all entries, advances SafeToReclaimEpoch,
       ; and invokes callbacks whose epochs are now safe.
       mov      rdi, qword ptr [rbx+0x28]   ; rdi = tableAligned.
       movsxd   rsi, dword ptr [rsi]        ; rsi = this thread's table index.
       shl      rsi, 6                      ; rsi = byte offset of its Entry.
       mov      rsi, qword ptr [rdi+rsi]    ; rsi = announced localCurrentEpoch;
                                             ; second argument to Drain.
       mov      rdi, rbx                    ; rdi = this; first argument.
       call     [Tsavorite.core.LightEpoch:Drain(long):this]
 
G_M000_IG05:
       cmp      dword ptr [rbx+0x40], 0     ; Volatile-read waiterCount.
       jle      SHORT G_M000_IG08           ; No waiters: return normally.
 
G_M000_IG06:
       mov      rdi, rbx                    ; rdi = this for SuspendResume().
 
G_M000_IG07:
       add      rsp, 8                      ; Tear down frame before tail call.
       pop      rbx
       pop      rbp
       tail.jmp [Tsavorite.core.LightEpoch:SuspendResume():this]
                                             ; Fairness slow path: temporarily
                                             ; unprotect, then protect again.
 
G_M000_IG08:
       add      rsp, 8                      ; Tear down frame.
       pop      rbx
       pop      rbp
       ret      
 
G_M000_IG09:
       ; Slow TLS path. The helper returns the same Metadata storage base that
       ; the fast path placed in rax, then execution rejoins at IG03.
       mov      edi, 2                      ; Runtime ID for the TLS base.
       call     CORINFO_HELP_GETSHARED_GCTHREADSTATIC_BASE_NOCTOR_OPTIMIZED
       jmp      SHORT G_M000_IG03
 
; Total bytes of code 161

; Assembly listing for method Tsavorite.core.LightEpoch:ComputeNewSafeToReclaimEpoch(long):long:this (FullOpts)
; Emitting BLENDED_CODE for X64 with AVX - Unix
; FullOpts code
; optimized code
; rbp based frame
; fully interruptible
; No PGO data
;
; ---------------------------------------------------------------------------
; What this method implements
; ---------------------------------------------------------------------------
; Input:
;   rdi = this
;   rsi = currentEpoch, also the initial oldestOngoingCall
;
; Pseudocode:
;
;   oldestOngoingCall = currentEpoch
;   for index = 1 through 128:
;       entryEpoch = tableAligned[index].localCurrentEpoch
;       if entryEpoch != 0 and entryEpoch < oldestOngoingCall:
;           oldestOngoingCall = entryEpoch
;   SafeToReclaimEpoch = oldestOngoingCall - 1
;   return SafeToReclaimEpoch
;
; Why subtract one:
;   An active reader that announced epoch E may still access objects retired in
;   E, so only epochs strictly less than E are reclaimable. If no active entry
;   is older than currentEpoch, currentEpoch - 1 is safe.
;
; Important limitation:
;   The loads in this scan are ordinary loads. They can only observe an announce
;   after that announce becomes globally visible. Because baseline
;   ProtectAndDrain has no StoreLoad fence, a reader may already load protected
;   data while this scan still sees 0 or an older table value.

G_M000_IG01:
       push     rbp                         ; Standard frame prologue.
       mov      rbp, rsp
 
G_M000_IG02:
       mov      eax, 1                      ; index = 1 (slot 0 is not scanned).
       mov      rcx, qword ptr [rdi+0x28]   ; rcx = tableAligned.
       align    [0 bytes for IG03]
 
G_M000_IG03:
       movsxd   rdx, eax                    ; rdx = sign-extended index.
       shl      rdx, 6                      ; rdx = index * 64-byte Entry.
       mov      rdx, qword ptr [rcx+rdx]    ; rdx = entry.localCurrentEpoch.
       test     rdx, rdx                    ; Is this thread protected?
       je       SHORT G_M000_IG05           ; 0 means inactive; ignore the slot.
 
G_M000_IG04:
       cmp      rdx, rsi                    ; Compare entryEpoch with oldest.
       jge      SHORT G_M000_IG05           ; Keep oldest if entry is newer/equal.
       mov      rsi, rdx                    ; oldestOngoingCall = entryEpoch.
 
G_M000_IG05:
       inc      eax                         ; ++index.
       cmp      eax, 128                    ; Scan slots 1 through kTableSize.
       jle      SHORT G_M000_IG03
 
G_M000_IG06:
       dec      rsi                         ; Safe epoch = oldest active - 1.
       mov      qword ptr [rdi+0x38], rsi   ; Save SafeToReclaimEpoch.
       mov      rax, qword ptr [rdi+0x38]   ; Return it in rax.
 
G_M000_IG07:
       pop      rbp                         ; Standard frame epilogue.
       ret      
 
; Total bytes of code 59
