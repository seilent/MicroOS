#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
install="${libexec}/microos-android-install"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${STATE}/bin" "${T}/bin" "${T}/home"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_SYSTEMCTL="${T}/bin/systemctl"
export PATH="${T}/bin:${PATH}"

cat > "${T}/bin/systemctl" <<STUB
#!/usr/bin/bash
echo "systemctl \$*" >> "${STATE}/calls"
case "\$1 \$2 \$3" in
    "--user is-active --quiet") [[ -e "${STATE}/steam-active" ]] ;;
    "--user start --no-block") [[ ! -e "${STATE}/start-fails" ]] ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/systemctl"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${T}/home/.local/state" "${STATE}/calls"
    : > "${STATE}/calls"
    rm -f "${STATE}/steam-active" "${STATE}/start-fails"
}

run() {
    rc=0
    "${install}" > "${STATE}/out" 2> "${STATE}/stderr" || rc=$?
}

reset
: > "${STATE}/steam-active"
run
[[ "${rc}" == 0 ]] || fail "Steam active: exit ${rc}: $(cat "${STATE}/stderr")"
flag="${T}/home/.local/state/microos-lepton/lepton-install-requested"
[[ -f "${flag}" && ! -s "${flag}" ]] || fail "Steam active: the flag is not an empty file: $(ls -l "${flag}" 2>/dev/null)"
grep -qx "systemctl --user is-active --quiet gamescope-session-plus@steam.service" "${STATE}/calls" \
    || fail "Steam active: the Steam session was not checked: $(cat "${STATE}/calls")"
grep -qx "systemctl --user start --no-block microos-lepton-install.service" "${STATE}/calls" \
    || fail "Steam active: the unit was not started: $(cat "${STATE}/calls")"

reset
run
[[ "${rc}" == 0 ]] || fail "Steam inactive: exit ${rc}: $(cat "${STATE}/stderr")"
[[ -f "${T}/home/.local/state/microos-lepton/lepton-install-requested" ]] \
    || fail "Steam inactive: the flag is not written"
grep -q "start" "${STATE}/calls" && fail "Steam inactive: something was started: $(cat "${STATE}/calls")"
grep -q "is-active" "${STATE}/calls" || fail "Steam inactive: the Steam session was not checked"

reset
mkdir -p "${T}/home/.local/state/microos-lepton"
echo old > "${T}/home/.local/state/microos-lepton/lepton-install-requested"
run
[[ "${rc}" == 0 && ! -s "${T}/home/.local/state/microos-lepton/lepton-install-requested" ]] \
    || fail "an older flag: not emptied: $(cat "${T}/home/.local/state/microos-lepton/lepton-install-requested")"

reset
: > "${STATE}/steam-active"
: > "${STATE}/start-fails"
run
[[ "${rc}" == 0 ]] || fail "a failed start: exit ${rc}, the flag is the contract"
grep -q "cannot start microos-lepton-install.service" "${STATE}/stderr" || fail "a failed start: no message: $(cat "${STATE}/stderr")"
[[ -f "${T}/home/.local/state/microos-lepton/lepton-install-requested" ]] || fail "a failed start: the flag lost"

[[ "${failures}" == 0 ]] || exit 1
echo "install-request-test: ok"
