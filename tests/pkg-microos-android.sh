#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microos-android.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

rpm=$(find "$dir" -maxdepth 1 -name 'microos-android-1-*.noarch.rpm')
srpm=$(find "$dir" -maxdepth 1 -name 'microos-android-1-*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != GPL-2.0-or-later ]]; then fail "license tag: $(rpm -qp --qf '%{LICENSE}' "$rpm")"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=microos-android-data.tar.gz
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

requires=$(rpm -qp --requires "$rpm" | awk '{ print $1 }')
need=(microos-android-guestos waydroid lxc android-tools util-linux-core curl python3 python3-gobject python3-gbinder gtk3 xprop
  polkit)
for r in "${need[@]}"; do
  if ! grep -qx "$r" <<<"$requires"; then fail "does not require $r"; fi
done
for r in microemu zip podman passt catatonit inotify-tools java-25-openjdk-devel; do
  if grep -qx "$r" <<<"$requires"; then fail "still requires $r"; fi
done

files=$(rpm -qlp "$rpm")
for f in \
  /usr/bin/microos-android \
  /usr/libexec/microos/microos-android-battery \
  /usr/libexec/microos/microos-android-brightness \
  /usr/libexec/microos/microos-android-check \
  /usr/libexec/microos/microos-android-client \
  /usr/libexec/microos/microos-android-guest \
  /usr/libexec/microos/microos-android-install \
  /usr/libexec/microos/microos-android-lsfg \
  /usr/libexec/microos/microos-android-perf \
  /usr/libexec/microos/microos-android-root \
  /usr/libexec/microos/microos-android-status \
  /usr/libexec/microos/microos-fetch \
  /usr/libexec/microos/microos-gamescope-plain \
  /usr/lib/systemd/user/microos-android.service \
  /usr/lib/systemd/user/microos-android-battery.service \
  /usr/lib/systemd/user/microos-android-brightness.service \
  /usr/lib/systemd/user/microos-android-gapps.service \
  /usr/lib/systemd/user/microos-android-lsfg.service \
  /usr/lib/systemd/user/microos-android-perf.service \
  /usr/lib/systemd/user/microos-android-status.service \
  /usr/lib/systemd/system/microos-android-gapps@.service \
  /usr/lib/systemd/system/microos-android-gsf.service \
  /usr/lib/systemd/system/microos-android-layer.service \
  /usr/lib/systemd/system/microos-android-reset.service \
  /usr/share/polkit-1/rules.d/50-microos-android.rules \
  /usr/share/wayland-sessions/microos-android.desktop \
  /usr/share/gamescope-session-plus/sessions.d/android \
  /usr/share/microos-android/opts \
  /usr/share/microos-android/gapps.env; do
  if ! grep -qxF "$f" <<<"$files"; then fail "missing $f"; fi
done
for f in /usr/bin/steamvr /usr/lib/android-sdk/platform-tools/adb /usr/libexec/microos/microos-android-run \
  /usr/libexec/microos/microos-android-stop /usr/libexec/microos/microos-android-sideload /usr/libexec/microos/microos-lepton \
  /usr/libexec/microos/microos-lepton-lib.sh /usr/libexec/microos/microos-liblepton.sh /usr/share/microos-android/cmd \
  /usr/share/microos-android/restrictions-stub.jar /usr/lib/systemd/user/microos-lepton-prepare.service \
  /usr/lib/systemd/user/microos-android-gapps-setup.service /usr/share/microos-lepton; do
  if grep -qxF "$f" <<<"$files"; then fail "Lepton file $f installed"; fi
done
for f in /usr/share/microos-android/display /usr/lib/systemd/user/microos-android-pad.service \
  /usr/lib/systemd/user/gamescope-session-plus@android.service.d/20-microos-android-pad.conf \
  /usr/lib/microos/sessions.d/android.conf; do
  if grep -qxF "$f" <<<"$files"; then fail "$f is device data, not the package's"; fi
done
if grep -qE '^/usr/lib/(armada|extension-release\.d|extensions|microemu)|^/var/|^/etc/|^/usr/share/microemu|^/usr/bin/microemu-|^/usr/libexec/microemu' <<<"$files"; then
  fail "MicroEMU, sysext, Armada or host state paths: $(grep -E '^/usr/lib/(armada|extension-release\.d|extensions|microemu)|^/var/|^/etc/|^/usr/share/microemu|^/usr/bin/microemu-|^/usr/libexec/microemu' <<<"$files" | head -n5)"
fi
for f in microemu-lepton microemu-liblepton.sh microemu-play-run microemu-play-stop microemu-sideload microemu-pad-nodes \
  microemu-pad-fuzz microemu-android-sync microemu-android-roms microemu-context-move microemu-keyboard-install \
  microemu-gapps-install microemu-play-reset microemu-android-prune microemu-play-update; do
  if grep -q "/$f\$" <<<"$files"; then fail "removed file $f installed"; fi
done

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rpm2cpio "$rpm" > "$tmp/android.cpio"
(cd "$tmp" && mkdir root && cd root && cpio -idm --quiet < ../android.cpio)
root=$tmp/root

mkdir "$tmp/src"
rpm2cpio "$srpm" > "$tmp/srpm.cpio"
(cd "$tmp/src" && cpio -idm --quiet < "$tmp/srpm.cpio")
elf=$(find "$root/usr" -type f -exec sh -c 'for f; do if [ "$(head -c4 "$f" | od -An -tx1 | tr -d " ")" = 7f454c46 ]; then echo "$f"; fi; done' sh {} +)
if [[ -n $elf ]]; then fail "ELF files shipped: ${elf//$root/}"; fi

for f in "$root"/usr/libexec/microos/* "$root/usr/bin/microos-android"; do
  [[ -f $f ]] || continue
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$root"} is not 755"; fi
done

app=("$root/usr/libexec/microos" "$root/usr/bin" "$root/usr/lib/systemd" "$root/usr/share/microos-android")
legacy='contexts/microemu-\$\{old\}|share/microemu/android/home'
hits=$(grep -rnE 'armada|/run/armada|session-control|date \+%s|EPOCHREALTIME|MICROEMU|microemu|podman|lepton-android|microos-lepton' "${app[@]}" \
  | grep -vE "${legacy}" | cut -d: -f1 | sort -u || true)
if [[ -n $hits ]]; then fail "Armada names, wall clock waits or MicroEMU names in: ${hits//$root/}"; fi

unit=$root/usr/lib/systemd/user/microos-android.service
for line in Type=simple PartOf=gamescope-session-plus@android.service StopPropagatedFrom=gamescope-session-plus@android.service \
  Requisite=gamescope-session-plus@android.service After=gamescope-session-plus@android.service \
  Wants=microos-android-brightness.service EnvironmentFile=%t/microos-android/session.env \
  'ExecStart=/usr/bin/flock -s /run/microos-android/images.lock /usr/bin/waydroid session start' \
  'ExecStop=-/usr/libexec/microos/microos-android-guest stop' 'ExecStop=/usr/bin/waydroid session stop' \
  'ExecStopPost=/usr/bin/waydroid session stop' TimeoutStopSec=45; do
  if ! grep -qxF "$line" "$unit"; then fail "microos-android.service lacks $line"; fi
done
if grep -qE '^(BindsTo|Requires)=' "$unit"; then fail "microos-android.service binds or requires a unit"; fi
desktop=$root/usr/share/wayland-sessions/microos-android.desktop
for line in Exec=gamescope-session-plus\ android Type=Application DesktopNames=android NoDisplay=true; do
  if ! grep -qxF "$line" "$desktop"; then fail "microos-android.desktop lacks $line"; fi
done
client=$root/usr/share/gamescope-session-plus/sessions.d/android
for line in export\ GAMESCOPE_BIN=/usr/libexec/microos/microos-gamescope-plain \
  export\ CLIENTCMD=/usr/libexec/microos/microos-android-client; do
  if ! grep -qxF "$line" "$client"; then fail "the android client file lacks $line"; fi
done

exit "$rc"
