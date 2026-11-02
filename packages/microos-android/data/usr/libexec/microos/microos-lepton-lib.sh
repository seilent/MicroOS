microos_me=${microos_me:-microos-lepton}

LEPTON_HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) || LEPTON_HOME=
LEPTON_HOME=${MICROOS_HOME:-${LEPTON_HOME:-${HOME}}}
LIBLEPTON="${MICROOS_LIBLEPTON:-/usr/libexec/microos/microos-liblepton.sh}"
REVIEWED="${MICROOS_LEPTON_REVIEWED:-/usr/share/microos-lepton/reviewed}"
STEAM_EMPTY="${MICROOS_STEAM_EMPTY:-/usr/share/microos-lepton/steam-empty}"
DISCOVERY="${MICROOS_LEPTON_STEAM_DIR_CMD:-/usr/libexec/microos/microos-lepton-steam}"
DATA="${MICROOS_ANDROID_DATA:-${LEPTON_HOME}/.local/share/microos-android}"
VALVE_HOME="${MICROOS_LEPTON_HOME:-${DATA}/home}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${LEPTON_HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${LEPTON_HOME}/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${LEPTON_HOME}/.local/state}"
SNAPSHOTS="${MICROOS_LEPTON_SNAPSHOTS:-${XDG_DATA_HOME}/microos-lepton/builds}"
RUN="${MICROOS_RUNTIME_DIR:-${XDG_RUNTIME_DIR}/microos-lepton}"
STATE_DIR="${MICROOS_ANDROID_STATE:-${XDG_STATE_HOME}/microos-android}"
SYSTEM_CARD="${MICROOS_SYSTEM_CARD:-/run/microos/system-card}"

say() { printf '%s: %s\n' "${microos_me}" "$*" >&2; }

android_data() {
    printf '%s\n' "${DATA}"
}

home() {
    printf '%s\n' "${LEPTON_HOME}"
}

legacy_contexts() {
    local old=play
    printf '%s\n' "$(home)/.local/share/lepton/contexts/microemu-${old}" \
        "$(home)/.local/share/microemu/android/home/.local/share/lepton/contexts/microemu-${old}"
}

fail() {
    say "$*"
    exit 1
}

paths() {
    find . -mindepth 1 \( -path ./images/rootfs -o -path ./sysbake -o -path ./LICENSES \
        -o -path ./LICENSE.md -o -path ./README.md -o -path ./images/NOTICE.txt \) -prune \
        -o \( -type f -o -type l \) -printf '%P\n'
    printf '%s\n' images/rootfs/system/build.prop images/rootfs/system/etc/prop.default \
        images/rootfs/vendor/odm/etc/build.prop sysbake/system/packages.xml
}

entry() {
    local base=$1 path=$2 target
    if [[ -L "${base}/${path}" ]]; then
        target=$(readlink "${base}/${path}") || return 1
        printf 'link  %s  %s\n' "${path}" "${target}"
    elif [[ -f "${base}/${path}" ]]; then
        printf '%s  %s\n' "$(sha256sum < "${base}/${path}" | cut -d' ' -f1)" "${path}"
    else
        printf 'missing  %s\n' "${path}"
    fi
}

gate_error=

gate() {
    local runtime=$1 buildid=$2 block sums
    gate_error=
    block="${REVIEWED}/${buildid}"
    if [[ -z "${buildid}" || ! -f "${block}" || -L "${block}" ]]; then
        gate_error="Lepton build ${buildid} is not one MicroOS knows, refusing"
        return 1
    fi
    if [[ ! -d "${runtime}/images/rootfs" || -L "${runtime}/images/rootfs" \
        || ! -d "${runtime}/sysbake" || -L "${runtime}/sysbake" ]]; then
        gate_error="Lepton in ${runtime} has no images/rootfs or sysbake directory, refusing"
        return 1
    fi
    if [[ "$(sed -n 's/^ro\.build\.version\.sdk=//p' "${runtime}/images/rootfs/system/build.prop" 2>/dev/null)" != 30 ]]; then
        gate_error="Lepton in ${runtime} is not Android SDK 30, refusing"
        return 1
    fi
    sums=$(cd "${runtime}" && paths | LC_ALL=C sort | while IFS= read -r path; do entry "${runtime}" "${path}"; done) || :
    if [[ "${sums}" != "$(cat "${block}")" ]]; then
        gate_error="Lepton in ${runtime} is not the build in ${block}, refusing"
        return 1
    fi
}

