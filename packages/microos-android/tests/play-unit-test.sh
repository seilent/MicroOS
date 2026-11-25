#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
system="${repo}/data/usr/lib/systemd/system"
rules="${repo}/data/usr/share/polkit-1/rules.d/50-microos-android.rules"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

check() {
    local file="${system}/$1" line
    shift
    [[ -f "${file}" ]] || { fail "${file##*/} missing"; return; }
    for line in "$@"; do
        grep -qxF -- "${line}" "${file}" || fail "${file##*/} lacks ${line}"
    done
    grep -qE '^(WantedBy|RequiredBy)=' "${file}" && fail "${file##*/} is enabled"
    grep -q '^User=' "${file}" && fail "${file##*/} drops root"
    return 0
}
check microos-android-gsf.service Type=oneshot 'ExecStart=/usr/libexec/microos/microos-android-root gsf' \
    ProtectSystem=strict StateDirectory=microos-android PrivateNetwork=yes NoNewPrivileges=yes
check microos-android-reset.service Type=oneshot 'ExecStart=/usr/libexec/microos/microos-android-root reset' \
    PrivateNetwork=yes NoNewPrivileges=yes
check microos-android-layer.service Type=oneshot 'ExecStart=/usr/libexec/microos/microos-android-root layer' \
    PrivateNetwork=yes NoNewPrivileges=yes
check microos-android-gapps@.service Type=oneshot 'ExecStart=/usr/libexec/microos/microos-android-root gapps-%i' \
    TimeoutStartSec=30min Nice=19 IOSchedulingClass=idle StateDirectory=microos-android CacheDirectory=microos-android

re=$(sed -n 's/^  var units = \/\(.*\)\/;$/\1/p' "${rules}")
[[ -n "${re}" ]] || fail "no unit pattern in the polkit rule"
for u in microos-android-images.service microos-android-gsf.service microos-android-reset.service \
    microos-android-layer.service microos-android-gapps@fetch.service microos-android-gapps@install.service \
    microos-android-gapps@remove.service; do
    [[ "${u}" =~ ${re} ]] || fail "the polkit rule refuses ${u}"
done
for u in microos-android-gapps@other.service microos-android-root.service microos-android.service xmicroos-android-gsf.service \
    microos-android-gsf.serviceX microos-android-gapps@install.service.d; do
    [[ "${u}" =~ ${re} ]] && fail "the polkit rule allows ${u}"
done
grep -qF 'action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "micro"' "${rules}" || fail "polkit subject check"
grep -qF 'action.lookup("verb") == "start"' "${rules}" || fail "polkit verb check"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "play-unit-test: pass"
