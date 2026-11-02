#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != --inner ]]; then
    here=$(cd "$(dirname "$0")" && pwd)
    repo=$(dirname "$here")
    image=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
    exec podman run --rm --memory=14g --cpus=6 -v "${repo}:/repo:ro,Z" "${image}" \
        sh -c 'dnf -yq --setopt=install_weak_deps=False install mksh diffutils && /repo/tests/microos-android-cmd.sh --inner'
fi

cmd=/repo/packages/microos-android/data/usr/share/microos-android/cmd
[[ -f ${cmd} && ! -L ${cmd} ]] || { echo "FAIL: the guest cmd is missing" >&2; exit 1; }

T=$(mktemp -d)
trap 'chmod -R u+rwx "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
work=${T}/work
mkdir -p "${work}" "${T}/bin" "${T}/out" /system/bin

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > /system/bin/cmd_real <<'STUB'
#!/usr/bin/bash
out=${STUB_OUT:?}
printf '%s\n' "${#}" > "${out}/argc"
if (( $# > 0 )); then printf '%s\0' "$@" > "${out}/args"; else : > "${out}/args"; fi
cat > "${out}/stdin"
printf 'stdout %s\n' "${STUB_TAG:?}"
printf 'stderr %s\n' "${STUB_TAG}" >&2
printf '%s\n' "$$" > "${out}/pid"
printf 'called\n' > "${out}/called"
exit "${STUB_RC:-0}"
STUB
chmod 0755 /system/bin/cmd_real

for name in pm cmd mount umount dumpsys log setprop; do
    cat > "${T}/bin/${name}" <<STUB
#!/bin/sh
printf '%s %s\n' '${name}' "\$*" >> '${T}/called'
exit 97
STUB
    chmod 0755 "${T}/bin/${name}"
done
export PATH="${T}/bin:${PATH}"

: > "${T}/called"
input=${T}/input
printf 'line one\nline two\nbinary \001\002\n' > "${input}"
input_sha=$(sha256sum < "${input}" | cut -d' ' -f1)

cd "${work}"
before=$(find . -printf '%p %y %s\n' | sort)

check() {
    local name=$1 want=$2 rc=0 pid dir
    dir=${T}/out/${name}
    shift 2
    mkdir -p "${dir}"
    if (( $# > 0 )); then printf '%s\0' "$@" > "${dir}/want-args"; else : > "${dir}/want-args"; fi
    printf '%s\n' "${#}" > "${dir}/want-argc"
    STUB_OUT="${dir}" STUB_RC="${want}" STUB_TAG="${name}" \
        mksh "${cmd}" "$@" < "${input}" > "${dir}/stdout" 2> "${dir}/stderr" &
    pid=$!
    wait "${pid}" || rc=$?
    [[ "${rc}" == "${want}" ]] || fail "${name}: exit ${rc}, not ${want}: $(cat "${dir}/stderr")"
    [[ -f "${dir}/called" ]] || fail "${name}: cmd_real was not called"
    cmp -s "${dir}/args" "${dir}/want-args" || fail "${name}: arguments changed"
    cmp -s "${dir}/argc" "${dir}/want-argc" || fail "${name}: argument count changed"
    cmp -s "${dir}/stdout" <(printf 'stdout %s\n' "${name}") || fail "${name}: stdout changed"
    cmp -s "${dir}/stderr" <(printf 'stderr %s\n' "${name}") || fail "${name}: stderr changed"
    [[ "$(sha256sum < "${dir}/stdin" | cut -d' ' -f1)" == "${input_sha}" ]] || fail "${name}: stdin changed"
    [[ "$(cat "${dir}/pid")" == "${pid}" ]] || fail "${name}: cmd_real runs as pid $(cat "${dir}/pid"), not ${pid}, so the call is not an exec"
    [[ -z "$(cat "${T}/called")" ]] || fail "${name}: a stub ran: $(cat "${T}/called")"
}

check install 0 package install -r -g /sdcard/A.apk
check install-stream 0 package install -S 123456 -r -g
check commit 1 install-commit 123456
check existing 3 install-existing com.example.game
check uninstall 0 uninstall com.example.game
check verb 0 lepton mount_layers
check extra 0 lepton mount_vulkan_layers extra
check none 0
check list 0 package list packages

for want in 0 1 2 3 42; do
    rc=0
    mkdir -p "${T}/out/rc"
    STUB_OUT="${T}/out/rc" STUB_RC="${want}" STUB_TAG=rc mksh "${cmd}" package path com.example.game \
        < /dev/null > /dev/null 2> "${T}/out/rc/stderr" || rc=$?
    [[ "${rc}" == "${want}" ]] || fail "exit ${want}: mksh gave ${rc}: $(cat "${T}/out/rc/stderr")"
done

quiet=${T}/out/quiet
mkdir -p "${quiet}"
STUB_OUT="${quiet}" STUB_TAG=quiet mksh "${cmd}" lepton mount_vulkan_layers \
    < "${input}" > "${quiet}/stdout" 2> "${quiet}/stderr"
[[ ! -e "${quiet}/called" ]] || fail "lepton mount_vulkan_layers reached cmd_real"
[[ ! -s "${quiet}/stdout" && ! -s "${quiet}/stderr" ]] || fail "lepton mount_vulkan_layers wrote output"
[[ -z "$(cat "${T}/called")" ]] || fail "a stub ran: $(cat "${T}/called")"

after=$(find . -printf '%p %y %s\n' | sort)
[[ "${after}" == "${before}" ]] || fail "the scratch tree changed: ${after//$'\n'/ }"

echo "microos-android-cmd: ok"