reviewed_snapshots() {
    local dir buildid
    for dir in "${SNAPSHOTS}"/*; do
        [[ -d "${dir}" && ! -L "${dir}" ]] || continue
        buildid=${dir##*/}
        [[ "${buildid}" =~ ^[0-9]+$ ]] || continue
        [[ -f "${REVIEWED}/${buildid}" && ! -L "${REVIEWED}/${buildid}" ]] || continue
        printf '%s\n' "${dir}"
    done
}

reviewed_elsewhere() {
    local root=${1:-} status commit listing dir rc
    if [[ -n "${root}" ]]; then
        for dir in "${root}"/ostree/deploy/*/deploy/*/usr/share/microos-lepton/reviewed; do
            [[ -d "${dir}" && ! -L "${dir}" ]] || continue
            for listing in "${dir}"/*; do
                [[ -f "${listing}" && ! -L "${listing}" ]] || continue
                [[ "${listing##*/}" =~ ^[0-9]+$ ]] || continue
                printf '%s\n' "${listing##*/}"
            done
        done
    fi
    command -v ostree > /dev/null 2>&1 || return 0
    status=$(ostree admin status --json 2>/dev/null) || {
        say "cannot list the deployments, judging snapshots by the booted one"
        return 1
    }
    for commit in $(python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for item in data.get("deployments", []):
    commit = item.get("checksum")
    if isinstance(commit, str):
        print(commit)' <<< "${status}" 2>/dev/null); do
        [[ "${commit}" =~ ^[0-9a-f]{64}$ ]] || continue
        listing=$(ostree ls "${commit}" /usr/share/microos-lepton/reviewed 2>/dev/null) || {
            say "cannot list ${commit}, judging snapshots by the booted one"
            return 1
        }
        awk '{ print $NF }' <<< "${listing}" | grep -E '^[0-9]+$' || :
    done
    return 0
}

