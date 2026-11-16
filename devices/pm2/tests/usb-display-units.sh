#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fedora=${FEDORA:-registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d}
tmp=$(mktemp -d)
name=microos-usb-display-units-$$
image=localhost/microos-usb-display-units:$$
cleanup() {
  podman rm -f "$name" > /dev/null 2>&1 || true
  podman rmi -f "$image" > /dev/null 2>&1 || true
  podman unshare rm -rf "${tmp:?}" 2> /dev/null || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'FROM %s\nRUN dnf -yq --setopt=install_weak_deps=False install systemd iproute python3 util-linux procps-ng shadow-utils findutils gawk diffutils dbus-broker systemd-pam python3-gobject python3-evdev gstreamer1-plugins-base gstreamer1-plugins-good && dnf clean all\n' \
  "$fedora" | podman build -q --memory=14g --cpu-period=100000 --cpu-quota=600000 -t "$image" -f - "$tmp" > /dev/null
mkdir "$tmp/journal"
podman run -d --name "$name" --memory=14g --cpus=6 --systemd=always --privileged -v "$here/..:/repo:ro,Z" \
  -v "$tmp/journal:/var/log/journal:Z" \
  "$image" /usr/sbin/init > /dev/null
for (( i = 0; i < 120; i++ )); do
  state=$(podman exec "$name" systemctl is-system-running --wait 2> /dev/null || true)
  [[ $state != running && $state != degraded ]] || break
  sleep 1
done
[[ $state == running || $state == degraded ]] || fail "systemd in the container did not finish booting: $state"
podman exec "$name" /repo/tests/usb-display/units || fail "unit graph"
podman exec "$name" systemd-cat -t usb-display-units echo "shutdown begins"
podman exec "$name" systemctl --no-block poweroff
code=$(timeout 120 podman wait "$name") || fail "the container did not stop within 120 s of the poweroff"
journal=$(podman run --rm --memory=14g --cpus=6 -v "$tmp/journal:/var/log/journal:ro,Z" "$image" journalctl -D /var/log/journal -o cat)
shutdown=$(sed -n '/^shutdown begins$/,$p' <<< "$journal")
[[ -n $shutdown ]] || fail "no shutdown in the journal"
order=()
for l in "Stopped microos-usb-display-link.service " "Closed microos-usb-display-link.socket " \
  "Stopped microos-usb-display-gadget.service " "Stopped microos-usb-display-arm.service "; do
  n=$(grep -nF -m1 "$l" <<< "$shutdown" | cut -d: -f1)
  [[ -n $n ]] || fail "shutdown lacks '$l'"
  order+=("$n")
done
(( order[0] < order[1] && order[1] < order[2] && order[2] < order[3] )) || fail "shutdown stop order: lines ${order[*]}"
bad=$(grep -E 'ordering cycle|Job .* deleted to break|Dependency failed|microos-usb-display.*([Ff]ailed|keeping it)' <<< "$shutdown" || true)
[[ -z $bad ]] || fail "shutdown transaction: $bad"
echo "usb-display-units: ok (container exit $code)"
