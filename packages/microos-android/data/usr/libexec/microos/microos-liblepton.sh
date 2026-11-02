microos_say() { printf 'microos-liblepton: %s\n' "$*" >&2; }

microos_refuse() {
    microos_say "$*"
    if [[ -n "${microos_prefix:-}" ]]; then
        rm -rf "${microos_prefix:?}"
    fi
    exit 1
}

if [[ "${MICROOS_LEPTON_RUNTIME:-}" != /* || ! -f "${MICROOS_LEPTON_RUNTIME}/liblepton/liblepton.sh" ]]; then
    microos_say "no Lepton runtime in MICROOS_LEPTON_RUNTIME (${MICROOS_LEPTON_RUNTIME:-unset}), refusing"
    exit 1
fi
microos_lepton=$(readlink -f "${MICROOS_LEPTON_RUNTIME}/lepton")
if [[ "$(readlink -f "$0")" != "${microos_lepton}" || "$(readlink "/proc/$$/fd/255")" != "${microos_lepton}" ]]; then
    microos_say "$0 is not ${MICROOS_LEPTON_RUNTIME}/lepton, refusing"
    exit 1
fi
unset microos_lepton
if [[ "${COMMAND:-}" != start || $# -ne 2 ]]; then
    microos_say "only start <context> runs through MicroOS, refusing ${*:-help}"
    exit 1
fi
for microos_var in SteamAppId STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_LIBRARY_PATHS STEAM_COMPAT_SHADER_PATH LEPTON_PREFIX \
    $(compgen -v LEPTON_ENV_ || true); do
    if [[ -v "${microos_var}" ]]; then
        microos_say "${microos_var} is set, refusing"
        exit 1
    fi
done
unset microos_var
case "${LEPTON_CONTEXT:-}" in
    dev|sysbake|steamlaunch-*)
        microos_say "${LEPTON_CONTEXT} is a context name Lepton treats specially, refusing"
        exit 1
        ;;
esac
if [[ ! "${LEPTON_CONTEXT:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    microos_say "bad context name ${LEPTON_CONTEXT:-}, refusing"
    exit 1
fi
microos_home=$(getent passwd "$(id -u)" | cut -d: -f6)
if [[ "$(readlink -m "${HOME}")" == "$(readlink -m "${microos_home:-/}")" ]]; then
    microos_say "HOME is the home of $(id -un), refusing"
    exit 1
fi
unset microos_home
if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" \
    && "${STEAM_COMPAT_DATA_PATH}" != "${HOME}/.local/share/lepton/contexts/${LEPTON_CONTEXT#headless-}" ]]; then
    microos_say "STEAM_COMPAT_DATA_PATH is not ${HOME}/.local/share/lepton/contexts/${LEPTON_CONTEXT#headless-}, refusing"
    exit 1
fi
if compgen -G "${HOME}/.local/share/Steam/steamapps/appmanifest_*.acf" >/dev/null; then
    microos_say "${HOME}/.local/share/Steam/steamapps holds app manifests, refusing"
    exit 1
fi
microos_context=${LEPTON_CONTEXT}
microos_data=${STEAM_COMPAT_DATA_PATH:-}
microos_reviewed="${MICROOS_LEPTON_REVIEWED:-/usr/share/microos-lepton/reviewed}"
microos_buildid=${MICROOS_LEPTON_RUNTIME##*/}
microos_block=${microos_reviewed}/${microos_buildid}
if [[ "${microos_reviewed}" != /* || ! -d "${microos_reviewed}" \
    || ! -f "${microos_block}" || -L "${microos_block}" ]]; then
    microos_say "Lepton build ${microos_buildid} is not one MicroOS knows, refusing"
    exit 1
fi
if [[ ! -d "${MICROOS_LEPTON_RUNTIME}/images/rootfs" || -L "${MICROOS_LEPTON_RUNTIME}/images/rootfs" \
    || ! -d "${MICROOS_LEPTON_RUNTIME}/sysbake" || -L "${MICROOS_LEPTON_RUNTIME}/sysbake" ]]; then
    microos_say "Lepton in ${MICROOS_LEPTON_RUNTIME} has no images/rootfs or sysbake directory, refusing"
    exit 1
fi
if [[ "$(sed -n 's/^ro\.build\.version\.sdk=//p' "${MICROOS_LEPTON_RUNTIME}/images/rootfs/system/build.prop" 2>/dev/null)" != 30 ]]; then
    microos_say "Lepton in ${MICROOS_LEPTON_RUNTIME} is not Android SDK 30, refusing"
    exit 1
fi
microos_paths() {
    find . -mindepth 1 \( -path ./images/rootfs -o -path ./sysbake -o -path ./LICENSES \
        -o -path ./LICENSE.md -o -path ./README.md -o -path ./images/NOTICE.txt \) -prune \
        -o \( -type f -o -type l \) -printf '%P\n'
    printf '%s\n' images/rootfs/system/build.prop images/rootfs/system/etc/prop.default \
        images/rootfs/vendor/odm/etc/build.prop sysbake/system/packages.xml
}
microos_entry() {
    local microos_target
    if [[ -L "${MICROOS_LEPTON_RUNTIME}/$1" ]]; then
        microos_target=$(readlink "${MICROOS_LEPTON_RUNTIME}/$1") || return 1
        printf 'link  %s  %s\n' "$1" "${microos_target}"
    elif [[ -f "${MICROOS_LEPTON_RUNTIME}/$1" ]]; then
        printf '%s  %s\n' "$(sha256sum < "${MICROOS_LEPTON_RUNTIME}/$1" | cut -d' ' -f1)" "$1"
    else
        printf 'missing  %s\n' "$1"
    fi
}
microos_entries=$(cd "${MICROOS_LEPTON_RUNTIME}" && microos_paths | LC_ALL=C sort \
    | while IFS= read -r microos_path; do microos_entry "${microos_path}"; done)

if [[ "${microos_entries}" != "$(cat "${microos_block}")" ]]; then
    microos_say "Lepton in ${MICROOS_LEPTON_RUNTIME} is not the build in ${microos_block}, refusing"
    exit 1
fi
unset microos_entries microos_reviewed microos_buildid microos_block microos_path
microos_rc=0
podman container exists "lepton-${LEPTON_CONTEXT}" 2>/dev/null || microos_rc=$?
case "${microos_rc}" in
    1) ;;
    0)
        microos_label=$(podman inspect --type container -f '{{ index .Config.Labels "STEAM_COMPAT_DATA_PATH" }}' \
            "lepton-${LEPTON_CONTEXT}" 2>/dev/null) || microos_label=
        if [[ -z "${microos_label}" || "${microos_label}" != "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            microos_say "lepton-${LEPTON_CONTEXT} belongs to ${microos_label:-another flow}, refusing"
            exit 1
        fi
        microos_running=$(podman inspect --type container -f '{{.State.Running}}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null) \
            || microos_running=
        if [[ "${microos_running}" != false ]]; then
            microos_say "lepton-${LEPTON_CONTEXT} runs, refusing"
            exit 1
        fi
        ;;
    *)
        microos_say "podman container exists failed (rc=${microos_rc}), refusing"
        exit 1
        ;;
esac
unset microos_rc microos_label microos_running

source "${MICROOS_LEPTON_RUNTIME}/liblepton/liblepton.sh"

for microos_fn in setup_mounts setup_props prepare_baked_data_for_removal clear_baked_app_data cleanup_container \
    cleanup_all kill_all wipe_baked_system_data podman_network_options get_baked_app_data_dir data_mount_path \
    kill_container podman_ip podman_subnet adb_port create_prefix setup_podman_mounts setup_podman_base \
    onexit_path determine_app; do
    if ! declare -F "${microos_fn}" >/dev/null; then
        microos_say "Lepton in ${MICROOS_LEPTON_RUNTIME} has no ${microos_fn}, refusing"
        exit 1
    fi
done
unset microos_fn

LEPTON_DATA_DIR="${HOME}/.local/share/lepton/contexts"
APK_AUTO_INSTALL_DIR=/dev/null/microos
MDNS_PUBLISH_PATH=/bin/false
STEAMVR_LOGS_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/microos-lepton/steamvr-logs"
mkdir -p "${STEAMVR_LOGS_DIR}" || microos_refuse "cannot make ${STEAMVR_LOGS_DIR}, refusing"
microos_prefix=
microos_run="${MICROOS_RUNTIME_DIR:-${XDG_RUNTIME_DIR}/microos-android}"
microos_run="${microos_run%/}"

microos_record_prefix() {
    local tmp
    mkdir -p "${microos_run}" || { microos_say "cannot make ${microos_run}, ${1} goes unrecorded"; return 0; }
    tmp=$(mktemp "${microos_run}/lepton-prefix.XXXXXX") || { microos_say "cannot record ${1} in ${microos_run}"; return 0; }
    if printf '%s\n' "$1" > "${tmp}" && mv -T "${tmp}" "${microos_run}/lepton-prefix"; then
        return 0
    fi
    rm -f "${tmp}"
    microos_say "cannot record ${1} in ${microos_run}"
}

eval "microos_valve_$(declare -f create_prefix)"
create_prefix() {
    local had="${LEPTON_PREFIX:-}"
    microos_valve_create_prefix "$@"
    [[ -n "${had}" ]] || microos_prefix=${LEPTON_PREFIX:-}
    [[ -z "${microos_prefix}" ]] || microos_record_prefix "${microos_prefix}"
}

microos_holds_files() {
    local rc=0
    podman unshare bash -c '[[ -L "$1" || ! -e "$1" ]] && exit 1; [[ -d "$1" ]] || exit 0; c=$(ls -A -- "$1") || exit 2
        [[ -n "${c}" ]]' _ "$1" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        1) return 1 ;;
        *) microos_refuse "cannot read $1 (rc=${rc}), refusing" ;;
    esac
}

microos_no_guest() {
    local running
    running=$(podman ps --filter label=lepton=true --format '{{.Names}}') \
        || microos_refuse "cannot list the running Lepton containers, refusing"
    if [[ -n "${running}" ]]; then
        microos_refuse "${running//$'\n'/ } runs, refusing"
    fi
}

microos_check_context() {
    local data baked ctx path pair host guest external target client entries
    data=$(data_mount_path)
    baked=${data%/data_overlay}
    ctx=${baked%/baked}
    for path in "${ctx}" "${ctx}/internal" "${ctx}/external" "${ctx}/media0" "${baked}" "${baked}/data_workdir" \
        "${baked}/app_workdir" "${baked}/app_overlay" "${baked}/app_lowerdir" "${data}" "${data}/media" "${data}/misc" \
        "${data}/misc/adb" "${data}/misc/ethernet" "${data}/misc/ethernet/ipconfig.txt" "${data}/steamvr" \
        "${data}/steamvr/runtime" "${data}/steam_app"; do
        if [[ -L "${path}" ]]; then
            microos_refuse "${path} is a link, refusing"
        fi
    done
    client=${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}
    if [[ -n "${client}" ]] && ! { [[ -d "${client}" && ! -L "${client}" ]] \
        && entries=$(find "${client}" -mindepth 1 -print -quit) && [[ -z "${entries}" ]]; }; then
        microos_refuse "STEAM_COMPAT_CLIENT_INSTALL_PATH ${client} is not an empty directory, refusing"
    fi
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        external="${STEAM_COMPAT_DATA_PATH}/external"
        [[ -d "${external}" ]] || external="${STEAM_COMPAT_DATA_PATH}/media0"
        for pair in Documents:Documents Downloads:Download Videos:Movies; do
            host="${HOME}/${pair%%:*}"
            guest="${external}/${pair#*:}"
            if [[ -d "${host}" ]] && microos_holds_files "${guest}"; then
                microos_refuse "Lepton replaces ${guest} with a link to ${host} at start, move what it holds into ${host} first"
            fi
        done
        target="into ${STEAM_COMPAT_DATA_PATH}/external"
    else
        target="out of ${ctx}"
    fi
    if microos_holds_files "${data}/media/0"; then
        microos_refuse "Lepton deletes ${data}/media/0 at start, move what it holds ${target} first"
    fi
}

microos_narrow_bind() {
    local i found=0 external bind="type=bind,source=${LEPTON_DATA_DIR},destination=${LEPTON_DATA_DIR},rw"
    local -a cmdline=()
    for (( i = 0; i < ${#PODMAN_CMDLINE[@]}; i++ )); do
        if [[ "${PODMAN_CMDLINE[i]}" == --mount && "${PODMAN_CMDLINE[i + 1]:-}" == "${bind}" ]]; then
            found=$((found + 1))
            i=$((i + 1))
            if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
                external="${STEAM_COMPAT_DATA_PATH}/external"
                cmdline+=(--mount "type=bind,source=${external},destination=${external},rw")
            fi
        else
            cmdline+=("${PODMAN_CMDLINE[i]}")
        fi
    done
    (( found == 1 )) || microos_refuse "Lepton binds ${LEPTON_DATA_DIR} ${found} times, not once, refusing"
    PODMAN_CMDLINE=("${cmdline[@]}")
}

microos_cmd_mount() {
    [[ "$1" =~ (^|[=:])/system/bin/cmd([,:@]|$) ]]
}

microos_guest_cmd() {
    local i part joined bind element guest="${MICROOS_GUEST_CMD:-/usr/share/microos-android/cmd}"
    local found=0 is_cmd=0 swapped=0 mentions=0
    local -a cmdline=() parts=()
    if [[ ! -f "${guest}" ]]; then
        microos_refuse "the guest cmd ${guest} is not a regular file, refusing"
    fi
    if [[ -e /usr/share/guestos/android/system/bin/cmd ]]; then
        microos_refuse "/usr/share/guestos/android/system/bin/cmd is a second guest cmd, refusing"
    fi
    for (( i = 0; i < ${#PODMAN_CMDLINE[@]}; i++ )); do
        if [[ "${PODMAN_CMDLINE[i]}" != --mount ]]; then
            cmdline+=("${PODMAN_CMDLINE[i]}")
            continue
        fi
        i=$((i + 1))
        bind=${PODMAN_CMDLINE[i]:-}
        parts=()
        IFS=, read -ra parts <<< "${bind}"
        is_cmd=0
        swapped=0
        joined=
        for part in "${parts[@]}"; do
            case "${part}" in
                destination=/system/bin/cmd)
                    is_cmd=1
                    ;;
                source=*)
                    part="source=${guest}"
                    swapped=1
                    ;;
            esac
            joined+=${joined:+,}${part}
        done
        if (( is_cmd && ! swapped )); then
            microos_refuse "Lepton binds /system/bin/cmd with no source=, refusing"
        fi
        if (( is_cmd )); then
            found=$((found + 1))
            cmdline+=(--mount "${joined}")
        else
            cmdline+=(--mount "${bind}")
        fi
    done
    for element in "${cmdline[@]}"; do
        if microos_cmd_mount "${element}"; then
            mentions=$((mentions + 1))
        fi
    done
    (( mentions == 1 )) || microos_refuse "Lepton binds /system/bin/cmd ${mentions} times, not once, refusing"
    (( found == mentions )) || microos_refuse "Lepton binds /system/bin/cmd in a form MicroOS does not rewrite, refusing"
    PODMAN_CMDLINE=("${cmdline[@]}")
}

microos_podman_mounts() {
    local i bind shm=0 runtime=0 logs=0
    local -a cmdline=()
    for (( i = 0; i < ${#PODMAN_CMDLINE[@]}; i++ )); do
        if [[ "${PODMAN_CMDLINE[i]}" != --mount ]]; then
            cmdline+=("${PODMAN_CMDLINE[i]}")
            continue
        fi
        i=$((i + 1))
        bind=${PODMAN_CMDLINE[i]:-}
        case "${bind}" in
            type=bind,source=/dev/shm,destination=/dev/shm,rw)
                shm=$((shm + 1))
                cmdline+=(--tmpfs "/dev/shm:rw,nosuid,nodev,noexec")
                ;;
            type=bind,source=*,destination=/data/steamvr/runtime,rw)
                runtime=$((runtime + 1))
                cmdline+=(--mount "${bind%,rw},ro")
                ;;
            "type=bind,source=${STEAMVR_LOGS_DIR},destination=/data/steamvr/logs,rw")
                logs=$((logs + 1))
                ;;
            *)
                cmdline+=(--mount "${bind}")
                ;;
        esac
    done
    (( shm == 1 )) || microos_refuse "Lepton binds /dev/shm ${shm} times, not once, refusing"
    (( runtime == 1 )) || microos_refuse "Lepton binds /data/steamvr/runtime ${runtime} times, not once, refusing"
    (( logs == 1 )) || microos_refuse "Lepton binds ${STEAMVR_LOGS_DIR} ${logs} times, not once, refusing"
    PODMAN_CMDLINE=("${cmdline[@]}")
}

microos_same_start() {
    local var
    if [[ "${LEPTON_CONTEXT:-}" != "${microos_context}" || "${STEAM_COMPAT_DATA_PATH:-}" != "${microos_data}" ]]; then
        microos_refuse "Lepton switched to ${LEPTON_CONTEXT:-} on ${STEAM_COMPAT_DATA_PATH:-}, refusing"
    fi
    for var in SteamAppId STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_LIBRARY_PATHS STEAM_COMPAT_SHADER_PATH \
        $(compgen -v LEPTON_ENV_ || true); do
        if [[ -v "${var}" ]]; then
            microos_refuse "Lepton set ${var}, refusing"
        fi
    done
}

microos_audit_mounts() {
    local arg prev="" spec part conf source canonical ok data baked
    local -a parts sources=() allowed=()
    data=$(readlink -m "${LEPTON_DATA_DIR}")
    baked=$(get_baked_app_data_dir)
    for source in "${baked}/data_overlay" "${baked}/data_workdir" "${baked}/app_overlay" "${baked}/app_workdir" \
        "${baked}/app_lowerdir"; do
        allowed+=("$(readlink -m "${source}")")
    done
    if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        allowed+=("$(readlink -m "${STEAM_COMPAT_DATA_PATH}/external")")
    fi
    for arg in "${PODMAN_CMDLINE[@]}"; do
        case "${prev}" in
            -v|--volume)
                sources+=("${arg%%:*}")
                ;;
        esac
        case "${arg}" in
            -v=*|--volume=*)
                spec=${arg#*=}
                sources+=("${spec%%:*}")
                ;;
        esac
        IFS=, read -ra parts <<< "${arg}"
        for part in "${parts[@]}"; do
            case "${part}" in
                source=*|src=*|upperdir=*|workdir=*) sources+=("${part#*=}") ;;
            esac
        done
        prev=${arg}
    done
    if [[ -n "${CONTAINERS_CONF_OVERRIDE:-}" ]]; then
        conf=$(cat -- "${CONTAINERS_CONF_OVERRIDE}") || microos_refuse "cannot read ${CONTAINERS_CONF_OVERRIDE}, refusing"
        if grep -qE "^[[:space:]]*volumes[[:space:]]*=" <<< "${conf}"; then
            microos_refuse "${CONTAINERS_CONF_OVERRIDE} sets volumes, refusing"
        fi
        if grep -qE "['\\\\]" <<< "${conf}"; then
            microos_refuse "${CONTAINERS_CONF_OVERRIDE} holds a quote or a backslash, refusing"
        fi
        mapfile -t -O "${#sources[@]}" sources < <(grep -oE '(source|src|upperdir|workdir)=[^,"]*' <<< "${conf}" \
            | sed 's/^[a-z]*=//')
    fi
    for source in "${sources[@]}"; do
        canonical=$(readlink -m "${source}") || continue
        [[ "${canonical}" == "${data}" || "${data}" == "${canonical%/}/"* || "${canonical}" == "${data}/"* ]] || continue
        readlink -f "${source}" > /dev/null 2>&1 \
            || microos_refuse "Lepton binds ${source}, at, above or under ${LEPTON_DATA_DIR} and cannot be resolved, refusing"
        ok=0
        for arg in "${allowed[@]}"; do
            [[ "${canonical}" != "${arg}" ]] || ok=1
        done
        (( ok )) || microos_refuse "Lepton binds ${source}, at, above or under ${LEPTON_DATA_DIR}, refusing"
    done
}

microos_adb_keys() {
    local keys="${XDG_CONFIG_HOME:?}/microos-android/adb_keys" home
    [[ -f "${keys}" ]] || keys=/dev/null
    [[ "$1" == "${HOME}"/* ]] || microos_refuse "$1 is not under ${HOME}, refusing"
    home=$(cd -P "${HOME}" && pwd -P) || microos_refuse "cannot resolve ${HOME}, refusing"
    if ! podman unshare sh -c 'cd -P "$1" && [ "$(pwd -P)" = "$5" ] && for d in misc adb; do
            { [ -d "$d" ] && [ ! -L "$d" ]; } || mkdir "$d" && cd -P "$d" || exit 1
        done && chown -h "$2" . && chmod "$3" . && rm -f adb_keys.new && set -C && cat > adb_keys.new &&
        chown -h "$2" adb_keys.new && chmod "$4" adb_keys.new && mv -fT adb_keys.new adb_keys' \
        sh "$1" "$2" "$3" "$4" "${home}${1#"${HOME}"}" < "${keys}"; then
        microos_refuse "cannot write $1/misc/adb/adb_keys, refusing"
    fi
}

microos_cgroup_parent() {
    local i
    local -a cmdline=()
    for (( i = 0; i < ${#PODMAN_CMDLINE[@]}; i++ )); do
        case "${PODMAN_CMDLINE[i]}" in
            --cgroup-parent=*|-cgroup-parent=*)
                cmdline+=("--cgroup-parent=game-android.slice")
                ;;
            --cgroup-parent)
                cmdline+=("--cgroup-parent=game-android.slice")
                (( i + 1 < ${#PODMAN_CMDLINE[@]} )) && i=$((i + 1))
                ;;
            *) cmdline+=("${PODMAN_CMDLINE[i]}") ;;
        esac
    done
    PODMAN_CMDLINE=("${cmdline[@]}" --cgroup-parent=game-android.slice)
}

eval "microos_valve_$(declare -f setup_podman_base)"
setup_podman_base() {
    microos_valve_setup_podman_base "$@"
    microos_cgroup_parent
}

eval "microos_valve_$(declare -f determine_app)"
determine_app() {
    microos_valve_determine_app "$@"
    microos_same_start
}

eval "microos_valve_$(declare -f setup_mounts)"
setup_mounts() {
    microos_no_guest
    microos_same_start
    microos_check_context
    if [[ -z "${microos_prefix}" || "${LEPTON_PREFIX:-}" != "${microos_prefix}" ]]; then
        microos_refuse "LEPTON_PREFIX=${LEPTON_PREFIX:-} is not the prefix this start made, refusing"
    fi
    microos_valve_setup_mounts "$@"
    microos_narrow_bind
    microos_guest_cmd
}

eval "microos_valve_$(declare -f setup_podman_mounts)"
setup_podman_mounts() {
    microos_valve_setup_podman_mounts "$@"
    microos_podman_mounts
}

onexit_path() {
    printf '%s' "${SCRIPT_DIR}/lepton-on-app-exit"
}

eval "microos_valve_$(declare -f setup_props)"
setup_props() {
    microos_valve_setup_props "$@"
    microos_no_guest
    microos_audit_mounts
    microos_adb_keys "$(data_mount_path)" 0:0 0755 0644
}

prepare_baked_data_for_removal() {
    local baked dir context="${1:-${LEPTON_CONTEXT}}"
    baked=$(get_baked_app_data_dir "$@")
    [[ "${baked}" == /?*/baked && -d "${baked}" && ! -L "${baked}" ]] || return 0
    if [[ "$(podman inspect --type container -f '{{.State.Running}}' "lepton-${context}" 2>/dev/null)" == true ]]; then
        microos_say "lepton-${context} still runs, kept the workdirs in ${baked}"
        return 0
    fi
    for dir in "${baked}/app_workdir" "${baked}/data_workdir"; do
        [[ -d "${dir}" && ! -L "${dir}" ]] || continue
        if ! { chmod -R 700 "${dir}" && rm -rf "${dir:?}"; }; then
            microos_say "cannot clear ${dir}"
        fi
    done
}

clear_baked_app_data() {
    microos_say "kept the baked app data, asked to clear it for ${1:-no reason}"
}

cleanup_container() {
    kill_container "${1:-${LEPTON_CONTEXT}}"
}

cleanup_all() {
    microos_refuse "cleanup_all deletes every context, refusing"
}

kill_all() {
    microos_refuse "kill_all stops every Lepton container, refusing"
}

wipe_baked_system_data() {
    microos_refuse "wipe_baked_system_data deletes the runtime's sysbake, refusing"
}

podman_network_options() {
    local options
    options="-I eth0 --ipv4-only --no-ndp -a $(podman_ip) -g $(podman_subnet).1 -m 1500 --no-dhcpv6 --no-dhcp"
    options+=" -t 127.0.0.1/$(adb_port) --no-splice --map-guest-addr none --dns-forward $(podman_subnet).1"
    printf '%s' "--network=pasta:${options// /,}"
}