prune_snapshots() {
    local current=$1 dir build previous="" elsewhere rc=0
    [[ "${MICROOS_LEPTON_READ_ONLY:-}" != 1 ]] || return 0
    elsewhere=$(reviewed_elsewhere "${MICROOS_SYSROOT:-/sysroot}") || rc=$?
    if (( rc )); then
        say "a deployment's reviewed list is unreadable, no snapshot pruned"
        return 0
    fi
    for dir in $(reviewed_snapshots); do
        [[ "${dir}" != "${current}" ]] || continue
        build=${dir##*/}
        grep -qxF "${build}" <<< "${elsewhere}" && continue
        if [[ -z "${previous}" || "${build}" -gt "${previous##*/}" ]]; then
            previous=${dir}
        fi
    done
    for dir in $(reviewed_snapshots); do
        [[ "${dir}" != "${current}" && "${dir}" != "${previous}" ]] || continue
        build=${dir##*/}
        grep -qxF "${build}" <<< "${elsewhere}" && continue
        rm -rf "${dir:?}" || say "cannot remove the old snapshot ${dir}"
    done
}

manifest_value() {
    sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$2" 2>/dev/null
}

steam_dir=
steam_buildid=
steam_manifest=
steam_error=

steam_look() {
    steam_dir=
    steam_buildid=
    steam_error=
    steam_dir=$("${DISCOVERY}" 2>/dev/null) && [[ "${steam_dir}" == */steamapps/common/Lepton && -d "${steam_dir}" ]] \
        || return 1
    steam_manifest="${steam_dir%/common/Lepton}/appmanifest_3029110.acf"
    [[ "$(manifest_value StateFlags "${steam_manifest}")" == 4 ]] || return 1
    steam_buildid=$(manifest_value buildid "${steam_manifest}")
    [[ -n "${steam_buildid}" ]] || return 1
    if [[ ! -f "${REVIEWED}/${steam_buildid}" || -L "${REVIEWED}/${steam_buildid}" ]]; then
        steam_error="Lepton build ${steam_buildid} is not one MicroOS knows, refusing"
        return 2
    fi
    gate "${steam_dir}" "${steam_buildid}" || { steam_error=${gate_error}; return 2; }
    [[ ! -e "${SNAPSHOTS}/${steam_buildid}" ]] || return 1
    return 0
}

snapshot_marker() {
    printf '%s/.verified.%s\n' "${SNAPSHOTS}" "$1"
}

write_marker() {
    local dir=$1 name=${2:-}
    local marker
    [[ -n "${name}" ]] || name=${dir##*/}
    marker=$(snapshot_marker "${name}")
    printf 'rootfs=%s\n' "$(rootfs_identity "${dir}" 2>/dev/null)" > "${marker}.new" \
        && chmod 0644 "${marker}.new" && mv -T "${marker}.new" "${marker}"
}

verified() {
    local dir=$1 marker stamp identity
    marker=$(snapshot_marker "${dir##*/}")
    [[ ! -L "${marker}" ]] || return 1
    [[ -f "${marker}" ]] || return 2
    grep -q '^rootfs=' "${marker}" 2>/dev/null || return 1
    stamp=$(stamp_identity "${marker}") || return 1
    [[ -n "${stamp}" ]] || return 3
    identity=$(rootfs_identity "${dir}" 2>/dev/null) || return 1
    [[ "${stamp}" == "${identity}" ]] || return 1
}

confirmed() {
    local rc=0
    verified "$1" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        2|3) gate "$1" "${1##*/}" ;;
        *) return 1 ;;
    esac
}

clean_temps() {
    local lock
    mkdir -p "${SNAPSHOTS}" 2>/dev/null || :
    if [[ -d "${SNAPSHOTS}" ]]; then
        exec {lock}<>"${SNAPSHOTS}/.lock" || { say "cannot open ${SNAPSHOTS}/.lock, no temp removed"; return 0; }
        if ! flock -n -x "${lock}"; then
            exec {lock}<&-
            say "a snapshot is being taken, no temp removed"
            return 0
        fi
        clean_temps_locked
        exec {lock}<&-
        return 0
    fi
    clean_temps_locked
}

clean_temps_locked() {
    local entry
    for entry in "${SNAPSHOTS}"/.take.* "${SNAPSHOTS}"/.prepare.* "${SNAPSHOTS}"/.verified.*.new; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        rm -rf "${entry:?}" || say "cannot remove the leftover ${entry}"
    done
    for entry in "${DATA}"/backups/*.part; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        podman unshare rm -rf "${entry:?}" || say "cannot remove the leftover ${entry}"
    done
}

snapshot() {
    local src=$1 buildid=$2 dest="${SNAPSHOTS}/${2}" dir fs
    mkdir -p "${SNAPSHOTS}" || fail "cannot make ${SNAPSHOTS}"
    for fs in "${src}" "${SNAPSHOTS}"; do
        [[ -d "${fs}" && ! -L "${fs}" ]] || fail "${fs} is not a directory, refusing"
    done
    for fs in "${SNAPSHOTS}"/.take.*; do
        [[ -e "${fs}" ]] || continue
        rm -rf "${fs:?}" || say "cannot remove the leftover ${fs}"
    done
    dir="${SNAPSHOTS}/.take.$$"
    rm -rf "${dir:?}" 2>/dev/null || :
    if ! cp -a --reflink=auto "${src}" "${dir}"; then
        rm -rf "${dir:?}"
        fail "cannot copy ${src} into ${SNAPSHOTS}, refusing"
    fi
    [[ "$(stat -c %d "${src}")" == "$(stat -c %d "${SNAPSHOTS}")" ]] || say "${src} is on another filesystem, copied it in full"
    for fs in "${dir}" "${dir}/sysbake" "${dir}/liblepton"; do
        if ! { setfattr -n user.microos -v 1 "${fs}" && setfattr -x user.microos "${fs}"; } 2>/dev/null; then
            rm -rf "${dir:?}"
            fail "${SNAPSHOTS} keeps no xattrs, refusing"
        fi
    done
    if ! gate "${dir}" "${buildid}"; then
        rm -rf "${dir:?}"
        fail "${gate_error}"
    fi
    if [[ -n "${steam_manifest:-}" ]] && { [[ "$(manifest_value buildid "${steam_manifest}")" != "${buildid}" ]] \
        || [[ "$(manifest_value StateFlags "${steam_manifest}")" != 4 ]]; }; then
        rm -rf "${dir:?}"
        fail "Lepton in ${src} changed while it was copied, refusing"
    fi
    sync
    write_marker "${dir}" "${buildid}" || say "cannot write the verified marker of ${dest}"
    rm -rf "${dest:?}" 2>/dev/null || :
    mv -T "${dir}" "${dest}" || { rm -rf "${dir:?}"; fail "cannot move the snapshot into ${dest}, refusing"; }
    say "took the snapshot ${dest}"
    prune_snapshots "${dest}"
}

take_from_steam() {
    local lock
    mkdir -p "${SNAPSHOTS}" || fail "cannot make ${SNAPSHOTS}"
    exec {lock}<>"${SNAPSHOTS}/.lock" || fail "cannot open ${SNAPSHOTS}/.lock"
    flock -w 600 -x "${lock}" || fail "cannot lock ${SNAPSHOTS}/.lock"
    steam_look || :
    if [[ -n "${steam_buildid}" && ! -e "${SNAPSHOTS}/${steam_buildid}" ]] \
        && steam_look && [[ -z "${steam_error}" ]]; then
        snapshot "${steam_dir}" "${steam_buildid}"
    fi
    exec {lock}<&-
}

resolve() {
    local dir found="" rc=0 other=0 newer="" marker stale=()
    for dir in $(reviewed_snapshots); do
        if [[ -L "$(snapshot_marker "${dir##*/}")" ]]; then
            say "the verified marker of ${dir} is a link, refusing it"
            other=1
            continue
        fi
        if ! gate "${dir}" "${dir##*/}"; then
            say "${gate_error}"
            if [[ "${MICROOS_LEPTON_READ_ONLY:-}" == 1 ]]; then
                say "a read only run leaves the bad snapshot ${dir}"
            else
                rm -rf "${dir:?}" || say "cannot remove the bad snapshot ${dir}"
                marker=$(snapshot_marker "${dir##*/}")
                [[ ! -e "${marker}" ]] || stale+=("${marker}")
            fi
            continue
        fi
        rc=0
        verified "${dir}" || rc=$?
        case "${rc}" in
            0) ;;
            2)
                if [[ "${MICROOS_LEPTON_READ_ONLY:-}" == 1 ]]; then
                    say "${dir} has no verified marker, a read only run leaves it"
                else
                    say "${dir} has no verified marker yet, writing it"
                    write_marker "${dir}" || say "cannot write the verified marker of ${dir}"
                fi
                ;;
            3)
                if [[ "${MICROOS_LEPTON_READ_ONLY:-}" == 1 ]]; then
                    say "${dir} has a verified marker with no rootfs identity, a read only run leaves it"
                else
                    say "${dir} has a verified marker with no rootfs identity, writing it"
                    write_marker "${dir}" || say "cannot write the verified marker of ${dir}"
                fi
                ;;
            *)
                say "${dir} is not the snapshot its verified marker names, refusing it"
                other=1
                continue
                ;;
        esac
        if [[ -z "${found}" || "${dir##*/}" -gt "${found##*/}" ]]; then
            found=${dir}
        fi
    done
    for marker in "${stale[@]}"; do
        rm -f "${marker}" || say "cannot remove the stale marker ${marker}"
    done
    rc=0
    steam_look || rc=$?
    (( rc == 0 )) && newer=1
    (( rc == 2 )) && other=1
    if (( ! other )) && [[ -n "${found}" ]] && { [[ -z "${newer}" ]] || [[ "${found##*/}" -ge "${steam_buildid}" ]]; }; then
        prune_snapshots "${found}"
        printf '%s\n' "${found}"
        return 0
    fi
    if [[ -n "${steam_buildid}" && ! -e "${SNAPSHOTS}/${steam_buildid}" && "${rc}" != 2 \
        && "${MICROOS_LEPTON_READ_ONLY:-}" != 1 ]]; then
        take_from_steam
        if [[ -e "${SNAPSHOTS}/${steam_buildid}" ]]; then
            found="${SNAPSHOTS}/${steam_buildid}"
        fi
    fi
    if [[ -z "${found}" && "${MICROOS_LEPTON_READ_ONLY:-}" == 1 && -n "${newer}" ]]; then
        found=${steam_dir}
    fi
    [[ -n "${found}" ]] || fail "${steam_error:-Lepton is not installed. Install it in Steam.}"
    prune_snapshots "${found}"
    printf '%s\n' "${found}"
}

