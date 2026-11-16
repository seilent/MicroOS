    .text
    .global _start
_start:
    b start
    nop
    .quad 0
    .quad 0
    .quad 0xa
    .zero 24
    .byte 0x41, 0x52, 0x4d, 0x64
    .zero 4

.macro LOAD64 r, v
    movz \r, #((\v) & 0xffff)
    movk \r, #(((\v) >> 16) & 0xffff), lsl #16
    movk \r, #(((\v) >> 32) & 0xffff), lsl #32
    movk \r, #(((\v) >> 48) & 0xffff), lsl #48
.endm

start:
    mov x19, x0

.if PRESET
sdam_preset:
    LOAD64 x23, 0xc400000
    LOAD64 x24, 0xc42d000
    ldr w21, [x23]
    lsr w2, w21, #28
    cmp w2, #7
    b.ne preset_done
    ldr w25, [x23, #4]
    and x25, x25, #0x7ff
    mov x2, #1024
    cmp x25, x2
    csel x25, x25, x2, lo
    mov x5, #0
    movn x28, #0
    add x2, x23, #0x2000
1:
    cmp x5, x25
    b.hs 3f
    ldr w10, [x2, x5, lsl #2]
    ubfx w11, w10, #8, #12
    cmp w11, #0x71
    b.ne 2f
    ldr w11, [x24, x5, lsl #2]
    tst w11, #7
    b.ne 2f
    mov x28, x5
    b 3f
2:
    add x5, x5, #1
    b 1b
3:
    cmn x28, #1
    b.eq preset_done
    LOAD64 x17, 0xc440000
    add x17, x17, x28, lsl #5
    mov w0, #0x04
    bl obs_read
    cbz x2, preset_done
    cmp x0, #0x2e
    b.ne preset_done
    mov w0, #0x05
    bl obs_read
    cbz x2, preset_done
    cmp x0, #1
    b.ne preset_done
    mov w0, #0x48
    bl obs_read
    cbz x2, preset_done
    and w3, w0, #1
    orr w3, w3, #4
    LOAD64 x20, 0xc500000
    add x20, x20, x28, lsl #12
    str w3, [x20, #0x10]
    dsb sy
    mov w5, #0x480
    str w5, [x20]
    LOAD64 x7, 100000
4:
    ldr w8, [x20, #8]
    tbnz w8, #0, preset_done
    subs x7, x7, #1
    b.ne 4b
preset_done:
.endif

    adr x1, wd_start
    adr x2, wd_end
    LOAD64 x4, ROUTINE
1:
    ldr x6, [x1], #8
    str x6, [x4], #8
    cmp x1, x2
    b.lo 1b
    LOAD64 x10, STATUS
    LOAD64 x3, ((SIGNATURE << 16) | ARMED)
    str w3, [x10]
    str wzr, [x10, #4]
    LOAD64 x11, DISARM
    str wzr, [x11]
    dsb sy

    mrs x6, ctr_el0
    ubfx x6, x6, #16, #4
    mov x7, #4
    lsl x6, x7, x6
    LOAD64 x8, ROUTINE
    add x12, x11, #64
2:
    dc cvac, x8
    add x8, x8, x6
    cmp x8, x12
    b.lo 2b
    dsb sy
    ic iallu
    dsb sy
    isb

    LOAD64 x0, 0xc4000003
    LOAD64 x1, MPIDR
    LOAD64 x2, ROUTINE
    adr x5, wd_code
    adr x6, wd_start
    sub x5, x5, x6
    add x2, x2, x5
    mov x3, #0
    smc #0
    cbz x0, boot
    LOAD64 x10, STATUS
    LOAD64 x3, ((SIGNATURE << 16) | REFUSED)
    str w3, [x10]
    str w0, [x10, #4]
    dsb sy

boot:
    adr x4, _start
    LOAD64 x5, PAYLOAD
    add x4, x4, x5
    mov x0, x19
    mov x1, #0
    mov x2, #0
    mov x3, #0
    br x4

.if PRESET
obs_read:
    lsl w5, w0, #4
    movz w6, #0x0800, lsl #16
    orr w5, w5, w6
    str w5, [x17]
    LOAD64 x7, 100000
1:
    ldr w8, [x17, #8]
    tbnz w8, #0, 2f
    subs x7, x7, #1
    b.ne 1b
    mov x2, #0
    ret
2:
    tst w8, #0xe
    b.ne 3f
    ldr w0, [x17, #0x18]
    and x0, x0, #0xff
    mov x2, #1
    ret
3:
    mov x2, #0
    ret
.endif

    .p2align 12
wd_start:
    .rept 16
    .p2align 7
    b wd_reset
    .endr
wd_code:
    adr x0, wd_start
    msr vbar_el1, x0
    isb
    add x9, x0, #0x1000
    mov x1, x9
    mov x2, #512
1:
    str xzr, [x1], #8
    subs x2, x2, #1
    b.ne 1b
    mov x3, #0x709
    str x3, [x9]
    LOAD64 x3, 0x40000709
    str x3, [x9, #8]
    LOAD64 x3, 0x80000701
    str x3, [x9, #16]
    LOAD64 x3, 0xc0000705
    str x3, [x9, #24]
    mov x1, x9
    mov x2, #64
2:
    dc civac, x1
    add x1, x1, #64
    subs x2, x2, #1
    b.ne 2b
    dsb sy
    mov x3, #0x44ff
    msr mair_el1, x3
    LOAD64 x3, 0x200803d19
    msr tcr_el1, x3
    msr ttbr0_el1, x9
    isb
    tlbi vmalle1
    dsb nsh
    isb
    mrs x3, sctlr_el1
    mov x4, #0x1005
    orr x3, x3, x4
    msr sctlr_el1, x3
    isb

    LOAD64 x20, STATUS
    LOAD64 x21, DISARM
    LOAD64 x26, MAGIC
    LOAD64 x27, DEADLINE
    LOAD64 x28, ((SIGNATURE << 16) | RUNNING)
    mrs x23, cntfrq_el0
    cbnz x23, 3f
    LOAD64 x23, 0x124f800
3:
    mrs x22, cntvct_el0
    mov x24, x22
wd_loop:
    ldr w1, [x21]
    cmp w1, w26
    b.eq wd_off
    mrs x0, cntvct_el0
    sub x0, x0, x22
    udiv x0, x0, x23
    str w0, [x20, #4]
    str w28, [x20]
    dsb sy
    cmp x0, x27
    b.hs wd_reset
    add x24, x24, x23
4:
    mrs x3, cntvct_el0
    cmp x3, x24
    b.lo 4b
    b wd_loop
wd_off:
    LOAD64 x3, ((SIGNATURE << 16) | STOPPED)
    str w3, [x20]
    dsb sy
    LOAD64 x0, 0x84000002
    smc #0
5:
    wfe
    b 5b
wd_reset:
    LOAD64 x0, 0x84000009
    smc #0
6:
    wfe
    b 6b
    .p2align 3
wd_end:
