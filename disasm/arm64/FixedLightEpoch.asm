; Assembly listing for method Tsavorite.core.FixedLightEpoch:ProtectAndDrain():this (FullOpts)
; Emitting BLENDED_CODE for generic ARM64 - Unix
; FullOpts code
; optimized code
; fp based frame
; fully interruptible
; No PGO data
; 0 inlinees with PGO data; 1 single block inlinees; 0 inlinees without PGO data

G_M000_IG01:
            stp     fp, lr, [sp, #-0x20]!
            str     x19, [sp, #0x18]
            mov     fp, sp
            mov     x19, x0
 
G_M000_IG02:
            movz    x0, #0xD1FFAB1E
            movk    x0, #0xD1FFAB1E LSL #16
            movk    x0, #0xD1FFAB1E LSL #32
            mov     w1, #14
            bl      CORINFO_HELP_GETSHARED_GCTHREADSTATIC_BASE_NOCTOR
            ldr     x1, [x0]
            add     x1, x1, #8
            ldr     w0, [x19, #0x48]
            sbfiz   x0, x0, #2, #32
            add     x1, x1, x0
            ldr     x0, [x19, #0x28]
            ldr     w2, [x1]
            sbfiz   x2, x2, #6, #32
            add     x0, x0, x2
            ldr     x2, [x19, #0x30]
            str     x2, [x0]
            dmb     ish
            add     x0, x19, #68
            ldapr   w0, [x0]
            cmp     w0, #0
            ble     G_M000_IG04
 
G_M000_IG03:
            ldr     x0, [x19, #0x28]
            ldr     w1, [x1]
            sbfiz   x1, x1, #6, #32
            ldr     x1, [x0, x1]
            mov     x0, x19
            movz    x2, #0xD1FFAB1E
            movk    x2, #0xD1FFAB1E LSL #16
            movk    x2, #0xD1FFAB1E LSL #32
            ldr     x2, [x2]
            blr     x2
 
G_M000_IG04:
            add     x0, x19, #64
            ldapr   w0, [x0]
            cmp     w0, #0
            ble     G_M000_IG07
 
G_M000_IG05:
            mov     x0, x19
            movz    x1, #0xD1FFAB1E
            movk    x1, #0xD1FFAB1E LSL #16
            movk    x1, #0xD1FFAB1E LSL #32
            ldr     x1, [x1]
 
G_M000_IG06:
            ldr     x19, [sp, #0x18]
            ldp     fp, lr, [sp], #0x20
            br      x1
 
G_M000_IG07:
            ldr     x19, [sp, #0x18]
            ldp     fp, lr, [sp], #0x20
            ret     lr
 
; Total bytes of code 200

; Assembly listing for method Tsavorite.core.FixedLightEpoch:ComputeNewSafeToReclaimEpoch(long):long:this (FullOpts)
; Emitting BLENDED_CODE for generic ARM64 - Unix
; FullOpts code
; optimized code
; fp based frame
; fully interruptible
; No PGO data

G_M000_IG01:
            stp     fp, lr, [sp, #-0x10]!
            mov     fp, sp
 
G_M000_IG02:
            mov     w2, #1
            ldr     x3, [x0, #0x28]
            align   [0 bytes for IG03]
            align   [0 bytes]
            align   [0 bytes]
            align   [0 bytes]
 
G_M000_IG03:
            sbfiz   x4, x2, #6, #32
            ldr     x4, [x3, x4]
            cbz     x4, G_M000_IG05
 
G_M000_IG04:
            cmp     x4, x1
            bge     G_M000_IG05
            mov     x1, x4
 
G_M000_IG05:
            add     w2, w2, #1
            cmp     w2, #128
            ble     G_M000_IG03
 
G_M000_IG06:
            sub     x1, x1, #1
            str     x1, [x0, #0x38]
            ldr     x0, [x0, #0x38]
 
G_M000_IG07:
            ldp     fp, lr, [sp], #0x10
            ret     lr
 
; Total bytes of code 72

