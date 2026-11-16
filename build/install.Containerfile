FROM registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d

RUN find /etc/yum.repos.d -type f ! -name fedora.repo ! -name fedora-updates.repo -delete \
 && dnf -y --setopt=install_weak_deps=False install \
      android-tools btrfs-progs dosfstools mtools ostree rpm-ostree policycoreutils util-linux \
      binutils-aarch64-linux-gnu skopeo python3 openssl attr jq tar gzip findutils diffutils \
 && dnf clean all
