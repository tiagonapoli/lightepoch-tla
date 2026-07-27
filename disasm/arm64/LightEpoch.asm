; Assembly listing for method Tsavorite.core.LightEpoch:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for generic ARM64 - Unix
; FullOpts code
; optimized code
; fp based frame
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
; AArch64 calling convention and object-field map:
;   x0 on entry  = this (the LightEpoch object)
;   x19          = this, preserved across helper/method calls
;   [x19+0x28]   = tableAligned, pointer to the epoch-entry table
;   [x19+0x30]   = CurrentEpoch
;   [x19+0x40]   = waiterCount
;   [x19+0x44]   = drainCount
;   [x19+0x48]   = instanceId
;
; Each epoch-table Entry is 64 bytes (one cache line). Its first 8 bytes are
; localCurrentEpoch. A value of 0 means that the table entry is not currently
; protected; a positive value announces the oldest epoch that may still be in
; use by that thread.
;
; Correctness-critical ordering point:
;   The "str x2, [x0]" in IG02 is the reader's epoch announcement. It is a plain
;   store. There is no DMB ISH between it and the following loads. AArch64 may
;   therefore issue a later protected-data load before this announcement is
;   visible to the reclaimer. LDAPR below is an acquire load, but acquire orders
;   operations after that load; it does not turn the preceding STR into a
;   StoreLoad barrier. This file is the intentionally broken baseline.

