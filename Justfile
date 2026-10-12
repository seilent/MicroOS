set positional-arguments

builder := "localhost/microos-pkg-builder"

pkg name:
    #!/usr/bin/env bash
    set -euo pipefail
    hash=$(build/pkg-hash.sh "$1")
    out=out/pkg/$1
    tag=localhost/microos-pkg/$1:$hash
    podman build -t {{builder}} -f build/pkg.Containerfile build
    rm -rf "$out"
    mkdir -p "$out"
    cache=()
    if [[ -n ${PKG_CCACHE:-} ]]; then
      mkdir -p "$PKG_CCACHE"
      cache=(-v "$PKG_CCACHE:/ccache:Z" -e CCACHE_DIR=/ccache)
    fi
    podman run --rm "${cache[@]}" \
      -v "$PWD/packages/$1:/src:ro,Z" \
      -v "$PWD/$out:/out:Z" \
      {{builder}} /src/build.sh /out
    if [[ -f tests/pkg-$1.sh ]]; then
      podman run --rm \
        -v "$PWD/tests:/tests:ro,Z" \
        -v "$PWD/$out:/out:ro,Z" \
        {{builder}} "/tests/pkg-$1.sh" /out
    fi
    printf 'FROM scratch\nCOPY *.rpm /rpms/\n' > "$out/Containerfile"
    podman build -f "$out/Containerfile" \
      --label org.opencontainers.image.source=https://github.com/seilent/MicroOS \
      -t "$tag" "$out"
    echo "$tag"

kernel:
    PKG_CCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/microos-ccache/kernel" just pkg kernel

kernel-push:
    #!/usr/bin/env bash
    set -euo pipefail
    hash=$(build/pkg-hash.sh kernel)
    repo=ghcr.io/seilent/microos/pkg/kernel
    keys=${MICROOS_KEYS:-$HOME/.config/microos/keys}
    cosign=${COSIGN:-cosign}
    podman login --get-login ghcr.io >/dev/null
    if skopeo inspect --raw "docker://$repo:$hash" >/dev/null 2>&1; then
      echo "$repo:$hash exists" >&2
      exit 1
    fi
    podman tag "localhost/microos-pkg/kernel:$hash" "$repo:$hash"
    digest=$(mktemp)
    trap 'rm -f "$digest"' EXIT
    podman push --digestfile "$digest" "$repo:$hash"
    COSIGN_PASSWORD=$(cat "$keys/microos.password") \
      "$cosign" sign -y --new-bundle-format=false --key "$keys/microos.key" "$repo@$(cat "$digest")"
    "$cosign" verify --key system_files/usr/share/microos/keys/microos.pub "$repo:$hash" >/dev/null
    echo "$repo:$hash"

test:
    tests/pkg-hash.sh
