FROM quay.io/fedora/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d

RUN find /etc/yum.repos.d -type f ! -name fedora.repo ! -name fedora-updates.repo -delete \
 && dnf -y --setopt=install_weak_deps=False install \
      rpm-build systemd-rpm-macros \
      gcc make perl-interpreter python3 \
      git-core curl tar gzip xz zstd cpio findutils diffutils which \
      bc bison flex dwarves dtc openssl openssl-devel elfutils-libelf-devel kmod ccache \
 && dnf clean all

ENV MICROOS_MARCH="-march=armv8.2-a+fp16+dotprod+rcpc -mtune=cortex-a77"
