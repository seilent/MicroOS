#!/usr/bin/bash

check() {
    return 255
}

depends() {
    echo systemd
}

install() {
    inst_multiple bash env cat ln mkdir rm rmdir readlink sleep stty journalctl modprobe
    inst_simple /usr/libexec/microos/microos-usb-console
    inst_simple "$moddir/microos-initrd-usbcon" /usr/libexec/microos/microos-initrd-usbcon
    inst_simple "$moddir/microos-initrd-usbcon.service" "$systemdsystemunitdir/microos-initrd-usbcon.service"
    $SYSTEMCTL -q --root "$initdir" enable microos-initrd-usbcon.service
}
