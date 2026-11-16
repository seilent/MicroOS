#!/usr/bin/bash

check() {
    return 255
}

depends() {
    echo systemd
}

installkernel() {
    instmods vfat nls_cp437 nls_iso8859-1 nvmem_qcom-spmi-sdam
}

install() {
    inst_multiple mount umount mountpoint sync mkdir mv rm cat tail dd od tr readlink sleep modprobe dmesg journalctl timeout \
        sha256sum stat blockdev
    inst_simple "$moddir/microos-guard" /usr/libexec/microos/microos-guard
    inst_simple /usr/libexec/microos/microos-sdam
    inst_simple /usr/libexec/microos/microos-bootb
    inst_simple /usr/lib/microos/slot.conf
    inst_simple "$moddir/microos-initrd-log" /usr/libexec/microos/microos-initrd-log
    inst_simple "$moddir/microos-guard.service" "$systemdsystemunitdir/microos-guard.service"
    inst_simple "$moddir/efi-device.conf" "$systemdsystemunitdir/dev-disk-by\\x2dpartlabel-microos_efi.device.d/10-microos.conf"
    inst_simple "$moddir/efi-device.conf" "$systemdsystemunitdir/dev-disk-by\\x2dpartlabel-boot_b.device.d/10-microos.conf"
    inst_simple "$moddir/efi-device.conf" "$systemdsystemunitdir/dev-disk-by\\x2dpartlabel-boot_a.device.d/10-microos.conf"
    inst_simple "$moddir/switch-root.conf" "$systemdsystemunitdir/initrd-switch-root.service.d/10-microos.conf"
    inst_simple "$moddir/emergency.conf" "$systemdsystemunitdir/emergency.service.d/10-microos.conf"
    inst_simple "$moddir/emergency.conf" "$systemdsystemunitdir/dracut-emergency.service.d/10-microos.conf"
    inst_simple "$moddir/cmdline.conf" /etc/cmdline.d/90-microos.conf
    $SYSTEMCTL -q --root "$initdir" enable microos-guard.service
    printf '%s %s\n' "$kernel" "$(date -u +%Y%m%dT%H%M%SZ)" > "$initdir/etc/microos-initrd-id"
}