rootfs_identity() {
    local runtime=$1 version fingerprint props
    version=$(cat "${runtime}/images/version.txt" 2>/dev/null) || return 1
    [[ -n "${version}" ]] || return 1
    props="${runtime}/images/rootfs/system/build.prop"
    fingerprint=$(sed -n 's/^ro\.system\.build\.fingerprint=//p' "${props}" 2>/dev/null | head -n 1) || return 1
    if [[ -z "${fingerprint}" ]]; then
        fingerprint=$(sed -n 's/^ro\.build\.fingerprint=//p' "${props}" 2>/dev/null | head -n 1) || return 1
    fi
    [[ -n "${fingerprint}" ]] || return 1
    printf '%s %s\n' "${version}" "${fingerprint}"
}

stamp_identity() {
    [[ -f "$1" ]] || return 1
    sed -n 's/^rootfs=//p' "$1" 2>/dev/null | head -n 1
}

identity_older() {
    local stamp_identity=$1 runtime_identity=$2 stamp_version runtime_version
    [[ -n "${stamp_identity}" && -n "${runtime_identity}" ]] || return 1
    stamp_version=${stamp_identity%% *}
    runtime_version=${runtime_identity%% *}
    [[ "${stamp_version}" != "${runtime_version}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${stamp_version}" "${runtime_version}" | sort -V | head -n 1)" == "${runtime_version}" ]]
}

word_ok() {
    [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

boottime_ms() {
    local up
    read -r up _ < /proc/uptime 2>/dev/null || return 1
    [[ "${up}" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$(( 10#${up%.*} * 1000 + 10#${up#*.} * 10 ))"
}

write_reason() {
    local run=$1 reason=$2
    word_ok "${reason}" || return 1
    mkdir -p "${run}" || return 1
    printf '%s\n' "${reason}" > "${run}/end-reason.new" && mv -T "${run}/end-reason.new" "${run}/end-reason"
}

state_lock() {
    local lock="${STATE_DIR}/state.json.lock" fd
    if [[ ! -d "${STATE_DIR}" ]]; then
        mkdir -p "${STATE_DIR}" || return 1
        chmod 700 "${STATE_DIR}" || return 1
    fi
    exec {fd}>>"${lock}" || return 1
    if ! flock -w 10 -x "${fd}"; then
        exec {fd}>&-
        say "${lock} is held, writing anyway"
        return 0
    fi
    state_lock_fd=${fd}
}

state_unlock() {
    [[ -z "${state_lock_fd:-}" ]] || exec {state_lock_fd}>&-
    state_lock_fd=
}

state_write() {
    local file="${STATE_DIR}/state.json"
    state_lock || return 1
    python3 -I - "${file}" "$@" <<'PY' || { state_unlock; return 1; }
import json
import os
import sys
import tempfile

path = sys.argv[1]
data = {}
try:
    with open(path) as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        data = loaded
except (OSError, ValueError):
    data = {}
for item in sys.argv[2:]:
    if "=" not in item:
        sys.exit("state: no = in " + item)
    key, value = item.split("=", 1)
    parts = key.split(".")
    node = data
    for part in parts[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            child = {}
            node[part] = child
        node = child
    if key == "last.boottime":
        try:
            value = int(value)
        except ValueError:
            sys.exit("state: last.boottime is not a number: " + value)
    node[parts[-1]] = value
directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".state.")
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    state_unlock
}

state_get() {
    python3 -I - "$(state_file)" "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
for part in sys.argv[2].split("."):
    if not isinstance(data, dict):
        sys.exit(1)
    data = data.get(part)
    if data is None:
        sys.exit(1)
if isinstance(data, bool) or not isinstance(data, (str, int)):
    sys.exit(1)
print(data)
PY
}

state_file() {
    printf '%s\n' "${STATE_DIR}/state.json"
}

state_init() {
    [[ -d "${STATE_DIR}" ]] || mkdir -p "${STATE_DIR}" || return 1
    chmod 700 "${STATE_DIR}" 2>/dev/null || :
    [[ -f "${STATE_DIR}/state.json" ]] && return 0
    state_write "lepton.build=" "lepton.source=" "last.result=" "last.reason=" "last.boottime=0" \
        "gapps.set=" "gapps.gms=" "gapps.play=" "gapps.setup=" "gsf_id=" "keyboard="
}

lepton_live() {
    local status
    status=$(podman inspect --type container -f '{{.State.Status}}' lepton-android 2>/dev/null) || status=
    case "${status}" in
        running|paused|stopping) return 0 ;;
    esac
    return 1
}

lepton_exited() {
    local status
    status=$(podman inspect --type container -f '{{.State.Status}}' lepton-android 2>/dev/null) || return 1
    [[ "${status}" == exited ]]
}

context_backup() {
    local runtime=$1 context=$2 buildid backup old
    buildid=${runtime##*/}
    backup="${DATA}/backups/${context##*/}.pre-${buildid}.bak"
    if [[ -e "${backup}.part" || -L "${backup}.part" ]]; then
        podman unshare rm -rf "${backup}.part" || fail "cannot remove ${backup}.part, refusing"
    fi
    if [[ -d "${context}" && ! -L "${context}" && ! -e "${backup}" ]]; then
        [[ ! -L "${DATA}/backups" ]] || fail "${DATA}/backups is a link, refusing"
        mkdir -p "${DATA}/backups" || fail "cannot make ${DATA}/backups"
        if ! podman unshare cp -a --reflink=auto "${context}" "${backup}.part"; then
            podman unshare rm -rf "${backup}.part" || :
            fail "cannot snapshot ${context} into ${backup}, refusing"
        fi
        mv -T "${backup}.part" "${backup}" || fail "cannot move the backup into ${backup}, refusing"
        for old in "${DATA}/backups/${context##*/}.pre-"*.bak; do
            [[ "${old}" != "${backup}" ]] || continue
            [[ "${old##*/}" =~ ^${context##*/}\.pre-[0-9]+\.bak$ ]] || continue
            podman unshare rm -rf "${old:?}" || say "cannot remove the old backup ${old}"
        done
        say "kept ${backup}"
    fi
}
