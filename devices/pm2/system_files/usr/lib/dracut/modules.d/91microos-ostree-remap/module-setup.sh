#!/usr/bin/bash

check() {
    return 255
}

depends() {
    echo ostree
}

install() {
    inst_multiple sh realpath mkdir
    inst_simple /usr/libexec/microos/prepare-root
    inst_simple "$moddir/prepare-root.conf" \
        "$systemdsystemunitdir/ostree-prepare-root.service.d/10-microos-remap.conf"
}
