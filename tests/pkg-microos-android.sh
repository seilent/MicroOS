#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microos-android.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
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
want=$(printf '%s\n' microos-android-data.tar.gz microos-android-stub.tar.gz microos-android-assets.tar.gz stub.sh | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

requires=$(rpm -qp --requires "$rpm" | awk '{ print $1 }')
need=(microos-android-guestos podman passt catatonit android-tools attr curl unzip python3 python3-gobject gtk3 rsync procps-ng)
for r in "${need[@]}"; do
  if ! grep -qx "$r" <<<"$requires"; then fail "does not require $r"; fi
done
for r in microemu zip; do
  if grep -qx "$r" <<<"$requires"; then fail "still requires $r"; fi
done

files=$(rpm -qlp "$rpm")
for f in \
  /usr/libexec/microos/microos-android-keyboard \
  /usr/libexec/microos/microos-android-pad-nodes \
  /usr/libexec/microos/microos-android-run \
  /usr/libexec/microos/microos-android-sideload \
  /usr/libexec/microos/microos-android-stop \
  /usr/libexec/microos/microos-fetch \
  /usr/libexec/microos/microos-lepton \
  /usr/libexec/microos/microos-lepton-steam \
  /usr/libexec/microos/microos-liblepton.sh \
  /usr/bin/microos-android \
  /usr/lib/systemd/user/microos-android.service \
  /usr/share/microos-android/display \
  /usr/share/microos-android/opts \
  /usr/share/microos-android/restrictions-stub.jar \
  /usr/share/microos-android/restrictions-stub.rc \
  /usr/share/microos-lepton/reviewed/25772114 \
  /usr/share/microos-lepton/steam-empty; do
  if ! grep -qxF "$f" <<<"$files"; then fail "missing $f"; fi
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
mapfile -t tars < <(find "$tmp/src" -maxdepth 1 -name 'microos-android-*.tar.gz' | sort)
if (( ${#tars[@]} != 3 )); then fail "the SRPM does not unpack the data, stub and assets tarballs"; fi
for t in "${tars[@]}"; do
  list=$(tar -tzf "$t") || { fail "cannot list ${t##*/}"; continue; }
  sdk=$(grep -E '(^|/)(android\.jar|platform-[^/]*\.zip|r8-[^/]*\.jar)$' <<<"$list" || true)
  if [[ -n $sdk ]]; then fail "${t##*/} holds an Android SDK file: ${sdk//$'\n'/ }"; fi
done

elf=$(find "$root/usr" -type f -exec sh -c 'for f; do if [ "$(head -c4 "$f" | od -An -tx1 | tr -d " ")" = 7f454c46 ]; then echo "$f"; fi; done' sh {} +)
if [[ -n $elf ]]; then fail "ELF files shipped: ${elf//$root/}"; fi

for f in "$root"/usr/libexec/microos/*; do
  [[ -f $f ]] || continue
  [[ $f == */microos-liblepton.sh ]] && continue
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$root"} is not 755"; fi
done
if [[ $(stat -c %a "$root/usr/libexec/microos/microos-liblepton.sh" 2>/dev/null) != 644 ]]; then
  fail "/usr/libexec/microos/microos-liblepton.sh is not 644"
fi
if [[ $(head -c2 "$root/usr/libexec/microos/microos-liblepton.sh") == '#!' ]]; then
  fail "/usr/libexec/microos/microos-liblepton.sh carries a shebang, it is sourced"
fi
if [[ $(stat -c %a "$root/usr/bin/microos-android" 2>/dev/null) != 755 ]]; then
  fail "/usr/bin/microos-android is not 755"
fi
for f in "$root"/usr/share/microos-lepton/reviewed/*; do
  [[ -f $f && ! -L $f ]] || fail "${f#"$root"} is not a regular file"
done
if [[ -e $root/usr/share/microos-lepton/reviewed/lepton-reviewed ]]; then fail "the reviewed dir is nested"; fi
stem=$root/usr/share/microos-lepton/steam-empty
if [[ ! -d $stem || -L $stem || -n $(find "$stem" -mindepth 1) ]]; then
  fail "usr/share/microos-lepton/steam-empty is not an empty dir"
fi
if [[ -n $(find "$root/usr/share/microos-android" -maxdepth 1 -name '.stub.*') ]]; then
  fail "the stub build left a work dir in /usr/share/microos-android"
fi

app=("$root/usr/libexec/microos" "$root/usr/bin" "$root/usr/lib/systemd" "$root/usr/share/microos-android")
hits=$(grep -rlE 'armada|/run/armada|session-control|date \+%s|EPOCHREALTIME|MICROEMU|microemu' "${app[@]}" || true)
if [[ -n $hits ]]; then fail "Armada names, wall clock waits or MicroEMU names in: ${hits//$root/}"; fi

unit=$root/usr/lib/systemd/user/microos-android.service
for line in StopPropagatedFrom=gamescope-session-plus@android.service Type=notify NotifyAccess=all \
  TimeoutStartSec=120 TimeoutStopSec=20 SuccessExitStatus=143 \
  ExecStartPre=/usr/bin/podman\ rm\ -fi\ lepton-android ExecStart=/usr/libexec/microos/microos-android-run \
  ExecStop=/usr/libexec/microos/microos-android-stop \
  ExecStopPost=/usr/libexec/microos/microos-android-stop\ --post; do
  if ! grep -qF "$line" "$unit"; then fail "microos-android.service lacks $line"; fi
done
if grep -qE '^(BindsTo|Wants)=' "$unit"; then fail "microos-android.service pulls a start"; fi
if grep -q 'SuccessExitStatus=.*137' "$unit"; then fail "microos-android.service hides a 137"; fi
if grep -qE '^(Requisite|Requires|After|EnvironmentFile)=' "$unit"; then
  fail "microos-android.service carries a key of the session and prepare batches"
fi
if [[ -e $root/usr/lib/microos/sessions.d || -e $root/usr/share/wayland-sessions || -e $root/usr/share/gamescope-session-plus ]]; then
  fail "a session entry of a later batch is shipped"
fi

rc_file=$root/usr/share/microos-android/restrictions-stub.rc
if ! grep -qx 'service microos_restrictions_stub /system/bin/app_process -Djava.class.path=/system/framework/restrictions-stub.jar /system/bin RestrictionsStub' "$rc_file"; then
  fail "rc service line"
fi
if grep -q '#' "$rc_file"; then fail "rc carries a comment"; fi

unzip -p "$root/usr/share/microos-android/restrictions-stub.jar" classes.dex > "$tmp/classes.dex" || fail "the stub jar holds no classes.dex"
if [[ $(unzip -Z1 "$root/usr/share/microos-android/restrictions-stub.jar") != classes.dex ]]; then
  fail "the stub jar holds more than classes.dex"
fi
if ! grep -qa RestrictionsStub "$tmp/classes.dex"; then fail "classes.dex does not name RestrictionsStub"; fi

if grep -qF 'debug.mesa.tu.debug=noubwc' "$root/usr/libexec/microos/microos-android-run"; then
  fail "the run still writes the noubwc odm line"
fi
if ! grep -qF 'keycodes[[:space:]]+114' "$root/usr/libexec/microos/microos-android-run"; then
  fail "the run has no keycodes derive step"
fi
if ! grep -qF 'destination=/system/etc/init/lineage-system.rc,ro' "$root/usr/libexec/microos/microos-android-run"; then
  fail "the run does not bind the derived rc"
fi

exit "$rc"