G_M000_IG01:
            stp     fp, lr, [sp, #-0x20]!   ; Allocate frame; save fp and return address.
            str     x19, [sp, #0x18]        ; Save callee-saved x19.
            mov     fp, sp                  ; Establish this method's frame.
            mov     x19, x0                 ; Keep "this" in x19 across calls.
 
G_M000_IG02:
            ; Resolve the current thread's GC thread-static Metadata storage.
            ; The diffable disassembler substitutes 0xD1FFAB1E for a
            ; runtime-specific handle; it is not an epoch value.
            movz    x0, #0xD1FFAB1E         ; Begin materializing TLS handle.
            movk    x0, #0xD1FFAB1E LSL #16
            movk    x0, #0xD1FFAB1E LSL #32 ; x0 = thread-static handle.
            mov     w1, #26                 ; Runtime thread-static type ID.
            bl      CORINFO_HELP_GETSHARED_GCTHREADSTATIC_BASE_NOCTOR
                                             ; x0 = current thread's Metadata base.
            ldr     x1, [x0, #0x18]         ; x1 = Metadata.Entries backing data.
            add     x1, x1, #8              ; Advance to first stored int index.
            ldr     w0, [x19, #0x48]        ; w0 = instanceId.
            sbfiz   x0, x0, #2, #32         ; x0 = instanceId * 4 bytes.
            add     x1, x1, x0              ; x1 = &Entries[instanceId].
            ldr     x0, [x19, #0x28]        ; x0 = tableAligned.
            ldr     w2, [x1]                ; w2 = this thread's table index.
            sbfiz   x2, x2, #6, #32         ; x2 = index * 64-byte Entry.
            add     x0, x0, x2              ; x0 = &tableAligned[index].
            ldr     x2, [x19, #0x30]        ; x2 = CurrentEpoch.
            str     x2, [x0]                ; ANNOUNCE: entry.localCurrentEpoch
                                             ;           = CurrentEpoch.
                                             ; Plain STR: NO StoreLoad fence.
            add     x0, x19, #68            ; x0 = &drainCount (offset 0x44).
            ldapr   w0, [x0]                ; Acquire-read volatile drainCount.
                                             ; Acquire does not order the older
                                             ; announce store before this load.
            cmp     w0, #0                  ; Are callbacks pending?
            ble     G_M000_IG04             ; No: skip Drain.
 
G_M000_IG03:
            ; A drain is pending. Reload the epoch just announced and pass it to
            ; Drain(nextEpoch). Drain scans all entries, advances
            ; SafeToReclaimEpoch, and invokes callbacks whose epochs are safe.
            ldr     x0, [x19, #0x28]        ; x0 = tableAligned.
            ldr     w1, [x1]                ; w1 = this thread's table index.
            sbfiz   x1, x1, #6, #32         ; x1 = index * 64-byte Entry.
            ldr     x1, [x0, x1]            ; x1 = announced localCurrentEpoch;
                                             ; second argument to Drain.
            mov     x0, x19                 ; x0 = this; first argument.
            movz    x2, #0xD1FFAB1E         ; Begin loading method target cell.
            movk    x2, #0xD1FFAB1E LSL #16
            movk    x2, #0xD1FFAB1E LSL #32
            ldr     x2, [x2]                ; x2 = address of Drain.
            blr     x2                      ; Call Drain(this, nextEpoch).
 
G_M000_IG04:
            add     x0, x19, #64            ; x0 = &waiterCount (offset 0x40).
            ldapr   w0, [x0]                ; Acquire-read volatile waiterCount.
            cmp     w0, #0                  ; Is another thread waiting?
            ble     G_M000_IG07             ; No: return normally.
 
G_M000_IG05:
            mov     x0, x19                 ; x0 = this for SuspendResume().
            movz    x1, #0xD1FFAB1E         ; Begin loading method target cell.
            movk    x1, #0xD1FFAB1E LSL #16
            movk    x1, #0xD1FFAB1E LSL #32
            ldr     x1, [x1]                ; x1 = address of SuspendResume.
 
G_M000_IG06:
            ldr     x19, [sp, #0x18]        ; Restore x19.
            ldp     fp, lr, [sp], #0x20     ; Tear down frame.
            br      x1                      ; Tail-call SuspendResume: briefly
                                             ; unprotect, then protect again.
 
G_M000_IG07:
            ldr     x19, [sp, #0x18]        ; Restore x19.
            ldp     fp, lr, [sp], #0x20     ; Tear down frame.
            ret     lr                      ; Return to caller.
 
; Total bytes of code 196

; Assembly listing for method Tsavorite.core.LightEpoch:ComputeNewSafeToReclaimEpoch(long):long:this (FullOpts)
; Emitting BLENDED_CODE for generic ARM64 - Unix
; FullOpts code
; optimized code
; fp based frame
; fully interruptible
; No PGO data
;
; ---------------------------------------------------------------------------
; What this method implements
; ---------------------------------------------------------------------------
; Input:
;   x0 = this
;   x1 = currentEpoch, also the initial oldestOngoingCall
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
;   The LDR instructions in this scan are ordinary loads. They can only observe
;   an announce after that announce becomes visible. Because baseline
;   ProtectAndDrain has no StoreLoad fence, a reader may already load protected
;   data while this scan still sees 0 or an older table value.

G_M000_IG01:
            stp     fp, lr, [sp, #-0x10]!   ; Allocate frame; save fp and lr.
            mov     fp, sp                  ; Establish this method's frame.
 
G_M000_IG02:
            mov     w2, #1                  ; index = 1 (slot 0 is not scanned).
            ldr     x3, [x0, #0x28]         ; x3 = tableAligned.
            align   [0 bytes for IG03]
            align   [0 bytes]
            align   [0 bytes]
            align   [0 bytes]
 
G_M000_IG03:
            sbfiz   x4, x2, #6, #32         ; x4 = index * 64-byte Entry.
            ldr     x4, [x3, x4]            ; x4 = entry.localCurrentEpoch.
            cbz     x4, G_M000_IG05          ; 0 means inactive; ignore the slot.
 
G_M000_IG04:
            cmp     x4, x1                  ; Compare entryEpoch with oldest.
            bge     G_M000_IG05             ; Keep oldest if entry is newer/equal.
            mov     x1, x4                  ; oldestOngoingCall = entryEpoch.
 
G_M000_IG05:
            add     w2, w2, #1              ; ++index.
            cmp     w2, #128                ; Scan slots 1 through kTableSize.
            ble     G_M000_IG03
 
G_M000_IG06:
            sub     x1, x1, #1              ; Safe epoch = oldest active - 1.
            str     x1, [x0, #0x38]         ; Save SafeToReclaimEpoch.
            ldr     x0, [x0, #0x38]         ; Return it in x0.
 
G_M000_IG07:
            ldp     fp, lr, [sp], #0x10     ; Tear down frame.
            ret     lr                      ; Return to caller.
 
; Total bytes of code 72
