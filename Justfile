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
    podman run --rm \
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

test:
    tests/pkg-hash.sh
