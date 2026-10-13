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
      podman run --rm --network=none "${cache[@]}" \
        -v "$PWD/packages/$1:/src:ro,Z" \
        -v "$PWD/$work:/work:ro,Z" \
        -v "$PWD/$out:/out:Z" \
        "$img" /src/build.sh /out /work
      rm -rf "$work"
    else
      podman run --rm "${cache[@]}" \
        -v "$PWD/packages/$1:/src:ro,Z" \
        -v "$PWD/$out:/out:Z" \
        "$img" /src/build.sh /out
    fi
    if [[ -f tests/pkg-$1.sh ]]; then
      podman run --rm --security-opt apparmor=unconfined \
        -v "$PWD/tests:/tests:ro,Z" \
        -v "$PWD/$out:/out:ro,Z" \
        "$img" "/tests/pkg-$1.sh" /out
    fi
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
    run "$fedora" sh -c "$dnf python3-gobject python3-evdev dbus-daemon util-linux systemd-udev && /repo/tests/powerd.sh && /repo/tests/hotkeyd.sh && /repo/tests/sleep.sh && /repo/tests/steamos-manager-policy.sh && /repo/tests/steamos-manager-config.sh"
    run -v "$PWD/system_files/usr/bin/steamos-update:/usr/bin/steamos-update:ro,Z" "$fedora" \
      sh -c "$dnf systemd-udev && /repo/tests/helpers.sh"
    run "$fedora" sh -c "$dnf alsa-ucm alsa-ucm-utils alsa-utils pipewire-utils systemd-udev && /repo/tests/audio.sh"
    just pkg gamescope-session
    run "$fedora" sh -c "$dnf /repo/out/pkg/gamescope-session/*.noarch.rpm && /repo/tests/session.sh"
