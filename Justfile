set positional-arguments

builder := "localhost/microos-pkg-builder"

pkg name:
    #!/usr/bin/env bash
    set -euo pipefail
    hash=$(build/pkg-hash.sh "$1")
    mapfile -t inputs < <(build/pkg-hash.sh --inputs "$1")
    dirty=0
    [[ -z $(git status --porcelain -- "${inputs[@]}") ]] || dirty=1
    out=out/pkg/$1
    tag=localhost/microos-pkg/$1:$hash
    mapfile -t deps < <(build/pkg-hash.sh --deps "$1")
    depdir=out/deps/$1
    rm -rf "$depdir"
    mounts=()
    for dep in "${deps[@]}"; do
      dtag=localhost/microos-pkg/$dep:$(build/pkg-hash.sh "$dep")
      mapfile -t dinputs < <(build/pkg-hash.sh --inputs "$dep")
      if [[ -n $(git status --porcelain -- "${dinputs[@]}") \
        || $(podman image inspect -f '{{{{index .Labels "microos.dirty"}}' "$dtag" 2>/dev/null) != 0 ]]; then
        just pkg "$dep"
      fi
      [[ $(podman image inspect -f '{{{{index .Labels "microos.dirty"}}' "$dtag") == 0 ]] || dirty=1
      mkdir -p "$depdir"
      ctr=$(podman create "$dtag" none)
      podman cp "$ctr:/rpms/." "$depdir/"
      podman rm "$ctr" >/dev/null
    done
    (( ${#deps[@]} == 0 )) || mounts=(-v "$PWD/$depdir:/deps:ro,Z")
    if [[ $1 == microset && -n ${MICROSET_SRC:-} ]]; then
      mounts+=(-v "$(realpath "$MICROSET_SRC"):/microset-src:ro,Z" -e MICROSET_SRC=/microset-src)
    fi
    podman build -t {{builder}} -f build/pkg.Containerfile build
    img={{builder}}
    if [[ -f packages/$1/Containerfile ]]; then
      img={{builder}}-$1
      podman build -t "$img" -f "packages/$1/Containerfile" "packages/$1"
    fi
    rm -rf "$out"
    mkdir -p "$out"
    cache=()
    if [[ -n ${PKG_CCACHE:-} ]]; then
      mkdir -p "$PKG_CCACHE"
      cache=(-v "$PKG_CCACHE:/ccache:Z" -e CCACHE_DIR=/ccache)
    fi
    if [[ -f packages/$1/fetch.sh ]]; then
      work=out/work/$1
      rm -rf "$work"
      mkdir -p "$work"
      podman run --rm \
        -v "$PWD/packages/$1:/src:ro,Z" \
        -v "$PWD/$work:/work:Z" \
        "$img" /src/fetch.sh /work
      podman run --rm --network=none "${cache[@]}" "${mounts[@]}" \
        -v "$PWD/packages/$1:/src:ro,Z" \
        -v "$PWD/$work:/work:ro,Z" \
        -v "$PWD/$out:/out:Z" \
        "$img" /src/build.sh /out /work
      rm -rf "$work"
    else
      podman run --rm "${cache[@]}" "${mounts[@]}" \
        -v "$PWD/packages/$1:/src:ro,Z" \
        -v "$PWD/$out:/out:Z" \
        "$img" /src/build.sh /out
    fi
    if [[ -f tests/pkg-$1.sh ]]; then
      podman run --rm --security-opt apparmor=unconfined "${mounts[@]}" \
        -v "$PWD/tests:/tests:ro,Z" \
        -v "$PWD/$out:/out:ro,Z" \
        "$img" "/tests/pkg-$1.sh" /out
    fi
    rm -rf "$depdir"
    [[ ! -e $out/dirty ]] || dirty=1
    podman build -f build/pkg-wrap.Containerfile --label "microos.dirty=$dirty" -t "$tag" "$out"
    echo "$tag"

kernel:
    PKG_CCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/microos-ccache/kernel" just pkg kernel

pkg-push name:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t inputs < <(build/pkg-hash.sh --inputs "$1")
    if [[ -n $(git status --porcelain -- "${inputs[@]}") ]]; then
      echo "uncommitted changes in the inputs of $1" >&2
      exit 1
    fi
    hash=$(build/pkg-hash.sh "$1")
    local=localhost/microos-pkg/$1:$hash
    if [[ $(podman inspect -f '{{{{index .Labels "microos.dirty"}}' "$local") != 0 ]]; then
      echo "$local was built from uncommitted inputs" >&2
      exit 1
    fi
    for dep in $(build/pkg-hash.sh --deps "$1"); do
      dtag=localhost/microos-pkg/$dep:$(build/pkg-hash.sh "$dep")
      if ! podman image exists "$dtag"; then
        echo "dep $dep has no local image $dtag, run just pkg $dep" >&2
        exit 1
      fi
      if [[ $(podman inspect -f '{{{{index .Labels "microos.dirty"}}' "$dtag") != 0 ]]; then
        echo "$dtag, a dep of $1, was built from uncommitted inputs" >&2
        exit 1
      fi
    done
    repo=ghcr.io/seilent/microos/pkg/$1
    api=/user/packages/container/microos%2Fpkg%2F$1
    keys=${MICROOS_KEYS:-$HOME/.config/microos/keys}
    cosign=${COSIGN:-cosign}
    podman login --get-login ghcr.io >/dev/null
    if ! gh api "$api" >/dev/null 2>&1; then
      start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      gh workflow run package-init.yml -R seilent/MicroOS -f name="$1"
      run=
      for _ in $(seq 60); do
        sleep 5
        run=$(gh run list -R seilent/MicroOS --workflow package-init.yml --event workflow_dispatch \
          --user seilent --json databaseId,createdAt \
          --jq "[.[] | select(.createdAt >= \"$start\")][0].databaseId // empty")
        [[ -z $run ]] || break
      done
      [[ -n $run ]] || { echo "package-init run not found" >&2; exit 1; }
      gh run watch "$run" -R seilent/MicroOS --exit-status >/dev/null
    fi
    if err=$(skopeo inspect --raw "docker://$repo:$hash" 2>&1 >/dev/null); then
      echo "$repo:$hash exists" >&2
      exit 1
    fi
    if ! grep -qiE 'manifest unknown|404' <<< "$err"; then
      echo "$err" >&2
      exit 1
    fi
    podman tag "$local" "$repo:$hash"
    digest=$(mktemp)
    trap 'rm -f "$digest"' EXIT
    podman push --digestfile "$digest" "$repo:$hash"
    COSIGN_PASSWORD=$(cat "$keys/microos.password") \
      "$cosign" sign -y --new-bundle-format=false --key "$keys/microos.key" "$repo@$(cat "$digest")"
    "$cosign" verify --key system_files/usr/share/microos/keys/microos.pub "$repo@$(cat "$digest")" >/dev/null
    init=$(gh api "$api/versions" --jq '.[] | select(.metadata.container.tags | index("init")) | .id')
    if [[ -n $init ]]; then
      gh api -X DELETE "$api/versions/$init"
    fi
    echo "$repo:$hash"

test:
    tests/pkg-hash.sh

test-services:
    #!/usr/bin/env bash
    set -euo pipefail
    case $(uname -m) in
      x86_64) arch=amd64 ;;
      aarch64) arch=arm64 ;;
      *) echo "no fedora:44 for $(uname -m)" >&2; exit 1 ;;
    esac
    fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
    dnf="dnf -yq --setopt=install_weak_deps=False install"
    run() { podman run --rm --arch "$arch" -v "$PWD:/repo:ro,Z" "$@"; }
    run "$fedora" sh -c "$dnf python3-gobject python3-evdev dbus-daemon util-linux systemd-udev && /repo/tests/powerd.sh && /repo/tests/vpower.sh && /repo/tests/hotkeyd.sh && /repo/tests/sleep.sh && /repo/tests/steamos-manager-policy.sh && /repo/tests/steamos-manager-config.sh"
    run -v "$PWD/system_files/usr/bin/steamos-update:/usr/bin/steamos-update:ro,Z" "$fedora" \
      sh -c "$dnf systemd-udev && /repo/tests/helpers.sh"
    run "$fedora" sh -c "$dnf alsa-ucm alsa-ucm-utils alsa-utils pipewire-utils systemd-udev && /repo/tests/audio.sh"
    run "$fedora" sh -c "$dnf jq util-linux systemd-udev && /repo/tests/storage.sh"
    run "$fedora" sh -c "$dnf jq python3 util-linux systemd && /repo/tests/microos-session.sh"
    run "$fedora" sh -c "$dnf git-core && /repo/tests/pkg-hash.sh"
    just pkg microset
    just pkg gamescope-session
    run "$fedora" sh -c "$dnf /repo/out/pkg/gamescope-session/*.noarch.rpm && /repo/tests/session.sh"
