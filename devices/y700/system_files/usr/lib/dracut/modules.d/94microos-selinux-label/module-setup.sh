#!/usr/bin/bash

check() {
    return 255
}

depends() {
    echo systemd
}

installkernel() {
    instmods btrfs vfat nls_cp437 nls_iso8859-1
}

install() {
    inst_multiple setfiles mount umount mountpoint mkdir ln readlink mv rm cat sed tail stat timeout sha256sum sync
    inst_simple "$moddir/microos-selinux-label" /usr/libexec/microos/microos-selinux-label
    inst_simple "$moddir/microos-selinux-label-etc.service" "$systemdsystemunitdir/microos-selinux-label-etc.service"
    inst_simple "$moddir/microos-selinux-label-var.service" "$systemdsystemunitdir/microos-selinux-label-var.service"
    $SYSTEMCTL -q --root "$initdir" enable microos-selinux-label-etc.service
    $SYSTEMCTL -q --root "$initdir" enable microos-selinux-label-var.service
}
