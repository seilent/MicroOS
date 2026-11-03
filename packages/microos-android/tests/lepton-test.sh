#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
launcher="${libexec}/microos-lepton"
override="${libexec}/microos-liblepton.sh"
lib="${libexec}/microos-lepton-lib.sh"
opts="${repo}/data/usr/share/microos-android/opts"
reviewed="${repo}/data/usr/share/microos-lepton/reviewed"
unit="${repo}/data/usr/lib/systemd/user/microos-android.service"

T=$(mktemp -d)
holder=
trap '[[ -z "${holder}" ]] || kill "${holder}" 2>/dev/null; chmod -R u+rwx "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
STATE="${T}/state"
mkdir -p "${STATE}/steamvr/runtime" "${STATE}/steamvr/logs" "${STATE}/steamvr/config" "${T}/bin" "${T}/home" "${T}/xdg" \
    "${T}/steam-empty" "${T}/outside"

unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME DBUS_SESSION_BUS_ADDRESS MICROOS_RUNTIME_DIR MICROOS_LEPTON_HOME \
    STEAM_COMPAT_DATA_PATH APP_WANTS_FLATSCREEN GAMESCOPE_WAYLAND_DISPLAY CONTAINERS_CONF_OVERRIDE MICROOS_GUEST_CMD \
    LEPTON_ADB_PORT LEPTON_GDB_PORT LEPTON_LLDB_PORT LEPTON_NO_CLEANUP LEPTON_KEEP_CONTEXT IS_PARENT SteamAppId \
    STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_LIBRARY_PATHS STEAM_COMPAT_SHADER_PATH LEPTON_PREFIX MICROOS_LEPTON_REVIEWED
for var in $(compgen -v LEPTON_ENV_ || true); do
    unset "${var}"
done
real_setpgid=$(command -v setpgid)
real_rm=$(command -v rm)
cp "${repo}/data/usr/share/microos-android/cmd" "${T}/guest-cmd"
export HOME="${T}/home" XDG_RUNTIME_DIR="${T}/xdg"
export MICROOS_HOME="${T}/home"
export MICROOS_LIBLEPTON="${override}" MICROOS_STEAM_EMPTY="${T}/steam-empty" MICROOS_GUEST_CMD="${T}/guest-cmd"
export PATH="${T}/bin:${PATH}"
valve_home="${HOME}/.local/share/microos-android/home"
contexts="${valve_home}/.local/share/lepton/contexts"
run_dir="${XDG_RUNTIME_DIR}/microos-lepton"
android_run_dir="${XDG_RUNTIME_DIR}/microos-android"

{ printf '#!/usr/bin/bash\nstate=%q\nreal_rm=%q\n' "${STATE}" "${real_rm}"; cat; } > "${T}/bin/podman" <<'STUB'
printf 'podman %s\n' "$*" >> "${state}/podman"
reg="${state}/containers"
[[ "${XDG_CONFIG_HOME:-}" != */config-b ]] || reg="${state}/containers-b"
[[ -e "${reg}" ]] || : > "${reg}"
last=${!#}
case "$1" in
    unshare)
        [[ ! -e "${state}/unshare-fail" ]] || exit 125
        shift
        exec "$@"
        ;;
    ps)
        [[ ! -e "${state}/ps-fail" ]] || exit 125
        if [[ " $* " == *" -a "* ]]; then
            cut -d' ' -f1 "${reg}"
        else
            grep ' running ' "${reg}" | cut -d' ' -f1
        fi
        ;;
    run)
        name=
        scdp=
        prefix=
        replace=0
        prev=
        for arg in "$@"; do
            [[ "${arg}" != --replace ]] || replace=1
            case "${prev}" in
                --name) name=${arg} ;;
                --mount)
                    src=${arg#*source=}
                    src=${src%%,*}
                    [[ -e "${src}" ]] || { echo "podman: ${src} missing" >&2; exit 125; }
                    ;;
                --label)
                    case "${arg}" in
                        STEAM_COMPAT_DATA_PATH=*) scdp=${arg#*=} ;;
                        PREFIX=*) prefix=${arg#*=} ;;
                    esac
                    ;;
            esac
            prev=${arg}
        done
        if grep -q "^${name} " "${reg}"; then
            (( replace )) || { echo "podman: ${name} in use" >&2; exit 125; }
            sed -i "\|^${name} |d" "${reg}"
        fi
        printf '%s\n' "$@" > "${state}/run-${name}"
        printf '%s\n' "${prefix}" > "${state}/prefix-${name}"
        printf '%s running %s\n' "${name}" "${scdp}" >> "${reg}"
        ;;
    stop)
        [[ -e "${state}/stop-fail" && -n "${IS_PARENT:-}" ]] && exit 0
        sed -i "s|^${last} running |${last} exited |" "${reg}"
        ;;
    rm)
        sed -i "\|^${last} |d" "${reg}"
        "${real_rm}" -f "${state}/prefix-${last}"
        ;;
    exec) ;;
    inspect)
        format=
        prev=
        for arg in "$@"; do
            [[ "${prev}" != -f ]] || format=${arg}
            prev=${arg}
        done
        line=$(grep "^${last} " "${reg}") || exit 125
        case "${format}" in
            *State.Running*)
                [[ ! -e "${state}/running-fail" ]] || exit 125
                if [[ "${line}" == "${last} running "* ]]; then echo true; else echo false; fi
                ;;
            *STEAM_COMPAT_DATA_PATH*) echo "${line#* * }" ;;
            *PREFIX*) cat "${state}/prefix-${last}" 2>/dev/null ;;
        esac
        ;;
    container)
        [[ ! -e "${state}/exists-fail" ]] || exit 125
        grep -q "^${last} " "${reg}"
        ;;
    *) echo "podman: unexpected $*" >&2; exit 99 ;;
esac
STUB
{ printf '#!/usr/bin/bash\nstate=%q\n' "${STATE}"; cat; } > "${T}/bin/chown" <<'STUB'
printf 'chown %s in %s\n' "$*" "${PWD}" >> "${state}/chown"
[[ "$1" == -h ]] || echo "chown without -h: $*" >> "${state}/chown-bad"
[[ ! -L "${!#}" ]] || echo "chown on a link: $*" >> "${state}/chown-bad"
STUB
{ printf '#!/usr/bin/bash\nstate=%q\nreal_rm=%q\n' "${STATE}" "${real_rm}"; cat; } > "${T}/bin/rm" <<'STUB'
if [[ -e "${state}/rm-plant" && "$*" == "-f adb_keys.new" ]]; then
    "${real_rm}" "$@"
    ln -s "$(cat "${state}/rm-plant")" adb_keys.new
    exit 0
fi
exec "${real_rm}" "$@"
STUB
{ printf '#!/usr/bin/bash\n'; cat; } > "${T}/bin/setpgid" <<STUB
[[ "\$1" != --foreground ]] || shift
exec ${real_setpgid} "\$@"
STUB
chmod 0755 "${T}/bin/"*

cat > "${T}/fake-lepton" <<'FAKE'
[[ -n "${IS_PARENT:-}" ]] || tr '\0' '\n' < "/proc/$$/environ" > "${FAKE_STATE}/env-${2:-none}"
set -euo pipefail
COMMAND="${1:-help}"
LEPTON_CONTEXT="${2:-}"
if [[ "${COMMAND}" == start || "${COMMAND}" == waitforexitandrun ]] && [[ -z "${IS_PARENT:-}" ]]; then
    export IS_PARENT=true
    exec setpgid --foreground "$0" "$@"
fi
if [[ -e "${FAKE_STATE}/swap-hook" ]]; then
    mv "${FAKE_STATE}/swap-hook" "${FAKE_STATE}/swap-hook.ran"
    bash "${FAKE_STATE}/swap-hook.ran"
fi
if [[ -n "${SteamAppId:-}" ]]; then
    LEPTON_CONTEXT="steamlaunch-${SteamAppId}"
fi
if [[ "${SteamAppId:-}" == 3056000 ]] || { [[ "${COMMAND}" == start ]] && [[ -z "${LEPTON_CONTEXT}" ]]; }; then
    LEPTON_CONTEXT=dev
    unset SteamAppId STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_DATA_PATH
fi
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/liblepton/liblepton.sh"
printf '%s\n' "${SCRIPT_DIR}" "${LEPTON_DIR}" "${LEPTON_DATA_DIR}" "${APK_AUTO_INSTALL_DIR}" "${MDNS_PUBLISH_PATH}" \
    "${STEAMVR_LOGS_DIR}" > "${FAKE_STATE}/paths-${LEPTON_CONTEXT}"
if [[ -e "${FAKE_STATE}/after-source" ]]; then
    bash "${FAKE_STATE}/after-source"
fi
case "${COMMAND}" in
    start|waitforexitandrun)
        determine_app --start
        log_to_file
        logcat_debug_clear
        if [[ -e "${FAKE_STATE}/call" ]]; then
            "$(cat "${FAKE_STATE}/call")"
        fi
        setup_container
        start_container
        teardown()
        {
            trap "" INT TERM ERR
            set +e
            set +o pipefail
            if [[ -e "${FAKE_STATE}/early" ]]; then
                dump_logcat "$(logcat_debug_dir)"
                clear_baked_app_data "early exit"
            fi
            kill_container "${LEPTON_CONTEXT}" --quiet
            if [[ -z "${LEPTON_KEEP_CONTEXT:-}" ]]; then
                cleanup_container
            fi
            remove_prefix
            if ! is_steamlaunch; then
                remove_context "${LEPTON_CONTEXT}"
                clear_baked_app_data "non steamlaunch container"
            fi
            echo teardown >> "${FAKE_STATE}/events-${LEPTON_CONTEXT}"
            kill -TERM -- -$$
            trap "-" INT TERM ERR
        }
        handle_signal()
        {
            println "Signal ${1} received, killing container..."
            teardown
        }
        trap "handle_signal SIGINT" INT
        trap "handle_signal SIGTERM" TERM
        trap "handle_signal ERR" ERR
        wait_for_container
        teardown
        ;;
    kill_all)
        kill_all
        ;;
    cleanup_all)
        cleanup_all
        ;;
    sysbake)
        [[ -n "${GITLAB_CI:-}" ]] || exit 1
        LEPTON_CONTEXT=sysbake
        wipe_baked_system_data
        cleanup_all
        ;;
    unreal_vr_test)
        SteamAppId=3418470 STEAM_COMPAT_INSTALL_PATH="${LEPTON_DIR}/../../vrtest" \
            STEAM_COMPAT_DATA_PATH="${LEPTON_DIR}/../../compatdata/3418470" "${LEPTON_ENTRYPOINT}" start
        ;;
    help)
        println "Usage: $0 verb"
        ;;
    *)
        die "Unknown command '${COMMAND}', try 'help'!"
        ;;
esac
FAKE

cat > "${T}/fake-liblepton" <<'FAKE'
set -euo pipefail
LEPTON_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LEPTON_ENTRYPOINT="${LEPTON_DIR}/../lepton"
LEPTON_DATA_DIR="${HOME}/.local/share/lepton/contexts"
STEAM_PATH="${HOME}/.local/share/Steam"
STEAMAPPS_PATH="${STEAM_PATH}/steamapps"
APK_AUTO_INSTALL_DIR="${HOME}/lepton_auto_install_apks"
MDNS_PUBLISH_PATH="${LEPTON_DIR}/mdns_publisher/bin/lepton-mdns-publish"
BAKED_SYSTEM_DATA_DIR="${LEPTON_DIR}/../sysbake"
PODMAN_CMDLINE=()
STEAMVR_LOGS_DIR="${FAKE_STATE}/steamvr/logs"

println() { printf '%s\n' "$@"; }
print() { printf '%s' "$@"; }
die() { printf '%s\n' "$@" >&2; exit 1; }
onexit_path() { print "$(data_mount_path)/lepton-on-app-exit"; }
logcat_debug_dir() { print "${STEAMVR_LOGS_DIR}/lepton-logcats/${LEPTON_CONTEXT}"; }
logcat_debug_clear() { rm -rf "$(logcat_debug_dir)"; }
lepton_log_file() { print "/${STEAMVR_LOGS_DIR}/lepton-${LEPTON_CONTEXT}.log"; }

log_to_file()
{
    local log
    log=$(lepton_log_file)
    mv "${log}" "${log%.log}.prev.log" 2>/dev/null || true
    println "Lepton starting up" > "${log}"
}

dump_logcat()
{
    mkdir -p "$1"
    println logcat > "$1/logcat-main.log"
}
is_app() { false; }
is_steamlaunch() { [[ "${1:-${LEPTON_CONTEXT:-}}" == steamlaunch-* ]]; }

create_prefix()
{
    if [[ -z "${LEPTON_PREFIX:-}" ]]; then
        LEPTON_PREFIX=$(mktemp -d "${FAKE_STATE}/lepton-context.XXXXXX")
        export LEPTON_PREFIX
    fi
}

is_context_live()
{
    [[ "$(podman inspect -f '{{.State.Running}}' "lepton-${1:-${LEPTON_CONTEXT}}" 2>/dev/null)" == true ]]
}

determine_app()
{
    local is_start=false game
    [[ "${1:-}" != --start ]] || is_start=true
    if [[ -z "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]]; then
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_PATH}"
    fi
    if [[ "${LEPTON_CONTEXT}" != dev ]] && ! is_steamlaunch "${LEPTON_CONTEXT}"; then
        for game in ${STEAMAPPS_PATH}/appmanifest_*.acf; do
            if [[ "$(grep '"name"' "${game}" | cut -d'"' -f4)" == "${LEPTON_CONTEXT}" ]]; then
                SteamAppId=$(grep '"appid"' "${game}" | cut -d'"' -f4)
                export SteamAppId STEAM_COMPAT_INSTALL_PATH="${STEAMAPPS_PATH}/common/game"
                export STEAM_COMPAT_DATA_PATH="${STEAMAPPS_PATH}/compatdata/${SteamAppId}"
                export STEAM_COMPAT_LIBRARY_PATHS="${STEAMAPPS_PATH}"
                export STEAM_COMPAT_SHADER_PATH="${STEAMAPPS_PATH}/shadercache/${SteamAppId}"
                LEPTON_CONTEXT="steamlaunch-${SteamAppId}"
                break
            fi
        done
    fi
    if is_context_live; then
        LEPTON_PREFIX=$(podman inspect -f '{{ index .Config.Labels "PREFIX" }}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null || true)
        export LEPTON_PREFIX
    elif [[ "${is_start}" == true ]]; then
        create_prefix
    fi
}

get_baked_app_data_dir()
{
    local context="${1:-${LEPTON_CONTEXT}}" data_path="${2:-${STEAM_COMPAT_DATA_PATH:-}}"
    if [[ -n "${data_path}" ]]; then
        print "${data_path}/baked"
    else
        print "${LEPTON_DATA_DIR}/${context}/baked"
    fi
}

fake_shader_path() { export STEAM_COMPAT_SHADER_PATH="${FAKE_STATE}/shader"; }
fake_data_path() { export STEAM_COMPAT_DATA_PATH="${FAKE_STATE}/other-data"; }

data_mount_path() { print "$(get_baked_app_data_dir "$@")/data_overlay"; }
data_workdir() { print "$(get_baked_app_data_dir "$@")/data_workdir"; }
app_workdir() { print "$(get_baked_app_data_dir "$@")/app_workdir"; }
app_datadir() { print "$(get_baked_app_data_dir "$@")/app_overlay"; }

prepare_baked_data_for_removal()
{
    local dir
    for dir in "$(data_workdir "$@")" "$(data_mount_path "$@")" "$(app_datadir "$@")"; do
        if [[ -d "${dir}" ]]; then
            chmod -R 700 "${dir}"
            rm -rf "${dir}"
        fi
    done
}

clear_baked_app_data()
{
    shift
    if [[ "${LEPTON_NO_CLEANUP:-false}" != false ]]; then
        println "Skipping clearing baked app data due to env LEPTON_NO_CLEANUP"
    else
        prepare_baked_data_for_removal "$@"
        rm -rf "$(get_baked_app_data_dir "$@")"
    fi
}

remove_prefix()
{
    if [[ -n "${LEPTON_PREFIX:-}" ]]; then
        prepare_baked_data_for_removal
        rm -rf "${LEPTON_PREFIX}"
    fi
}

wipe_baked_system_data()
{
    chmod 700 -R "${BAKED_SYSTEM_DATA_DIR}" 2>/dev/null || true
    rm -rf "${BAKED_SYSTEM_DATA_DIR}"
}

adb_port() { print "${LEPTON_ADB_PORT:-}"; }
podman_ip() { print 192.168.1.26; }

podman_subnet()
{
    local ip
    ip=$(podman_ip)
    print "${ip%.*}"
}

podman_network_options()
{
    local options="-I eth0 --ipv4-only --no-ndp -a $(podman_ip) -g $(podman_subnet).1 -m 1500 --no-dhcpv6 --no-dhcp"
    options+=" --map-gw -t auto -u auto --no-splice --dns-forward $(podman_subnet).1"
    print "--network=pasta:${options// /,}"
}

props_file() { print "${LEPTON_PREFIX}/lepton.prop"; }

setup_podman_base()
{
    PODMAN_CMDLINE+=(--pid=private --ipc=private --uts=private --cgroupns=private)
}

setup_props()
{
    local props="ro.lepton.devmode=false"
    [[ -z "${LEPTON_ADB_PORT:-}" ]] || props+=$'\n'"service.adb.tcp.port=${LEPTON_ADB_PORT}"
    println "${props}" > "$(props_file)"
    chmod 0644 "$(props_file)"
}

setup_mounts()
{
    local target
    echo setup_mounts >> "${FAKE_STATE}/events-${LEPTON_CONTEXT}"
    mkdir -p "$(data_mount_path)/steam_app" "$(data_workdir)" "$(app_workdir)" "$(app_datadir)" \
        "$(get_baked_app_data_dir)/app_lowerdir" "${LEPTON_DATA_DIR}"
    PODMAN_CMDLINE+=(-v "${BAKED_SYSTEM_DATA_DIR}:/data:O,upperdir=$(data_mount_path),workdir=$(data_workdir)")
    if [[ ! -e "${FAKE_STATE}/no-data-bind" ]]; then
        PODMAN_CMDLINE+=(--mount "type=bind,source=${LEPTON_DATA_DIR},destination=${LEPTON_DATA_DIR},rw")
    fi
    if [[ -n "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]]; then
        PODMAN_CMDLINE+=(--mount "type=bind,source=${STEAM_COMPAT_CLIENT_INSTALL_PATH},destination=${STEAM_COMPAT_CLIENT_INSTALL_PATH},rw")
    fi
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        if [[ -d "${STEAM_COMPAT_DATA_PATH}/media0" ]]; then
            if [[ ! -d "${STEAM_COMPAT_DATA_PATH}/external" ]]; then
                mv "${STEAM_COMPAT_DATA_PATH}/media0" "${STEAM_COMPAT_DATA_PATH}/external"
            fi
        fi
        mkdir -p "${STEAM_COMPAT_DATA_PATH}/external"
    fi
    rm -rf "$(data_mount_path)/media/0"
    mkdir -p "$(data_mount_path)/media"
    target="$(data_mount_path)/media/0"
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        target="${STEAM_COMPAT_DATA_PATH}/external"
    else
        mkdir -p "${target}"
    fi
    if [[ -d "${HOME}/Documents" ]]; then
        rm -rf "${target}/Documents"
        ln -s "${HOME}/Documents" "${target}/Documents"
    fi
    if [[ -d "${HOME}/Downloads" ]]; then
        rm -rf "${target}/Download"
        ln -s "${HOME}/Downloads" "${target}/Download"
    fi
    if [[ -d "${HOME}/Videos" ]]; then
        rm -rf "${target}/Movies"
        ln -s "${HOME}/Videos" "${target}/Movies"
    fi
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        ln -s "${STEAM_COMPAT_DATA_PATH}/external" "$(data_mount_path)/media/0"
    fi
    PODMAN_CMDLINE+=(-v "$(get_baked_app_data_dir)/app_lowerdir:/data/steam_app:O,upperdir=$(app_datadir),workdir=$(app_workdir)")
    PODMAN_CMDLINE+=(--mount "type=bind,source=${HOME}/.steam/steam.pipe,destination=/lepton/steam.pipe,rw")
    for n in $(seq "$(cat "${FAKE_STATE}/cmd-binds" 2>/dev/null || echo 1)"); do
        PODMAN_CMDLINE+=(--mount "type=bind,source=${LEPTON_DIR}/../images/rootfs_overlay/system/bin/cmd,destination=/system/bin/cmd,ro")
    done
}

setup_podman_mounts()
{
    local persistent n
    PODMAN_CMDLINE+=(--tmpfs /dev:rw,nosuid,noexec,U)
    for (( n = 0; n < $(cat "${FAKE_STATE}/shm-binds" 2>/dev/null || echo 1); n++ )); do
        PODMAN_CMDLINE+=(--mount "type=bind,source=/dev/shm,destination=/dev/shm,rw")
    done
    mkdir -p "$(data_mount_path)/misc/ethernet"
    touch "$(data_mount_path)/misc/ethernet/ipconfig.txt"
    mkdir -p "$(data_mount_path)/steamvr/runtime"
    for (( n = 0; n < $(cat "${FAKE_STATE}/runtime-binds" 2>/dev/null || echo 1); n++ )); do
        PODMAN_CMDLINE+=(--mount "type=bind,source=${FAKE_STATE}/steamvr/runtime,destination=/data/steamvr/runtime,rw")
    done
    if [[ ! -e "${FAKE_STATE}/no-logs-bind" ]]; then
        PODMAN_CMDLINE+=(--mount "type=bind,source=${STEAMVR_LOGS_DIR},destination=/data/steamvr/logs,rw")
    fi
    PODMAN_CMDLINE+=(--mount "type=bind,source=${FAKE_STATE}/steamvr/config,destination=/data/steamvr/config,ro")
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        persistent="${STEAM_COMPAT_DATA_PATH}/internal/"
        if [[ -d "${STEAM_COMPAT_DATA_PATH}/" ]]; then
            if [[ ! -d "${persistent}" ]]; then
                mkdir -p "$(dirname "${persistent}")"
                mv "${STEAM_COMPAT_DATA_PATH}/" "${persistent}"
            fi
        fi
        mkdir -p "${persistent}"
        chmod 700 "${persistent}"
    fi
}

kill_container()
{
    local context="${1:-${LEPTON_CONTEXT}}"
    podman exec -i "lepton-${context}" /system/bin/reboot -p 2>/dev/null || true
    podman stop -t 0 "lepton-${context}" >/dev/null 2>&1 || true
}

kill_all()
{
    local context
    for context in $(podman ps -a --filter label=lepton=true --format '{{.Names}}'); do
        kill_container "${context#lepton-}"
    done
}

cleanup_container()
{
    local context="${1:-${LEPTON_CONTEXT}}" other
    other=$(podman inspect -f '{{ index .Config.Labels "STEAM_COMPAT_DATA_PATH" }}' "lepton-${context}" 2>/dev/null || true)
    kill_container "${context}"
    if [[ -n "${other}" ]]; then
        rm -f "${other}"/baked/data_overlay/system/users/0/settings_{global,system,secure}.xml
    fi
}

cleanup_all()
{
    chmod -R 700 "${LEPTON_DATA_DIR}" || true
    rm -rf "${LEPTON_DATA_DIR:?}"/*
}

remove_context() { podman rm -fi "lepton-${1:-${LEPTON_CONTEXT}}" || true; }

setup_container()
{
    cleanup_container
    setup_podman_base
    setup_mounts
    setup_podman_mounts
    export LEPTON_ADB_PORT="${LEPTON_ADB_PORT:-5555}"
    PODMAN_CMDLINE+=("$(podman_network_options)")
    if [[ -e "${FAKE_STATE}/extra-mounts" ]]; then
        mapfile -t -O "${#PODMAN_CMDLINE[@]}" PODMAN_CMDLINE < "${FAKE_STATE}/extra-mounts"
    fi
    if [[ -e "${FAKE_STATE}/before-props" ]]; then
        bash "${FAKE_STATE}/before-props"
    fi
    setup_props
}

start_container()
{
    rm -f "$(onexit_path)"
    cp "$(props_file)" "${FAKE_STATE}/props-${LEPTON_CONTEXT}"
    podman rm -fi "lepton-${LEPTON_CONTEXT}" 2>/dev/null || true
    podman run --replace --name "lepton-${LEPTON_CONTEXT}" "${PODMAN_CMDLINE[@]}" --label lepton=true \
        --label "STEAM_COMPAT_DATA_PATH=${STEAM_COMPAT_DATA_PATH:-}" --label "PREFIX=${LEPTON_PREFIX:-}" \
        --rootfs "${LEPTON_DIR}/../images/rootfs:O" /init
    if [[ -e "${FAKE_STATE}/after-run" ]]; then
        bash "${FAKE_STATE}/after-run"
    fi
    println "Boot complete!"
    println logcat >> "$(lepton_log_file)"
}

wait_for_container()
{
    (
        while [[ "$(podman inspect -f '{{.State.Running}}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null)" == true ]]; do
            sleep 0.1
        done
        print "$(onexit_path)" > "${FAKE_STATE}/onexit-${LEPTON_CONTEXT}"
        touch "$(onexit_path)"
    ) &
    wait "$!"
}

[[ -z "${FAKE_DROP}" ]] || unset -f "${FAKE_DROP}"
FAKE

make_runtime() {
    mkdir -p "$1/liblepton" "$1/images/rootfs/system/etc" "$1/images/rootfs/vendor/odm/etc" \
        "$1/images/rootfs_overlay/vendor/bin" "$1/images/rootfs_overlay/system/bin" "$1/sysbake/system" \
        "$1/liblepton/apk_extractor/bin"
    echo xml > "$1/sysbake/system/packages.xml"
    echo '# file: sysbake/system' > "$1/sysbake.xattrs"
    printf 'ro.build.version.release=11\nro.build.version.sdk=30\nro.system.build.fingerprint=lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys\n' \
        > "$1/images/rootfs/system/build.prop"
    echo 'ro.odm.build.id=RQ3A' > "$1/images/rootfs/vendor/odm/etc/build.prop"
    echo 'ro.adb.secure=0' > "$1/images/rootfs/system/etc/prop.default"
    echo 3.0.3 > "$1/images/version.txt"
    echo overlay > "$1/images/rootfs_overlay/vendor/bin/lepton_set_volumes.sh"
    echo 'cmd_real "$@"' > "$1/images/rootfs_overlay/system/bin/cmd"
    echo fakedroid > "$1/liblepton/app_metadata.sh"
    { printf '#!/bin/bash\nFAKE_STATE=%q\n' "${STATE}"; cat "${T}/fake-lepton"; } > "$1/lepton"
    { printf '#!/bin/bash\nFAKE_STATE=%q\nFAKE_DROP=%q\n' "${STATE}" "${2:-}"; cat "${T}/fake-liblepton"; } > "$1/liblepton/liblepton.sh"
    chmod 0755 "$1/lepton"
    ln -s lepton "$1/fauxdroid"
    launcher_block "$1" > "$1.reviewed"
}

marker() {
    local dir=$1
    printf 'rootfs=%s\n' "$(cat "${dir}/images/version.txt") $(sed -n 's/^ro\.system\.build\.fingerprint=//p' "${dir}/images/rootfs/system/build.prop" | head -n 1)" \
        > "$(dirname "${dir}")/.verified.${dir##*/}"
}

launcher_block() {
    (
        eval "$(sed -n '/^paths()/,/^}/p;/^entry()/,/^}/p' "${lib}")"
        cd "$1"
        paths | LC_ALL=C sort | while IFS= read -r path; do entry "$1" "${path}"; done
    )
}

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

seed() {
    local d="$1/baked/data_overlay" s
    mkdir -p "${d}/system/users/0" "${d}/data/com.example.game" "$1/baked/app_overlay" "$1/external/Download" \
        "$1/baked/data_workdir/work" "$1/baked/app_workdir/work" "$1/internal"
    echo xml > "${d}/system/packages.xml"
    for s in global system secure; do
        echo "${s}" > "${d}/system/users/0/settings_${s}.xml"
    done
    echo save > "${d}/data/com.example.game/save"
    echo app > "$1/baked/app_overlay/file"
    echo dl > "$1/external/Download/file"
    chmod 000 "$1/baked/data_workdir/work" "$1/baked/app_workdir/work"
}

unseed_modes() {
    chmod 755 "$1/baked/data_workdir/work" "$1/baked/app_workdir/work" 2>/dev/null || :
}

intact() {
    local d="$1/baked/data_overlay" s
    [[ -f "${d}/system/packages.xml" && -f "${d}/data/com.example.game/save" && -f "$1/baked/app_overlay/file" \
        && -f "$1/external/Download/file" ]] || fail "$2: context data lost"
    for s in global system secure; do
        [[ -f "${d}/system/users/0/settings_${s}.xml" ]] || fail "$2: settings_${s}.xml lost"
    done
}

snapshot() { find "$1" -printf '%p %y %m %s %l\n' | sort; }

running() {
    local n=0
    until grep -q "^lepton-$1 running " "${3:-${STATE}/containers}" 2>/dev/null; do
        kill -0 "$2" 2>/dev/null || return 1
        (( ++n < 100 )) || return 1
        sleep 0.1
    done
}

gone() {
    local n=0
    while kill -0 "$1" 2>/dev/null; do
        (( ++n <= 100 )) || return 1
        sleep 0.1
    done
}

cycle() {
    local name=$1 pid
    shift
    rc=0
    "$@" > "${STATE}/out-${name}" 2>&1 &
    pid=$!
    if running "${name}" "${pid}"; then
        podman stop -t 0 "lepton-${name}" >/dev/null
    fi
    wait "${pid}" || rc=$?
}

refused() {
    local name=$1 pid
    shift
    rc=0
    rm -f "${STATE:?}"/run-lepton-*
    "$@" > "${STATE}/out-${name}" 2>&1 &
    pid=$!
    gone "${pid}" || { kill -9 "${pid}"; podman stop -t 0 "lepton-${name}" >/dev/null; fail "${name}: still running"; }
    wait "${pid}" || rc=$?
    [[ "${rc}" == 1 ]] || fail "${name}: exit ${rc}, expected 1: $(cat "${STATE}/out-${name}")"
    compgen -G "${STATE}/run-lepton-*" > /dev/null && fail "${name}: a container ran"
    compgen -G "${STATE}/lepton-context.*" > /dev/null && fail "${name}: Lepton's prefix left"
    return 0
}

out() { cat "${STATE}/out-$1"; }

views() { compgen -G "${run_dir}/tool.*" || true; }

direct() {
    env -i HOME="${valve_home}" PATH="${PATH}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" XDG_CONFIG_HOME="${HOME}/.config" \
        STEAM_COMPAT_CLIENT_INSTALL_PATH="${T}/steam-empty" LEPTON_ADB_PORT=15655 MICROOS_GUEST_CMD="${T}/guest-cmd" \
        MICROOS_LEPTON_RUNTIME="${rt}" MICROOS_LEPTON_REVIEWED="${MICROOS_LEPTON_REVIEWED:-}" "$@"
}

block="${reviewed}/25772114"
[[ -f "${block}" ]] || fail "lepton-reviewed: no block for build 25772114"
[[ "$(wc -l < "${block}")" == 41 ]] || fail "lepton-reviewed: $(wc -l < "${block}") lines"
grep -vqE '^([0-9a-f]{64}  [A-Za-z0-9._/-]+|link  [A-Za-z0-9._/-]+  [A-Za-z0-9._/-]+|missing  [A-Za-z0-9._/-]+)$' "${block}" \
    && fail "lepton-reviewed: a line is neither <sha256>  <path>, link  <path>  <target> nor missing  <path>"
for path in lepton liblepton/liblepton.sh sysbake.xattrs images/rootfs/system/build.prop \
    images/rootfs/vendor/odm/etc/build.prop images/rootfs/system/etc/prop.default sysbake/system/packages.xml \
    liblepton/apk_extractor/bin/apk-info-extractor; do
    grep -qE "  ${path}$" "${block}" || fail "lepton-reviewed: ${path} is not hashed"
done
grep -qxF "link  fauxdroid  lepton" "${block}" || fail "lepton-reviewed: the fauxdroid link is not recorded"
grep -qE '  (LICENSE\.md|README\.md|images/NOTICE\.txt)$|  LICENSES/' "${block}" \
    && fail "lepton-reviewed: a Valve doc is hashed, a doc edit would refuse a start"

export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps"
mkdir -p "${MICROOS_LEPTON_SNAPSHOTS}" "${T}/steam/steamapps/common"
make_runtime "${T}/steam/steamapps/common/Lepton"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
mkdir -p "${MICROOS_LEPTON_REVIEWED}"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${MICROOS_LEPTON_REVIEWED}/25772114"
manifest="${T}/steam/steamapps/appmanifest_3029110.acf"
printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' > "${manifest}"
export MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir"
mkdir -p "${T}/bin"
cat > "${MICROOS_LEPTON_STEAM_DIR_CMD}" <<STUB
#!/usr/bin/bash
[[ ! -e "${STATE}/no-lepton-dir" ]] || exit 1
printf '%s\n' "${T}/steam/steamapps/common/Lepton"
STUB
chmod 0755 "${MICROOS_LEPTON_STEAM_DIR_CMD}"
cp -a "${T}/steam/steamapps/common/Lepton" "${MICROOS_LEPTON_SNAPSHOTS}/25772114"
marker "${MICROOS_LEPTON_SNAPSHOTS}/25772114"
rt="${MICROOS_LEPTON_SNAPSHOTS}/25772114"
mkdir -p "${HOME}/.config/microos-android"
printf 'QAAAAkey1 micro@pm2\nQAAAAkey2 seilent@sepc\n' > "${HOME}/.config/microos-android/adb_keys"

for args in "" cleanup_all kill_all sysbake help unreal_vr_test "shell probe-lh-proto" \
    "install_app probe-lh-proto /x.apk" "waitforexitandrun probe-lh-proto" start "start probe-lh-proto extra"; do
    read -ra argv <<< "${args}"
    rc=0
    timeout -k 2 20 "${launcher}" "${argv[@]}" > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 1 ]] && grep -qx "microos-lepton: usage: microos-lepton runtime | start <context>" "${STATE}/out" \
        || fail "verb '${args}': exit ${rc}: $(cat "${STATE}/out")"
done
compgen -G "${STATE}/env-*" > /dev/null && fail "a refused verb reached lepton"
[[ ! -e "${run_dir}" ]] || fail "a refused verb made the view"

for name in dev sysbake steamlaunch-123 Probe a.apk ../x -x ""; do
    rc=0
    timeout -k 2 20 "${launcher}" start "${name}" > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 1 ]] || fail "context '${name}': exit ${rc}"
done
compgen -G "${STATE}/env-*" > /dev/null && fail "a refused context name reached lepton"

mkdir -p "${T}/rt-nolepton/liblepton"
: > "${T}/rt-nolepton/liblepton/liblepton.sh"
for runtime in "${rt}/.." "${T}/rt-nolepton" "${T}/absent"; do
    rc=0
    MICROOS_LEPTON_RUNTIME="${runtime}" timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: MICROOS_LEPTON_RUNTIME is ${runtime}, not this start's runtime ${rt}, refusing" \
        "${STATE}/out" || fail "runtime '${runtime}': exit ${rc}: $(cat "${STATE}/out")"
done
compgen -G "${STATE}/env-*" > /dev/null && fail "a foreign MICROOS_LEPTON_RUNTIME reached lepton"
[[ ! -d "${contexts}" || -z "$(ls -A "${contexts}" 2>/dev/null)" ]] || fail "a foreign MICROOS_LEPTON_RUNTIME made a context"
rc=0
MICROOS_LIBLEPTON="${T}/absent" timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -q "${T}/absent missing" "${STATE}/out" || fail "override missing: exit ${rc}"
rc=0
MICROOS_LEPTON_REVIEWED="${T}/absent" timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: no reviewed Lepton list in ${T}/absent" "${STATE}/out" \
    || fail "reviewed list missing: exit ${rc}: $(cat "${STATE}/out")"
mkdir -p "${T}/empty-review" "${T}/empty-steam/steamapps/common" "${T}/empty-snaps"
make_runtime "${T}/empty-steam/steamapps/common/Lepton"
printf '"AppState"\n{\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' \
    > "${T}/empty-steam/steamapps/appmanifest_3029110.acf"
cat > "${T}/bin/lepton-dir-empty" <<STUB
#!/usr/bin/bash
printf '%s\n' "${T}/empty-steam/steamapps/common/Lepton"
STUB
chmod 0755 "${T}/bin/lepton-dir-empty"
rc=0
MICROOS_LEPTON_SNAPSHOTS="${T}/empty-snaps" MICROOS_LEPTON_REVIEWED="${T}/empty-review" \
    MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-empty" \
    timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: Lepton build 25772114 is not one MicroOS knows, refusing" "${STATE}/out" \
    || fail "unknown build from Steam: exit ${rc}: $(cat "${STATE}/out")"
printf '"AppState"\n{\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"6"\n}\n' \
    > "${T}/empty-steam/steamapps/appmanifest_3029110.acf"
rc=0
MICROOS_LEPTON_SNAPSHOTS="${T}/empty-snaps" MICROOS_LEPTON_REVIEWED="${T}/reviewed" \
    MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-empty" \
    timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: Lepton is not installed. Install it in Steam." "${STATE}/out" \
    || fail "not installed bit clear: exit ${rc}: $(cat "${STATE}/out")"
rc=0
MICROOS_LEPTON_SNAPSHOTS="${T}/empty-snaps" MICROOS_LEPTON_REVIEWED="${T}/reviewed" \
    MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: Lepton is not installed. Install it in Steam." "${STATE}/out" \
    || fail "no tree from discovery: exit ${rc}: $(cat "${STATE}/out")"
rc=0
MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(grep -x "${rt}" "${STATE}/out")" == "${rt}" ]] \
    || fail "discovery down, snapshot present: exit ${rc}: $(cat "${STATE}/out")"
rm -rf "${T}/empty-review" "${T}/empty-steam" "${T}/empty-snaps"
for change in byte lepton extra xattrs sdk; do
    rm -rf "${T}/snaps-bad"
    mkdir -p "${T}/snaps-bad"
    cp -a "${rt}" "${T}/snaps-bad/25772114"
marker "${T}/snaps-bad/25772114"
    want="microos-lepton: Lepton in ${T}/snaps-bad/25772114 is not the build in ${MICROOS_LEPTON_REVIEWED}/25772114, refusing"
    case "${change}" in
        byte) sed -i '$ s/FAKE_DROP/FAKE_DROQ/' "${T}/snaps-bad/25772114/liblepton/liblepton.sh" ;;
        lepton) echo >> "${T}/snaps-bad/25772114/lepton" ;;
        extra) echo true > "${T}/snaps-bad/25772114/liblepton/new.sh" ;;
        xattrs) echo >> "${T}/snaps-bad/25772114/sysbake.xattrs" ;;
        sdk)
            sed -i 's/sdk=30/sdk=31/' "${T}/snaps-bad/25772114/images/rootfs/system/build.prop"
            want="microos-lepton: Lepton in ${T}/snaps-bad/25772114 is not Android SDK 30, refusing"
            ;;
    esac
    rc=0
    MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-bad" MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false \
        timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 1 && "$(cat "${STATE}/out")" == "${want}
microos-lepton: Lepton is not installed. Install it in Steam." ]] \
        || fail "runtime ${change} changed, no Steam copy: exit ${rc}: $(cat "${STATE}/out")"
    [[ -z "$(ls -A "${T}/snaps-bad")" ]] || fail "runtime ${change} changed: the bad snapshot was kept: $(ls -A "${T}/snaps-bad")"
    rc=0
    MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-bad" timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/snaps-bad/25772114" ]] \
        || fail "runtime ${change} changed, Steam copy: exit ${rc}: $(cat "${STATE}/out")"
    grep -qx "microos-lepton: took the snapshot ${T}/snaps-bad/25772114" "${STATE}/out" \
        || fail "runtime ${change} changed: not retaken from Steam: $(cat "${STATE}/out")"
done
rm -rf "${T}/snaps-bad"
echo x > "${T}/steam-empty/file"
rc=0
timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -q "is not an empty directory" "${STATE}/out" || fail "client dir not empty: exit ${rc}"
rm "${T}/steam-empty/file"
chmod 000 "${T}/steam-empty"
rc=0
timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
chmod 755 "${T}/steam-empty"
[[ "${rc}" == 1 ]] && grep -q "is not an empty directory" "${STATE}/out" || fail "client dir unreadable: exit ${rc}"
rc=0
STEAM_COMPAT_DATA_PATH="${contexts}/other" timeout -k 2 20 "${launcher}" start probe-lh-proto \
    > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: STEAM_COMPAT_DATA_PATH is not ${contexts}/probe-lh-proto, refusing" "${STATE}/out" \
    || fail "STEAM_COMPAT_DATA_PATH of another context: exit ${rc}: $(cat "${STATE}/out")"
compgen -G "${STATE}/env-*" > /dev/null && fail "a refused runtime reached lepton"
[[ ! -e "${contexts}" ]] || fail "a refused start made a context"

ctx="${contexts}/probe-lh-proto"
seed "${ctx}"
unseed_modes "${ctx}"
cp -a "${ctx}" "${T}/ctx-before-first-start"
echo prop > "${T}/odm.prop"
printf '[containers]\nmounts = ["type=bind,source=%s,destination=/vendor/odm/etc/build.prop,ro"]\n' "${T}/odm.prop" \
    > "${T}/containers.conf"
cycle probe-lh-proto env SteamAppId=1234 STEAM_COMPAT_INSTALL_PATH=/x STEAM_COMPAT_SHADER_PATH=/x STEAM_COMPAT_LIBRARY_PATHS=/x \
    LEPTON_ENV_FOO=1 LEPTON_PREFIX=/x LD_PRELOAD=/x LD_LIBRARY_PATH=/x LEPTON_NO_CLEANUP=false LEPTON_KEEP_CONTEXT= \
    LEPTON_DEBUG=true TERM=xterm-256color APP_WANTS_FLATSCREEN=true GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
    CONTAINERS_CONF_OVERRIDE="${T}/containers.conf" STEAM_COMPAT_DATA_PATH="${ctx}" \
    LEPTON_ADB_PORT=15655 LEPTON_GDB_PORT=15656 LEPTON_LLDB_PORT=15657 \
    "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "start: exit ${rc}: $(out probe-lh-proto)"
cat > "${STATE}/want-env" <<WANT
APP_WANTS_FLATSCREEN=true
CONTAINERS_CONF_OVERRIDE=${T}/containers.conf
DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus
GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
HOME=${valve_home}
LEPTON_ADB_PORT=15655
LEPTON_GDB_PORT=15656
LEPTON_KEEP_CONTEXT=1
LEPTON_LLDB_PORT=15657
LEPTON_NO_CLEANUP=true
MICROOS_LEPTON_REVIEWED=${MICROOS_LEPTON_REVIEWED}
MICROOS_LEPTON_RUNTIME=${rt}
MICROOS_GUEST_CMD=${T}/guest-cmd
PATH=${PATH}
STEAM_COMPAT_CLIENT_INSTALL_PATH=${T}/steam-empty
STEAM_COMPAT_DATA_PATH=${ctx}
TERM=dumb
XDG_CONFIG_HOME=${HOME}/.config
XDG_DATA_HOME=${HOME}/.local/share
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}
XDG_STATE_HOME=${HOME}/.local/state
WANT
diff <(sort "${STATE}/want-env") <(sort "${STATE}/env-probe-lh-proto") > "${STATE}/env-diff" \
    || fail "environment not exact: $(cat "${STATE}/env-diff")"
view=$(views)
[[ "${view}" == "${run_dir}"/tool.* && "$(wc -l <<< "${view}")" == 1 && -d "${view}" && ! -L "${view}" ]] \
    || fail "not one view dir: ${view}"
[[ "$(cat "${STATE}/paths-probe-lh-proto")" == "${view}
${rt}/liblepton
${contexts}
/dev/null/microos
/bin/false
${HOME}/.local/state/microos-lepton/steamvr-logs" ]] || fail "SCRIPT_DIR, LEPTON_DIR or the reassigned paths: $(cat "${STATE}/paths-probe-lh-proto")"
[[ "$(readlink "${view}/lepton")" == "${rt}/lepton" ]] || fail "view lepton: $(readlink "${view}/lepton")"
[[ "$(readlink "${view}/liblepton/liblepton.sh")" == "${override}" ]] || fail "view liblepton.sh"
[[ ! -e "${run_dir}/tool" ]] || fail "a tool link was made"
[[ -p "${valve_home}/.steam/steam.pipe" ]] || fail "steam.pipe FIFO not made under the Valve HOME"
network=$(grep '^--network=' "${STATE}/run-lepton-probe-lh-proto")
[[ "${network}" == "--network=pasta:-I,eth0,--ipv4-only,--no-ndp,-a,192.168.1.26,-g,192.168.1.1,-m,1500,--no-dhcpv6,--no-dhcp,-t,127.0.0.1/15655,--no-splice,--map-guest-addr,none,--dns-forward,192.168.1.1" ]] \
    || fail "network options: ${network}"
grep -qx "service.adb.tcp.port=15655" "${STATE}/props-probe-lh-proto" || fail "Valve's setup_props did not run: $(cat "${STATE}/props-probe-lh-proto")"
adb="${ctx}/baked/data_overlay/misc/adb"
printf 'QAAAAkey1 micro@pm2\nQAAAAkey2 seilent@sepc\n' > "${HOME}/.config/microos-android/adb_keys"
cmp -s "${HOME}/.config/microos-android/adb_keys" "${adb}/adb_keys" || fail "adb_keys not the key file: $(cat "${adb}/adb_keys")"
[[ "$(stat -c %a "${adb}")" == 755 && "$(stat -c %a "${adb}/adb_keys")" == 644 ]] \
    || fail "adb modes: $(stat -c %a "${adb}") $(stat -c %a "${adb}/adb_keys")"
grep -qx "chown -h 0:0 . in ${adb}" "${STATE}/chown" && grep -qx "chown -h 0:0 adb_keys.new in ${adb}" "${STATE}/chown" \
    || fail "adb owner: $(cat "${STATE}/chown")"
grep -q "^podman unshare sh -c " "${STATE}/podman" \
    && grep -qF " sh ${ctx}/baked/data_overlay 0:0 0755 0644 ${ctx}/baked/data_overlay" "${STATE}/podman" \
    || fail "adb_keys not written through podman unshare"
run_args="${STATE}/run-lepton-probe-lh-proto"
[[ "$(grep -c '^--cgroup-parent=game-android.slice$' "${run_args}")" == 1 ]] \
    || fail "the guest is not placed under game-android.slice: $(grep -n cgroup "${run_args}")"
grep -qxF "type=bind,source=${ctx}/external,destination=${ctx}/external,rw" "${run_args}" \
    || fail "external/ not bound at its own path: $(cat "${run_args}")"
grep -qF "${contexts}," "${run_args}" && fail "the contexts dir is bound into the guest"
[[ "$(grep -c "^type=bind,source=${ctx}/external," "${run_args}")" == 1 ]] || fail "external/ bound twice"
grep -qF "/dev/shm,destination=/dev/shm" "${run_args}" && fail "the host /dev/shm is bound into the guest"
[[ "$(grep -cxF -- /dev/shm:rw,nosuid,nodev,noexec "${run_args}")" == 1 ]] \
    && grep -B1 -xF -- /dev/shm:rw,nosuid,nodev,noexec "${run_args}" | head -n 1 | grep -qx -- --tmpfs \
    || fail "/dev/shm is not one private tmpfs: $(grep -n shm "${run_args}")"
grep -qxF "type=bind,source=${STATE}/steamvr/runtime,destination=/data/steamvr/runtime,ro" "${run_args}" \
    && ! grep -q 'destination=/data/steamvr/runtime,rw' "${run_args}" \
    || fail "the SteamVR runtime is not bound read only: $(grep -n steamvr/runtime "${run_args}")"
grep -q 'destination=/data/steamvr/logs' "${run_args}" && fail "the guest gets a bind at /data/steamvr/logs"
intact "${ctx}" "first stop"
[[ ! -e "${ctx}/baked/data_workdir" && ! -e "${ctx}/baked/app_workdir" ]] || fail "workdirs left after the stop"
grep -q "kept the baked app data, asked to clear it for non steamlaunch container" "${STATE}/out-probe-lh-proto" \
    || fail "clear_baked_app_data did not log: $(out probe-lh-proto)"
[[ "$(grep -c teardown "${STATE}/events-probe-lh-proto")" == 1 ]] || fail "teardown did not finish once"
[[ -f "${android_run_dir}/lepton-prefix" ]] || fail "the run did not record Valve's prefix: $(ls -A "${android_run_dir}" 2>/dev/null)"
[[ "$(cat "${android_run_dir}/lepton-prefix")" =~ ^${STATE}/lepton-context\.[A-Za-z0-9]+$ ]] \
    || fail "the record names $(cat "${android_run_dir}/lepton-prefix"), not the prefix Valve made in ${STATE}"
[[ -z "$(find "${android_run_dir}" -name 'lepton-prefix.*')" ]] || fail "the record left a temp file: $(ls -A "${android_run_dir}")"

for n in 2 3 4; do
    printf 'stale\n' > "${adb}/adb_keys"
    [[ "${n}" != 4 ]] || mv "${HOME}/.config/microos-android/adb_keys" "${HOME}/.config/microos-android/adb_keys.off"
    cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    [[ "${rc}" == 0 ]] || fail "cycle ${n}: exit ${rc}: $(out probe-lh-proto)"
    intact "${ctx}" "cycle ${n}"
done
[[ -f "${adb}/adb_keys" && ! -s "${adb}/adb_keys" ]] || fail "no key file: adb_keys not emptied: $(cat "${adb}/adb_keys")"
mv "${HOME}/.config/microos-android/adb_keys.off" "${HOME}/.config/microos-android/adb_keys"
diff <(grep -v '^STEAM_COMPAT_DATA_PATH=\|^LEPTON_.*_PORT=\|^APP_WANTS\|^GAMESCOPE\|^CONTAINERS_CONF' "${STATE}/want-env" | sort) \
    <(sort "${STATE}/env-probe-lh-proto" | grep -v '^STEAM_COMPAT_DATA_PATH=') > "${STATE}/env-diff" \
    || fail "environment without optional variables: $(cat "${STATE}/env-diff")"
[[ "$(views)" != "${view}" && "$(views | wc -l)" == 1 ]] || fail "the views of finished starts were kept: $(views)"

echo outside > "${T}/outside/file"
before=$(snapshot "${T}/outside")
unplant() {
    if [[ -L "${link}" ]]; then
        rm "${link}"
        mv "${T}/kept" "${link}"
    fi
}
for link in "${ctx}/baked/data_overlay/misc" "${adb}"; do
    plant=$(printf 'mv %q %q && ln -s %q %q\n' "${link}" "${T}/kept" "${T}/outside" "${link}")
    bash -c "${plant}"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: ${link} is a link, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "${link} a link at start: $(out probe-lh-proto)"
    [[ "$(snapshot "${T}/outside")" == "${before}" ]] || fail "${link} a link at start: outside changed: $(snapshot "${T}/outside")"
    unplant
    printf '%s\n' "${plant}" > "${STATE}/before-props"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    rm -f "${STATE}/before-props"
    grep -qxF "microos-liblepton: cannot write ${adb}/adb_keys, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "${link} a link at adb_keys: $(out probe-lh-proto)"
    [[ "$(snapshot "${T}/outside")" == "${before}" ]] || fail "${link} a link at adb_keys: outside changed: $(snapshot "${T}/outside")"
    unplant
done
for target in adb_keys.new adb_keys; do
    rm -f "${adb:?}/${target}"
    ln -s "${T}/outside/file" "${adb}/${target}"
    cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    [[ "${rc}" == 0 ]] || fail "${target} link: exit ${rc}: $(out probe-lh-proto)"
    [[ "$(snapshot "${T}/outside")" == "${before}" && "$(cat "${T}/outside/file")" == outside ]] \
        || fail "${target} link: outside changed: $(snapshot "${T}/outside")"
    [[ -f "${adb}/adb_keys" && ! -L "${adb}/adb_keys" && ! -e "${adb}/adb_keys.new" ]] \
        && cmp -s "${HOME}/.config/microos-android/adb_keys" "${adb}/adb_keys" || fail "${target} link: adb_keys not written"
done
[[ ! -e "${STATE}/chown-bad" ]] || fail "chown: $(cat "${STATE}/chown-bad")"
rm "${adb}/adb_keys"
mkdir "${adb}/adb_keys"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -q "cannot write ${adb}/adb_keys, refusing" "${STATE}/out-probe-lh-proto" || fail "adb_keys a directory: $(out probe-lh-proto)"
rmdir "${adb}/adb_keys"
rm -rf "${adb:?}"
: > "${adb}"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -q "cannot write ${adb}/adb_keys, refusing" "${STATE}/out-probe-lh-proto" || fail "adb_keys write failure: $(out probe-lh-proto)"
rm "${adb}"
printf '%s\n' "${T}/outside/file" > "${STATE}/rm-plant"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/rm-plant"
grep -qxF "microos-liblepton: cannot write ${adb}/adb_keys, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "adb_keys.new a link after the rm: $(out probe-lh-proto)"
[[ "$(snapshot "${T}/outside")" == "${before}" && "$(cat "${T}/outside/file")" == outside ]] \
    || fail "adb_keys.new a link after the rm: outside changed: $(cat "${T}/outside/file")"
rm -f "${adb:?}/adb_keys.new"
mkdir -p "${T}/outside2"
before2=$(snapshot "${T}/outside2")
data="${ctx}/baked/data_overlay"
printf 'mv %q %q && ln -s %q %q\n' "${data}" "${T}/kept-data" "${T}/outside2" "${data}" > "${STATE}/before-props"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm -f "${STATE}/before-props"
grep -qxF "microos-liblepton: cannot write ${adb}/adb_keys, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "data_overlay a link at adb_keys: $(out probe-lh-proto)"
[[ "$(snapshot "${T}/outside2")" == "${before2}" ]] || fail "data_overlay a link at adb_keys: outside changed: $(snapshot "${T}/outside2")"
[[ -L "${data}" ]] && rm "${data}" && mv "${T}/kept-data" "${data}"
printf 'stale\n' > "${adb}/adb_keys"
echo "lepton-other running /x" >> "${STATE}/containers"
: > "${STATE}/events-probe-lh-proto"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: lepton-other runs, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "another guest at start: $(out probe-lh-proto)"
grep -q setup_mounts "${STATE}/events-probe-lh-proto" && fail "another guest at start: Lepton's setup_mounts ran"
sed -i '/^lepton-other /d' "${STATE}/containers"
printf 'echo "lepton-other running /x" >> %q\n' "${STATE}/containers" > "${STATE}/before-props"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm -f "${STATE}/before-props"
grep -qxF "microos-liblepton: lepton-other runs, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "another guest at adb_keys: $(out probe-lh-proto)"
[[ "$(cat "${adb}/adb_keys")" == stale ]] || fail "another guest at adb_keys: adb_keys written"
sed -i '/^lepton-other /d' "${STATE}/containers"
: > "${STATE}/ps-fail"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/ps-fail"
grep -qxF "microos-liblepton: cannot list the running Lepton containers, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "podman ps failure: $(out probe-lh-proto)"

mkdir -p "${T}/other-prefix"
echo keep > "${T}/other-prefix/file"
for label in "${T}/other-context" ""; do
    echo "lepton-probe-lh-proto running ${label}" >> "${STATE}/containers"
    printf '%s\n' "${T}/other-prefix" > "${STATE}/prefix-lepton-probe-lh-proto"
    : > "${STATE}/podman"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: lepton-probe-lh-proto belongs to ${label:-another flow}, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "same name, label '${label}': $(out probe-lh-proto)"
    grep -qx "lepton-probe-lh-proto running ${label}" "${STATE}/containers" || fail "same name, label '${label}': container changed"
    grep -q "^podman \(stop\|rm\|run\|exec\) " "${STATE}/podman" && fail "same name, label '${label}': $(grep '^podman \(stop\|rm\|run\|exec\) ' "${STATE}/podman")"
    [[ -f "${T}/other-prefix/file" ]] || fail "same name, label '${label}': its prefix removed"
    sed -i '/^lepton-probe-lh-proto /d' "${STATE}/containers"
done
rm -f "${STATE}/prefix-lepton-probe-lh-proto"
: > "${STATE}/exists-fail"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/exists-fail"
grep -qxF "microos-liblepton: podman container exists failed (rc=125), refusing" "${STATE}/out-probe-lh-proto" \
    || fail "podman container exists failure: $(out probe-lh-proto)"
echo "lepton-probe-lh-proto exited ${ctx}" >> "${STATE}/containers"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "own leftover container: exit ${rc}: $(out probe-lh-proto)"
mkdir -p "${T}/own-prefix"
echo keep > "${T}/own-prefix/file"
echo "lepton-probe-lh-proto running ${ctx}" >> "${STATE}/containers"
printf '%s\n' "${T}/own-prefix" > "${STATE}/prefix-lepton-probe-lh-proto"
: > "${STATE}/podman"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: lepton-probe-lh-proto runs, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "same context running: $(out probe-lh-proto)"
grep -qx "lepton-probe-lh-proto running ${ctx}" "${STATE}/containers" || fail "same context running: container changed"
grep -q "^podman \(stop\|rm\|run\|exec\) " "${STATE}/podman" && fail "same context running: $(grep '^podman \(stop\|rm\|run\|exec\) ' "${STATE}/podman")"
[[ -f "${T}/own-prefix/file" ]] || fail "same context running: its prefix removed"
sed -i '/^lepton-probe-lh-proto /d' "${STATE}/containers"
echo "lepton-probe-lh-proto exited ${ctx}" >> "${STATE}/containers"
: > "${STATE}/running-fail"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/running-fail"
grep -qxF "microos-liblepton: lepton-probe-lh-proto runs, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "same context, state unreadable: $(out probe-lh-proto)"
sed -i '/^lepton-probe-lh-proto /d' "${STATE}/containers"
printf 'echo %q >> %q\n' "lepton-probe-lh-proto running ${ctx}" "${STATE}/containers" > "${STATE}/after-source"
link="${ctx}/baked/data_overlay/misc"
mv "${link}" "${T}/kept"
ln -s "${T}/outside" "${link}"
echo create_prefix > "${STATE}/call"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/call"
unplant
grep -qxF "microos-liblepton: ${link} is a link, refusing" "${STATE}/out-probe-lh-proto" || fail "adopted prefix: $(out probe-lh-proto)"
[[ -f "${T}/own-prefix/file" ]] || fail "a refusal removed the prefix Lepton took from the running container"
sed -i '/^lepton-probe-lh-proto /d' "${STATE}/containers"
rm -rf "${T:?}/own-prefix" "${STATE:?}/prefix-lepton-probe-lh-proto"
mkdir -p "${T}/own-prefix"
echo keep > "${T}/own-prefix/file"
for adopted in "${T}/own-prefix" ""; do
    printf '%s\n' "${adopted}" > "${STATE}/prefix-lepton-probe-lh-proto"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: LEPTON_PREFIX=${adopted} is not the prefix this start made, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "prefix '${adopted}' taken at setup_mounts: $(out probe-lh-proto)"
    sed -i '/^lepton-probe-lh-proto /d' "${STATE}/containers"
done
rm "${STATE}/after-source"
[[ -f "${T}/own-prefix/file" ]] || fail "prefix taken at setup_mounts: the prefix was removed"
rm -rf "${T:?}/own-prefix" "${STATE:?}/prefix-lepton-probe-lh-proto"

mkdir -p "${valve_home}/.local/share/Steam/steamapps"
printf '"appid" "77"\n"name" "probe-lh-proto"\n"installdir" "game"\n' > "${STATE}/appmanifest_77.acf"
cp "${STATE}/appmanifest_77.acf" "${valve_home}/.local/share/Steam/steamapps/"
: > "${STATE}/events-probe-lh-proto"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: ${valve_home}/.local/share/Steam/steamapps holds app manifests, refusing" \
    "${STATE}/out-probe-lh-proto" || fail "app manifest at start: $(out probe-lh-proto)"
grep -q setup_mounts "${STATE}/events-probe-lh-proto" && fail "app manifest at start: Lepton's setup_mounts ran"
rm "${valve_home}/.local/share/Steam/steamapps/appmanifest_77.acf"
printf 'cp %q %q\n' "${STATE}/appmanifest_77.acf" "${valve_home}/.local/share/Steam/steamapps/" > "${STATE}/after-source"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/after-source" "${valve_home}/.local/share/Steam/steamapps/appmanifest_77.acf"
grep -qxF "microos-liblepton: Lepton switched to steamlaunch-77 on ${valve_home}/.local/share/Steam/steamapps/compatdata/77, refusing" \
    "${STATE}/out-probe-lh-proto" || fail "app manifest after the check: $(out probe-lh-proto)"
[[ ! -e "${STATE}/events-steamlaunch-77" ]] || fail "app manifest after the check: Lepton's setup_mounts ran"
echo fake_shader_path > "${STATE}/call"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/call"
grep -qxF "microos-liblepton: Lepton set STEAM_COMPAT_SHADER_PATH, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "a Steam variable set after the check: $(out probe-lh-proto)"
grep -q setup_mounts "${STATE}/events-probe-lh-proto" && fail "a Steam variable set after the check: Lepton's setup_mounts ran"
echo fake_data_path > "${STATE}/call"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/call"
grep -qxF "microos-liblepton: Lepton switched to probe-lh-proto on ${STATE}/other-data, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "STEAM_COMPAT_DATA_PATH changed after the check: $(out probe-lh-proto)"
grep -q setup_mounts "${STATE}/events-probe-lh-proto" && fail "STEAM_COMPAT_DATA_PATH changed after the check: Lepton's setup_mounts ran"
intact "${ctx}" "app manifest"

for rel in internal external media0 baked/data_workdir baked/app_workdir baked/app_overlay baked/app_lowerdir \
    baked/data_overlay/misc/ethernet baked/data_overlay/misc/ethernet/ipconfig.txt baked/data_overlay/steamvr \
    baked/data_overlay/steamvr/runtime baked/data_overlay/steam_app; do
    link="${ctx}/${rel}"
    [[ ! -e "${link}" ]] || mv "${link}" "${T}/kept"
    if [[ "${rel}" == */ipconfig.txt ]]; then
        ln -s "${T}/outside/ipconfig.txt" "${link}"
    else
        ln -s "${T}/outside" "${link}"
    fi
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: ${link} is a link, refusing" "${STATE}/out-probe-lh-proto" || fail "${rel} a link: $(out probe-lh-proto)"
    [[ "$(snapshot "${T}/outside")" == "${before}" ]] || fail "${rel} a link: outside changed: $(snapshot "${T}/outside")"
    rm "${link}"
    [[ ! -e "${T}/kept" ]] || mv "${T}/kept" "${link}"
done
intact "${ctx}" "planted links"
: > "${STATE}/no-data-bind"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/no-data-bind"
grep -qxF "microos-liblepton: Lepton binds ${contexts} 0 times, not once, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "no contexts bind: $(out probe-lh-proto)"
logs="${HOME}/.local/state/microos-lepton/steamvr-logs"
: > "${STATE}/no-logs-bind"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE:?}/no-logs-bind"
grep -qxF "microos-liblepton: Lepton binds ${logs} 0 times, not once, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "no logs bind: $(out probe-lh-proto)"
for count in 0 2; do
    echo "${count}" > "${STATE}/shm-binds"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton binds /dev/shm ${count} times, not once, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "${count} /dev/shm binds: $(out probe-lh-proto)"
done
rm "${STATE}/shm-binds"
for count in 0 2; do
    echo "${count}" > "${STATE}/runtime-binds"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton binds /data/steamvr/runtime ${count} times, not once, refusing" \
        "${STATE}/out-probe-lh-proto" || fail "${count} SteamVR runtime binds: $(out probe-lh-proto)"
done
rm "${STATE}/runtime-binds"

mkdir -p "${contexts}/probe-lh-a"
for extra in "--mount|type=bind,source=${contexts},destination=/x,ro|${contexts}" \
    "--mount|type=bind,src=${contexts}/probe-lh-a,destination=/x,ro|${contexts}/probe-lh-a" \
    "-v|${valve_home}:/x|${valve_home}" \
    "--volume|/|/" \
    "--volume=${ctx}/internal:/x|${ctx}/internal" \
    "--mount=type=bind,source=${ctx}/baked,destination=/x|${ctx}/baked" \
    "-v|${rt}/sysbake:/x:O,upperdir=${ctx}/baked,workdir=${ctx}/baked/data_workdir|${ctx}/baked" \
    "-v|${rt}/sysbake:/x:O,upperdir=${T}/up,workdir=${contexts}/probe-lh-a/work|${contexts}/probe-lh-a/work" \
    "--mount|type=bind,source=${T}/linked,destination=/x,ro|${T}/linked"; do
    IFS='|' read -ra parts <<< "${extra}"
    printf '%s\n' "${parts[@]:0:${#parts[@]}-1}" > "${STATE}/extra-mounts"
    ln -sfn "${contexts}/probe-lh-a" "${T}/linked"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton binds ${parts[-1]}, at, above or under ${contexts}, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "extra mount ${parts[*]}: $(out probe-lh-proto)"
done
printf '%s\n' "--mount" "type=bind,source=${XDG_RUNTIME_DIR}/microos-android/lineage-system.rc,destination=/system/etc/init/lineage-system.rc,ro" \
    > "${STATE}/extra-mounts"
mkdir -p "${XDG_RUNTIME_DIR}/microos-android"
: > "${XDG_RUNTIME_DIR}/microos-android/lineage-system.rc"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "a bind from the runtime dir, where the rc override lives, was refused: $(out probe-lh-proto)"
grep -qxF "type=bind,source=${XDG_RUNTIME_DIR}/microos-android/lineage-system.rc,destination=/system/etc/init/lineage-system.rc,ro" \
    "${STATE}/run-lepton-probe-lh-proto" || fail "the runtime dir bind did not reach podman"
rm -f "${STATE}/extra-mounts" "${T}/linked"
for conf in "mounts = [\"type=bind,source=${contexts}/probe-lh-a,destination=/x,ro\"]|${contexts}/probe-lh-a" \
    "mounts = [\"type=bind,source=${T}/odm.prop,destination=/y,ro\", \"type=bind,src=${valve_home}/.local,destination=/x\"]|${valve_home}/.local"; do
    printf '[containers]\n%s\n' "${conf%|*}" > "${T}/bad.conf"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/bad.conf" \
        "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton binds ${conf##*|}, at, above or under ${contexts}, refusing" "${STATE}/out-probe-lh-proto" \
        || fail "CONTAINERS_CONF_OVERRIDE ${conf}: $(out probe-lh-proto)"
done
printf "[containers]\nmounts = [\"type=bind,source=%s:/x'y\"]\n" "${T}/odm.prop" > "${T}/bad.conf"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/bad.conf" \
    "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: ${T}/bad.conf holds a quote or a backslash, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "CONTAINERS_CONF_OVERRIDE with a quote: $(out probe-lh-proto)"
printf '[containers]\nmounts = ["type=bind,source=%s/baked/absent:/x"]\n' "${ctx}" > "${T}/bad.conf"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/bad.conf" \
    "${launcher}" start probe-lh-proto
grep -q "and cannot be resolved, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "CONTAINERS_CONF_OVERRIDE with an unresolvable source: $(out probe-lh-proto)"
printf '[containers]\nvolumes = ["%s:/x"]\n' "${T}/odm.prop" > "${T}/bad.conf"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/bad.conf" \
    "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: ${T}/bad.conf sets volumes, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "CONTAINERS_CONF_OVERRIDE with volumes: $(out probe-lh-proto)"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/absent.conf" \
    "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: cannot read ${T}/absent.conf, refusing" "${STATE}/out-probe-lh-proto" \
    || fail "CONTAINERS_CONF_OVERRIDE missing: $(out probe-lh-proto)"
rm -rf "${T:?}/bad.conf" "${contexts:?}/probe-lh-a"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" CONTAINERS_CONF_OVERRIDE="${T}/containers.conf" \
    "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "the overlay dirs and a CONTAINERS_CONF_OVERRIDE outside the contexts dir refused: $(out probe-lh-proto)"
grep -qxF -- "-v" "${run_args}" && grep -qF "upperdir=${ctx}/baked/data_overlay,workdir=${ctx}/baked/data_workdir" "${run_args}" \
    && grep -qF "${ctx}/baked/app_lowerdir:/data/steam_app:O,upperdir=${ctx}/baked/app_overlay,workdir=${ctx}/baked/app_workdir" \
        "${run_args}" || fail "the overlay mounts did not reach podman: $(grep -n -A1 -- '^-v$' "${run_args}")"
intact "${ctx}" "mount audit"

grep -qx "set adb-dialog package disable --user 0 com.android.systemui/.usb.UsbDebuggingActivity" "${opts}" \
    || fail "opts do not disable the USB debugging dialog"
grep -qx "set adb-expiry settings put global adb_allowed_connection_time 0" "${opts}" || fail "opts do not keep adb keys"

: > "${STATE}/early"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE}/early"
[[ "${rc}" == 0 ]] || fail "early exit: exit ${rc}"
grep -q "kept the baked app data, asked to clear it for early exit" "${STATE}/out-probe-lh-proto" || fail "early exit: not logged"
intact "${ctx}" "early exit"

mkdir -p "${T}/outside3/probe-lh-proto"
echo outside > "${T}/outside3/file"
echo outside > "${T}/outside3/probe-lh-proto/file"
before3=$(snapshot "${T}/outside3")
marker="${ctx}/baked/data_overlay/lepton-on-app-exit"
run_args="${STATE}/run-lepton-probe-lh-proto"
shared="${STATE}/steamvr/logs"
rm -rf "${shared:?}/lepton-logcats"
ln -s "${T}/outside3" "${shared}/lepton-logcats"
ln -sfn "${T}/outside3/file" "${shared}/lepton-probe-lh-proto.log"
guest="${ctx}/baked/data_overlay/steamvr/logs"
printf 'mkdir -p %q\nln -sfn %q %q\nln -sfn %q %q\nln -sfn %q %q\n' "${guest}" "${T}/outside3" "${guest}/lepton-logcats" \
    "${T}/outside3/file" "${guest}/lepton-probe-lh-proto.log" "${T}/outside3/marker" "${marker}" > "${STATE}/after-run"
: > "${STATE}/early"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
rm "${STATE:?}/early" "${STATE:?}/after-run"
[[ "${rc}" == 0 ]] || fail "guest links: exit ${rc}: $(out probe-lh-proto)"
[[ "$(snapshot "${T}/outside3")" == "${before3}" && ! -e "${T}/outside3/marker" ]] \
    || fail "guest links: outside changed: $(snapshot "${T}/outside3")"
grep -q 'destination=/data/steamvr/logs' "${run_args}" && fail "guest links: a bind at /data/steamvr/logs"
grep -qF "${logs}" "${run_args}" && fail "${logs} is bound into the guest"
view=$(sed -n 1p "${STATE}/paths-probe-lh-proto")
[[ "${view}" == "${run_dir}"/tool.* && "$(cat "${STATE}/onexit-probe-lh-proto")" == "${view}/lepton-on-app-exit" ]] \
    || fail "exit marker not in this start's view: $(cat "${STATE}/onexit-probe-lh-proto")"
[[ "$(cat "${logs}/lepton-probe-lh-proto.log")" == "Lepton starting up"$'\n'logcat ]] \
    || fail "Lepton's log not in ${logs}: $(ls -A "${logs}")"
[[ -f "${logs}/lepton-logcats/probe-lh-proto/logcat-main.log" ]] || fail "early exit logcat not in ${logs}"
compgen -G "${STATE}/lepton-context.*" > /dev/null && fail "guest links: Lepton's prefix left"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "after guest links: exit ${rc}: $(out probe-lh-proto)"
[[ "$(snapshot "${T}/outside3")" == "${before3}" && ! -e "${T}/outside3/marker" ]] \
    || fail "after guest links: outside changed: $(snapshot "${T}/outside3")"
[[ -f "${logs}/lepton-probe-lh-proto.prev.log" && ! -e "${logs}/lepton-logcats/probe-lh-proto" ]] \
    || fail "the next start did not rotate and clear in ${logs}: $(ls -AR "${logs}")"
[[ "$(ls -A "${shared}")" == lepton-logcats$'\n'lepton-probe-lh-proto.log && -L "${shared}/lepton-logcats" \
    && -L "${shared}/lepton-probe-lh-proto.log" ]] || fail "the SteamVR logs dir was written: $(ls -Al "${shared}")"
[[ -L "${guest}/lepton-logcats" && -L "${guest}/lepton-probe-lh-proto.log" ]] || fail "the guest's links were removed"
rm -f "${marker:?}" "${shared:?}/lepton-logcats" "${shared:?}/lepton-probe-lh-proto.log" "${guest:?}/lepton-logcats" \
    "${guest:?}/lepton-probe-lh-proto.log"

for line in StopPropagatedFrom=gamescope-session-plus@android.service \
    Type=notify NotifyAccess=all TimeoutStartSec=120 TimeoutStopSec=20 SuccessExitStatus=143 \
    ExecStartPre=/usr/bin/podman\ rm\ -fi\ lepton-android ExecStart=/usr/libexec/microos/microos-android-run \
    ExecStop=/usr/libexec/microos/microos-android-stop \
    ExecStopPost=/usr/libexec/microos/microos-android-stop\ --post; do
    grep -qF "${line}" "${unit}" || fail "microos-android.service lacks ${line}: $(cat "${unit}")"
done
grep -q SuccessExitStatus=137 "${unit}" && fail "microos-android.service treats 137 as a success status"
: > "${STATE}/events-probe-lh-proto"
STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto > "${STATE}/out-probe-lh-proto" 2>&1 &
pid=$!
running probe-lh-proto "${pid}" || fail "SIGTERM: never ran: $(out probe-lh-proto)"
kill -TERM "${pid}"
gone "${pid}" || { kill -9 "${pid}"; fail "SIGTERM: still running after 10 s"; }
rc=0
wait "${pid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "SIGTERM: exit ${rc}"
grep -q "Signal SIGTERM received" "${STATE}/out-probe-lh-proto" || fail "SIGTERM: Valve's handler did not run: $(out probe-lh-proto)"
[[ "$(grep -c teardown "${STATE}/events-probe-lh-proto")" == 1 ]] || fail "SIGTERM: teardown did not finish once"
intact "${ctx}" "SIGTERM"
[[ ! -e "${ctx}/baked/data_workdir" ]] || fail "SIGTERM: data workdir left"
grep -q "^lepton-probe-lh-proto " "${STATE}/containers" && fail "SIGTERM: container left"

: > "${STATE}/stop-fail"
STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto > "${STATE}/out-probe-lh-proto" 2>&1 &
pid=$!
running probe-lh-proto "${pid}" || fail "stop fails: never ran: $(out probe-lh-proto)"
kill -TERM "${pid}"
gone "${pid}" || { kill -9 "${pid}"; fail "stop fails: still running after 10 s"; }
wait "${pid}" || true
rm "${STATE}/stop-fail"
grep -qxF "microos-liblepton: lepton-probe-lh-proto still runs, kept the workdirs in ${ctx}/baked" "${STATE}/out-probe-lh-proto" \
    || fail "stop fails: $(out probe-lh-proto)"
[[ -d "${ctx}/baked/data_workdir" ]] || fail "stop fails: the workdir of a running container was cleared"
podman stop -t 0 lepton-probe-lh-proto >/dev/null
podman rm lepton-probe-lh-proto >/dev/null

STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto > "${STATE}/out-probe-lh-proto" 2>&1 &
pid=$!
running probe-lh-proto "${pid}" || fail "baked a link: never ran: $(out probe-lh-proto)"
mkdir -p "${T}/outside-baked/data_workdir/work" "${T}/outside-baked/app_workdir/work"
mv "${ctx}/baked" "${T}/baked.real"
ln -s "${T}/outside-baked" "${ctx}/baked"
podman stop -t 0 lepton-probe-lh-proto >/dev/null
rc=0
wait "${pid}" || rc=$?
[[ "${rc}" == 0 ]] || fail "baked a link: exit ${rc}: $(out probe-lh-proto)"
[[ -d "${T}/outside-baked/data_workdir/work" && -d "${T}/outside-baked/app_workdir/work" ]] \
    || fail "baked a link at the stop: the workdirs behind it were cleared"
rm "${ctx}/baked"
mv "${T}/baked.real" "${ctx}/baked"

cycle probe-lh-proto direct STEAM_COMPAT_DATA_PATH="${ctx}" "$(views)/lepton" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "view without LEPTON_NO_CLEANUP: exit ${rc}: $(out probe-lh-proto)"
grep -q '^LEPTON_NO_CLEANUP=\|^LEPTON_KEEP_CONTEXT=' "${STATE}/env-probe-lh-proto" && fail "view run: cleanup guards were set"
intact "${ctx}" "view without LEPTON_NO_CLEANUP or LEPTON_KEEP_CONTEXT"

control="${contexts}/probe-lh-control"
seed "${control}"
unseed_modes "${control}"
cycle probe-lh-control env -i HOME="${valve_home}" PATH="${PATH}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${T}/steam-empty" STEAM_COMPAT_DATA_PATH="${control}" LEPTON_ADB_PORT=15655 \
    MICROOS_GUEST_CMD="${T}/guest-cmd" "${rt}/lepton" start probe-lh-control
[[ "${rc}" == 0 ]] || fail "control: exit ${rc}: $(out probe-lh-control)"
[[ ! -e "${control}/baked" ]] || fail "control: the fake Valve teardown kept the baked data"
grep -q '^--network=pasta:.*,--map-gw,-t,auto,-u,auto,' "${STATE}/run-lepton-probe-lh-control" || fail "control: Valve's network options"
[[ "$(cat "${STATE}/onexit-probe-lh-control")" == "${control}/baked/data_overlay/lepton-on-app-exit" ]] \
    || fail "control: Valve's exit marker: $(cat "${STATE}/onexit-probe-lh-control")"
grep -qxF "type=bind,source=${STATE}/steamvr/logs,destination=/data/steamvr/logs,rw" "${STATE}/run-lepton-probe-lh-control" \
    && [[ -f "${STATE}/steamvr/logs/lepton-probe-lh-control.log" ]] || fail "control: Valve's SteamVR logs dir"
rm -rf "${control:?}"

fresh="${contexts}/probe-lh-fresh"
cycle probe-lh-fresh env STEAM_COMPAT_DATA_PATH="${fresh}" "${launcher}" start probe-lh-fresh
[[ "${rc}" == 0 && -d "${fresh}/internal" && -d "${fresh}/baked/data_overlay" ]] || fail "fresh context: exit ${rc}: $(out probe-lh-fresh)"
rm -rf "${fresh:?}"
ln -s "${T}/outside" "${fresh}"
rc=0
STEAM_COMPAT_DATA_PATH="${fresh}" timeout -k 2 20 "${launcher}" start probe-lh-fresh > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: ${fresh} is a link, refusing" "${STATE}/out" || fail "context link: exit ${rc}: $(cat "${STATE}/out")"
[[ "$(snapshot "${T}/outside")" == "${before}" ]] || fail "context link: outside changed"
rm "${fresh}"

pipe="${valve_home}/.steam/steam.pipe"
mv "${pipe}" "${T}/other.pipe"
ln -s "${T}/other.pipe" "${pipe}"
rc=0
STEAM_COMPAT_DATA_PATH="${ctx}" timeout -k 2 20 "${launcher}" start probe-lh-proto > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qxF "microos-lepton: cannot make the FIFO ${pipe}" "${STATE}/out" || fail "pipe link: exit ${rc}: $(cat "${STATE}/out")"
rm "${pipe}"
mv "${T}/other.pipe" "${pipe}"

for pair in Documents:Documents Downloads:Download Videos:Movies; do
    host="${valve_home}/${pair%%:*}"
    guest="${ctx}/external/${pair#*:}"
    mkdir -p "${host}" "${guest}"
    echo kept > "${guest}/file"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton replaces ${guest} with a link to ${host} at start, move what it holds into ${host} first" \
        "${STATE}/out-probe-lh-proto" || fail "${pair}: refusal text: $(out probe-lh-proto)"
    [[ -f "${guest}/file" ]] || fail "${pair}: guest dir lost"
    rm -rf "${host:?}"
    cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    [[ "${rc}" == 0 && -f "${guest}/file" ]] || fail "${pair}: no host dir: exit ${rc}"
    rm -rf "${guest:?}"
    mkdir -p "${host}" "${guest}"
    cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    [[ "${rc}" == 0 ]] || fail "${pair}: empty guest dir refused: $(out probe-lh-proto)"
    [[ -L "${guest}" ]] || fail "${pair}: the fake setup_mounts did not link the host dir"
    cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    [[ "${rc}" == 0 ]] || fail "${pair}: linked guest dir refused: $(out probe-lh-proto)"
    rm -rf "${host:?}" "${guest:?}"
done
mkdir -p "${ctx}/external/Download"
echo dl > "${ctx}/external/Download/file"
mkdir -p "${valve_home}/Downloads"
mv "${ctx}/external/Download" "${T}/kept-download"
echo file > "${ctx}/external/Download"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: Lepton replaces ${ctx}/external/Download with a link to ${valve_home}/Downloads at start, move what it holds into ${valve_home}/Downloads first" \
    "${STATE}/out-probe-lh-proto" || fail "Download a file: $(out probe-lh-proto)"
[[ -f "${ctx}/external/Download" ]] || fail "Download a file: lost"
rm "${ctx}/external/Download"
mv "${T}/kept-download" "${ctx}/external/Download"
rm -rf "${valve_home:?}/Downloads"

mv "${ctx}/external" "${ctx}/media0"
mkdir -p "${valve_home}/Downloads"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: Lepton replaces ${ctx}/media0/Download with a link to ${valve_home}/Downloads at start, move what it holds into ${valve_home}/Downloads first" \
    "${STATE}/out-probe-lh-proto" || fail "media0: refusal text: $(out probe-lh-proto)"
[[ -f "${ctx}/media0/Download/file" ]] || fail "media0: Download lost"
rm -rf "${valve_home:?}/Downloads"
mv "${ctx}/media0" "${ctx}/external"

media="${ctx}/baked/data_overlay/media"
rm -rf "${media:?}/0"
mkdir -p "${media}/0"
echo pic > "${media}/0/file"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: Lepton deletes ${media}/0 at start, move what it holds into ${ctx}/external first" \
    "${STATE}/out-probe-lh-proto" || fail "media/0: refusal text: $(out probe-lh-proto)"
[[ -f "${media}/0/file" ]] || fail "media/0: lost"
refused probe-lh-proto direct STEAM_COMPAT_DATA_PATH="${ctx}" "$(views)/lepton" start probe-lh-proto
grep -qxF "microos-liblepton: Lepton deletes ${media}/0 at start, move what it holds into ${ctx}/external first" \
    "${STATE}/out-probe-lh-proto" || fail "media/0 through the view: $(out probe-lh-proto)"
[[ -f "${media}/0/file" ]] || fail "media/0 through the view: lost"
mv "${media}/0" "${T}/kept-media"
echo pic > "${media}/0"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: Lepton deletes ${media}/0 at start, move what it holds into ${ctx}/external first" \
    "${STATE}/out-probe-lh-proto" || fail "media/0 a file: $(out probe-lh-proto)"
[[ -f "${media}/0" ]] || fail "media/0 a file: lost"
rm "${media}/0"
mv "${T}/kept-media" "${media}/0"
plain="${contexts}/probe-lh-plain"
mkdir -p "${plain}/baked/data_overlay/media/0"
echo pic > "${plain}/baked/data_overlay/media/0/file"
refused probe-lh-plain env "${launcher}" start probe-lh-plain
grep -qxF "microos-liblepton: Lepton deletes ${plain}/baked/data_overlay/media/0 at start, move what it holds out of ${plain} first" \
    "${STATE}/out-probe-lh-plain" || fail "media/0 without STEAM_COMPAT_DATA_PATH: $(out probe-lh-plain)"
: > "${STATE}/unshare-fail"
refused probe-lh-plain env "${launcher}" start probe-lh-plain
grep -q "cannot read ${plain}/baked/data_overlay/media/0 (rc=125), refusing" "${STATE}/out-probe-lh-plain" \
    || fail "unshare failure: $(out probe-lh-plain)"
rm "${STATE}/unshare-fail"
rm -rf "${plain:?}/baked/data_overlay/media/0"
echo "lepton-probe-lh-plain running " >> "${STATE}/containers"
refused probe-lh-plain env "${launcher}" start probe-lh-plain
grep -qxF "microos-liblepton: lepton-probe-lh-plain belongs to another flow, refusing" "${STATE}/out-probe-lh-plain" \
    || fail "same name, no label on either: $(out probe-lh-plain)"
grep -qx "lepton-probe-lh-plain running " "${STATE}/containers" || fail "same name, no label on either: container changed"
sed -i '/^lepton-probe-lh-plain /d' "${STATE}/containers"
cycle probe-lh-plain env "${launcher}" start probe-lh-plain
[[ "${rc}" == 0 ]] || fail "no STEAM_COMPAT_DATA_PATH: exit ${rc}: $(out probe-lh-plain)"
grep -F "${contexts}" "${STATE}/run-lepton-probe-lh-plain" | grep -vF ":O,upperdir=${contexts}/probe-lh-plain/baked/" \
    && fail "no STEAM_COMPAT_DATA_PATH: a contexts path is bound"
rm -rf "${media:?}/0"
ln -s "${ctx}/external" "${media}/0"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "media/0 link refused: $(out probe-lh-proto)"
intact "${ctx}" "media/0 link"

for count in 0 2; do
    echo "${count}" > "${STATE}/cmd-binds"
    refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
    grep -qxF "microos-liblepton: Lepton binds /system/bin/cmd ${count} times, not once, refusing" \
        "${STATE}/out-probe-lh-proto" || fail "${count} cmd binds: $(out probe-lh-proto)"
done
rm "${STATE}/cmd-binds"
cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" MICROOS_GUEST_CMD="${T}/guest-cmd" \
    "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 ]] || fail "the guest cmd swap: exit ${rc}: $(out probe-lh-proto)"
[[ "$(grep -c ',destination=/system/bin/cmd,' "${STATE}/run-lepton-probe-lh-proto")" == 1 \
    && "$(grep ',destination=/system/bin/cmd,' "${STATE}/run-lepton-probe-lh-proto")" \
        == "type=bind,source=${T}/guest-cmd,destination=/system/bin/cmd,ro" ]] \
    || fail "the guest cmd bind is $(grep -E 'source=|/system/bin/cmd' "${STATE}/run-lepton-probe-lh-proto" | tr '\n' ' ')"
grep -qF "images/rootfs_overlay/system/bin/cmd" "${STATE}/run-lepton-probe-lh-proto" \
    && fail "Valve's own cmd is still bound"
refused probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" MICROOS_GUEST_CMD="${T}/absent" \
    "${launcher}" start probe-lh-proto
grep -qxF "microos-liblepton: the guest cmd ${T}/absent is not a regular file, refusing" \
    "${STATE}/out-probe-lh-proto" || fail "a guest cmd that is not a file: $(out probe-lh-proto)"
cat > "${T}/guest-cmd-swap" <<'SWAP'
eval "$(sed -n '/^microos_cmd_mount()/,/^}/p;/^microos_guest_cmd()/,/^}/p' "$1")"
microos_refuse() { printf 'microos-liblepton: %s\n' "$*" >&2; exit 1; }
shift
if [[ -n "${GUEST_CMD:-}" ]]; then
    MICROOS_GUEST_CMD=${GUEST_CMD}
else
    unset MICROOS_GUEST_CMD
fi
PODMAN_CMDLINE=("$@")
microos_guest_cmd
printf '%s\n' "${PODMAN_CMDLINE[@]}"
SWAP
real_unshare=$(PATH=/usr/bin:/bin command -v unshare) || real_unshare=
if [[ -n "${real_unshare}" ]] && "${real_unshare}" -rm true 2>/dev/null; then
    guest_cmd_swap() {
        rc=0
        out=$(GUESTOS_CMD=$1 GUEST_CMD=$2 "${real_unshare}" -rm sh -c 'mount -t tmpfs none /usr/share || exit 1
            printf "#!/system/bin/sh\n" > /usr/share/microos-android-cmd || exit 1
            mkdir -p /usr/share/microos-android && mv /usr/share/microos-android-cmd /usr/share/microos-android/cmd || exit 1
            if [ -n "${GUESTOS_CMD}" ]; then
                mkdir -p "$(dirname "${GUESTOS_CMD}")" && : > "${GUESTOS_CMD}" || exit 1
            fi
            exec bash "$@"' sh "${T}/guest-cmd-swap" "${override}" "${@:3}" 2>&1) || rc=$?
    }
    guestos=/usr/share/guestos/android/system/bin/cmd
    canonical="type=bind,source=/valve/images/rootfs_overlay/system/bin/cmd,destination=/system/bin/cmd,ro"
    swapped_mount="type=bind,source=/usr/share/microos-android/cmd,destination=/system/bin/cmd,ro"
    guest_cmd_swap "" "" --mount "${canonical}" --mount "type=bind,source=/x,destination=/y,ro"
    [[ "${rc}" == 0 && "${out}" == $'--mount\n'"${swapped_mount}"$'\n--mount\ntype=bind,source=/x,destination=/y,ro' ]] \
        || fail "the default guest cmd: exit ${rc}: ${out}"
    guest_cmd_swap "${guestos}" "" --mount "${canonical}" --mount "type=bind,source=/x,destination=/y,ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: ${guestos} is a second guest cmd, refusing" ]] \
        || fail "a guestos cmd: exit ${rc}: ${out}"
    guest_cmd_swap "" /usr/share/microos-android/absent --mount "${canonical}"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: the guest cmd /usr/share/microos-android/absent is not a regular file, refusing" ]] \
        || fail "a guest cmd that is not a file: exit ${rc}: ${out}"
    guest_cmd_swap "" /usr/share/microos-android --mount "${canonical}"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: the guest cmd /usr/share/microos-android is not a regular file, refusing" ]] \
        || fail "a guest cmd that is a directory: exit ${rc}: ${out}"
    for form in "dst=/system/bin/cmd" "target=/system/bin/cmd"; do
        guest_cmd_swap "" "" --mount "type=bind,source=/valve/x,${form},ro"
        [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd in a form MicroOS does not rewrite, refusing" ]] \
            || fail "a cmd mount as ${form}: exit ${rc}: ${out}"
    done
    guest_cmd_swap "" "" "--mount=type=bind,source=/valve/x,destination=/system/bin/cmd,ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd in a form MicroOS does not rewrite, refusing" ]] \
        || fail "a --mount= cmd: exit ${rc}: ${out}"
    guest_cmd_swap "" "" -v "/valve/y:/system/bin/cmd:ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd in a form MicroOS does not rewrite, refusing" ]] \
        || fail "a -v cmd: exit ${rc}: ${out}"
    guest_cmd_swap "" "" --mount "type=bind,destination=/system/bin/cmd,ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd with no source=, refusing" ]] \
        || fail "a cmd mount with no source: exit ${rc}: ${out}"
    guest_cmd_swap "" "" --mount "${canonical}" "--mount=type=bind,source=/valve/y,destination=/system/bin/cmd,ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd 2 times, not once, refusing" ]] \
        || fail "a --mount= cmd beside the canonical one: exit ${rc}: ${out}"
    guest_cmd_swap "" "" --mount "${canonical}" -v "/valve/y:/system/bin/cmd:ro"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd 2 times, not once, refusing" ]] \
        || fail "a -v cmd beside the canonical one: exit ${rc}: ${out}"
    guest_cmd_swap "" "" --mount "${canonical}" --volume "/valve/y:/system/bin/cmd"
    [[ "${rc}" == 1 && "${out}" == "microos-liblepton: Lepton binds /system/bin/cmd 2 times, not once, refusing" ]] \
        || fail "a --volume cmd beside the canonical one: exit ${rc}: ${out}"
else
    echo "skip: unshare -rm cannot run, the guest cmd forms are not tested"
fi

for fn in setup_mounts setup_props prepare_baked_data_for_removal clear_baked_app_data cleanup_container cleanup_all \
    kill_all wipe_baked_system_data podman_network_options get_baked_app_data_dir data_mount_path kill_container \
    podman_ip podman_subnet adb_port create_prefix setup_podman_mounts setup_podman_base onexit_path determine_app; do
    rm -rf "${T:?}/snap-guard"
    mkdir -p "${T}/snap-guard"
    make_runtime "${T}/snap-guard/25772114" "${fn}"
    marker "${T}/snap-guard/25772114"
    mkdir -p "${T}/reviewed-guard"
    cp "${T}/snap-guard/25772114.reviewed" "${T}/reviewed-guard/25772114"
    refused probe-lh-guard env MICROOS_LEPTON_SNAPSHOTS="${T}/snap-guard" MICROOS_LEPTON_REVIEWED="${T}/reviewed-guard" \
        "${launcher}" start probe-lh-guard
    grep -qxF "microos-liblepton: Lepton in ${T}/snap-guard/25772114 has no ${fn}, refusing" "${STATE}/out-probe-lh-guard" \
        || fail "guard ${fn}: $(out probe-lh-guard)"
done
rm -rf "${T:?}/snap-guard" "${T:?}/reviewed-guard"

cycle probe-lh-proto env STEAM_COMPAT_DATA_PATH="${ctx}" "${launcher}" start probe-lh-proto
[[ "${rc}" == 0 && "$(readlink "$(views)/lepton")" == "${rt}/lepton" ]] || fail "view on ${rt}: exit ${rc}"
ctxa="${contexts}/probe-lh-a"
ctxb="${contexts}/probe-lh-b"
seed "${ctxa}"
unseed_modes "${ctxa}"
seed "${ctxb}"
unseed_modes "${ctxb}"
listing=$(ls "${contexts}")
echo "lepton-android running " >> "${STATE}/containers"
for args in cleanup_all kill_all unreal_vr_test help "sysbake" "waitforexitandrun probe-lh-a" start \
    "start probe-lh-a extra"; do
    read -ra argv <<< "${args}"
    refused "${argv[0]}" direct GITLAB_CI=1 "$(views)/lepton" "${argv[@]}"
    grep -qxF "microos-liblepton: only start <context> runs through MicroOS, refusing ${args}" \
        "${STATE}/out-${argv[0]}" || fail "view verb '${args}': $(out "${argv[0]}")"
done
for name in dev sysbake steamlaunch-1 Probe; do
    refused "${name}" direct "$(views)/lepton" start "${name}"
    grep -q "^microos-liblepton: .*${name}.*refusing" "${STATE}/out-${name}" || fail "view context ${name}: $(out "${name}")"
done
mkdir -p "${T}/keep"
echo keep > "${T}/keep/file"
for var in SteamAppId=1 STEAM_COMPAT_INSTALL_PATH=/x STEAM_COMPAT_LIBRARY_PATHS="${T}" STEAM_COMPAT_SHADER_PATH=/x \
    LEPTON_PREFIX="${T}/keep" LEPTON_ENV_FOO=1; do
    refused probe-lh-a direct "${var}" "$(views)/lepton" start probe-lh-a
    grep -qxF "microos-liblepton: ${var%%=*} is set, refusing" "${STATE}/out-probe-lh-a" || fail "view ${var%%=*}: $(out probe-lh-a)"
done
[[ -f "${T}/keep/file" ]] || fail "a refusal removed a LEPTON_PREFIX from the caller"
account_home=$(getent passwd "$(id -u)" | cut -d: -f6)
refused probe-lh-a direct HOME="${account_home}" "$(views)/lepton" start probe-lh-a
grep -qxF "microos-liblepton: HOME is the home of $(id -un), refusing" "${STATE}/out-probe-lh-a" || fail "view with the account HOME: $(out probe-lh-a)"
refused probe-lh-a direct STEAM_COMPAT_DATA_PATH="${ctxb}" "$(views)/lepton" start probe-lh-a
grep -qxF "microos-liblepton: STEAM_COMPAT_DATA_PATH is not ${ctxa}, refusing" "${STATE}/out-probe-lh-a" \
    || fail "view with another context's data: $(out probe-lh-a)"
mkdir -p "${T}/view-changed/liblepton" "${T}/changed-review"
ln -s "${T}/rt-changed/25772114/lepton" "${T}/view-changed/lepton"
ln -s "${override}" "${T}/view-changed/liblepton/liblepton.sh"
for change in xattrs sdk reviewed; do
    rm -rf "${T}/rt-changed"
    mkdir -p "${T}/rt-changed"
    cp -a "${rt}" "${T}/rt-changed/25772114"
    list="${MICROOS_LEPTON_REVIEWED}"
    want="microos-liblepton: Lepton in ${T}/rt-changed/25772114 is not the build in ${list}/25772114, refusing"
    case "${change}" in
        xattrs) echo >> "${T}/rt-changed/25772114/sysbake.xattrs" ;;
        sdk)
            sed -i 's/sdk=30/sdk=31/' "${T}/rt-changed/25772114/images/rootfs/system/build.prop"
            want="microos-liblepton: Lepton in ${T}/rt-changed/25772114 is not Android SDK 30, refusing"
            ;;
        reviewed)
            list="${T}/changed-review"
            want="microos-liblepton: Lepton build 25772114 is not one MicroOS knows, refusing"
            ;;
    esac
    refused probe-lh-a direct MICROOS_LEPTON_RUNTIME="${T}/rt-changed/25772114" MICROOS_LEPTON_REVIEWED="${list}" \
        STEAM_COMPAT_DATA_PATH="${ctxa}" "${T}/view-changed/lepton" start probe-lh-a
    grep -qxF "${want}" "${STATE}/out-probe-lh-a" || fail "view on a runtime with ${change} changed: $(out probe-lh-a)"
done
rm -rf "${T:?}/rt-changed" "${T:?}/view-changed" "${T:?}/changed-review"
for fn in cleanup_all kill_all wipe_baked_system_data; do
    echo "${fn}" > "${STATE}/call"
    refused probe-lh-a env STEAM_COMPAT_DATA_PATH="${ctxa}" "${launcher}" start probe-lh-a
    grep -q "^microos-liblepton: ${fn} .*, refusing" "${STATE}/out-probe-lh-a" || fail "${fn} in start: $(out probe-lh-a)"
done
rm "${STATE}/call"
[[ "$(ls "${contexts}")" == "${listing}" ]] || fail "contexts changed: $(ls "${contexts}")"
intact "${ctx}" "view verbs"
intact "${ctxa}" "view verbs"
intact "${ctxb}" "view verbs"
[[ -f "${rt}/sysbake/system/packages.xml" ]] || fail "the runtime's sysbake was wiped"
grep -qx "lepton-android running " "${STATE}/containers" || fail "another context's container was stopped"
sed -i '/^lepton-android /d' "${STATE}/containers"
mkdir -p "${T}/client"
echo x > "${T}/client/file"
refused probe-lh-a direct STEAM_COMPAT_DATA_PATH="${ctxa}" STEAM_COMPAT_CLIENT_INSTALL_PATH="${T}/client" "$(views)/lepton" start probe-lh-a
grep -qxF "microos-liblepton: STEAM_COMPAT_CLIENT_INSTALL_PATH ${T}/client is not an empty directory, refusing" \
    "${STATE}/out-probe-lh-a" || fail "view with a client dir: $(out probe-lh-a)"
refused probe-lh-a env -i HOME="${valve_home}" PATH="${PATH}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    XDG_CONFIG_HOME="${HOME}/.config" LEPTON_ADB_PORT=15655 MICROOS_LEPTON_RUNTIME="${rt}" \
    MICROOS_LEPTON_REVIEWED="${MICROOS_LEPTON_REVIEWED}" MICROOS_GUEST_CMD="${T}/guest-cmd" \
    STEAM_COMPAT_DATA_PATH="${ctxa}" "$(views)/lepton" start probe-lh-a
grep -qxF "microos-liblepton: STEAM_COMPAT_CLIENT_INSTALL_PATH ${valve_home}/.local/share/Steam is not an empty directory, refusing" \
    "${STATE}/out-probe-lh-a" || fail "view without a client dir: $(out probe-lh-a)"

mkdir -p "${T}/evil"
{ printf '#!/bin/bash\nFAKE_STATE=%q\n' "${STATE}"; cat "${T}/fake-lepton"; } > "${T}/evil/lepton"
chmod 0755 "${T}/evil/lepton"
evil="${T}/evil-view"
mkdir -p "${evil}/liblepton"
ln -s "${T}/evil/lepton" "${evil}/lepton"
ln -s "${override}" "${evil}/liblepton/liblepton.sh"
refused probe-lh-race direct "${evil}/lepton" start probe-lh-race
grep -qxF "microos-liblepton: ${evil}/lepton is not ${rt}/lepton, refusing" "${STATE}/out-probe-lh-race" \
    || fail "\$0 not the runtime: $(out probe-lh-race)"
printf 'ln -sfn %q %q\n' "${rt}/lepton" "${evil}/lepton" > "${STATE}/swap-hook"
refused probe-lh-race direct "${evil}/lepton" start probe-lh-race
[[ -e "${STATE}/swap-hook.ran" ]] || fail "race: hook did not run"
grep -qxF "microos-liblepton: ${evil}/lepton is not ${rt}/lepton, refusing" "${STATE}/out-probe-lh-race" \
    || fail "race: the script read is not the runtime's: $(out probe-lh-race)"
rm -f "${STATE}/swap-hook.ran"
ln -sfn "${rt}/lepton" "${evil}/lepton"
printf 'ln -sfn %q %q\n' "${T}/evil/lepton" "${evil}/lepton" > "${STATE}/swap-hook"
refused probe-lh-race direct "${evil}/lepton" start probe-lh-race
[[ -e "${STATE}/swap-hook.ran" ]] || fail "race back: hook did not run"
grep -qxF "microos-liblepton: ${evil}/lepton is not ${rt}/lepton, refusing" "${STATE}/out-probe-lh-race" \
    || fail "race back: \$0 no longer the runtime's: $(out probe-lh-race)"
rm -f "${STATE}/swap-hook.ran"

(
    exec 9<"${run_dir}"
    flock -x 9
    : > "${STATE}/run-held"
    exec sleep 60
) &
holder=$!
for _ in $(seq 1 100); do
    [[ ! -e "${STATE}/run-held" ]] || break
    sleep 0.1
done
[[ -e "${STATE}/run-held" ]] || fail "run lock: the holder never locked"
views_before=$(views)
STEAM_COMPAT_DATA_PATH="${ctxa}" "${launcher}" start probe-lh-a > "${STATE}/out-probe-lh-a" 2>&1 &
pida=$!
for _ in $(seq 1 100); do
    pgrep -P "${pida}" -x flock > /dev/null && break
    sleep 0.1
done
pgrep -P "${pida}" -x flock > /dev/null || fail "run lock: the launcher never waited on ${run_dir}"
[[ "$(views)" == "${views_before}" ]] || fail "run lock: a view was made while ${run_dir} was locked: $(views)"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
holder=
running probe-lh-a "${pida}" || fail "run lock: A never ran after the lock was free: $(out probe-lh-a)"
podman stop -t 0 lepton-probe-lh-a >/dev/null
rc=0
wait "${pida}" || rc=$?
[[ "${rc}" == 0 ]] || fail "run lock: A exit ${rc}: $(out probe-lh-a)"

rt2="${T}/snaps2"
mkdir -p "${T}/snaps2" "${T}/reviewed2"
make_runtime "${rt2}/99999998"
marker "${rt2}/99999998"
cp "${rt2}/99999998.reviewed" "${T}/reviewed2/99999998"
STEAM_COMPAT_DATA_PATH="${ctxa}" MICROOS_LEPTON_SNAPSHOTS="${T}/snaps" "${launcher}" start probe-lh-a > "${STATE}/out-probe-lh-a" 2>&1 &
pida=$!
running probe-lh-a "${pida}" || fail "views: A never ran: $(out probe-lh-a)"
view_a=$(sed -n 1p "${STATE}/paths-probe-lh-a")
mkdir -p "${T}/config-b"
XDG_CONFIG_HOME="${T}/config-b" STEAM_COMPAT_DATA_PATH="${ctxb}" MICROOS_LEPTON_SNAPSHOTS="${T}/snaps2" MICROOS_LEPTON_REVIEWED="${T}/reviewed2" "${launcher}" start probe-lh-b \
    > "${STATE}/out-probe-lh-b" 2>&1 &
pidb=$!
running probe-lh-b "${pidb}" "${STATE}/containers-b" || fail "views: B never ran: $(out probe-lh-b)"
view_b=$(sed -n 1p "${STATE}/paths-probe-lh-b")
[[ "${view_a}" != "${view_b}" ]] || fail "views: A and B share a view"
[[ -d "${view_a}" && "$(readlink -f "${view_a}/lepton")" == "${rt}/lepton" ]] || fail "views: A's view removed while A runs"
[[ "$(readlink -f "${view_b}/lepton")" == "${rt2}/99999998/lepton" ]] || fail "views: B's view does not lead to B's runtime"
podman stop -t 0 lepton-probe-lh-a >/dev/null
rc=0
wait "${pida}" || rc=$?
[[ "${rc}" == 0 ]] || fail "views: A exit ${rc}: $(out probe-lh-a)"
[[ "$(sed -n 2p "${STATE}/paths-probe-lh-a")" == "${rt}/liblepton" ]] || fail "views: A ran on another runtime"
intact "${ctxa}" "views A"
mkdir -p "${run_dir}/tool.held" "${run_dir}/tool.stale"
(
    exec 9<"${run_dir}/tool.held"
    flock -s 9
    : > "${STATE}/held"
    exec sleep 60
) &
holder=$!
for _ in $(seq 1 100); do
    [[ ! -e "${STATE}/held" ]] || break
    sleep 0.1
done
[[ -e "${STATE}/held" ]] || fail "views: the holder never locked"
cycle probe-lh-a env STEAM_COMPAT_DATA_PATH="${ctxa}" "${launcher}" start probe-lh-a
[[ "${rc}" == 0 ]] || fail "views: A again exit ${rc}"
[[ ! -e "${view_a}" && ! -e "${run_dir}/tool.stale" ]] || fail "views: an unheld view was kept: $(views)"
[[ -d "${view_b}" && -d "${run_dir}/tool.held" ]] || fail "views: a held view was removed: $(views)"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
holder=
XDG_CONFIG_HOME="${T}/config-b" podman stop -t 0 lepton-probe-lh-b >/dev/null
rc=0
wait "${pidb}" || rc=$?
[[ "${rc}" == 0 && "$(sed -n 2p "${STATE}/paths-probe-lh-b")" == "${rt2}/99999998/liblepton" ]] || fail "views: B exit ${rc}"
intact "${ctxb}" "views B"
cycle probe-lh-a env STEAM_COMPAT_DATA_PATH="${ctxa}" "${launcher}" start probe-lh-a
[[ "$(views)" == "$(sed -n 1p "${STATE}/paths-probe-lh-a")" ]] || fail "views: finished views kept: $(views)"

steam_copy() {
    rm -rf "${T}/lib-tree"
    mkdir -p "${T}/lib-tree/steamapps/common"
    cp -a "${rt}" "${T}/lib-tree/steamapps/common/Lepton"
    cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/lib-tree.reviewed"
    printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' \
        > "${T}/lib-tree/steamapps/appmanifest_3029110.acf"
    cat > "${T}/bin/lepton-dir-tree" <<STUB
#!/usr/bin/bash
printf '%s\n' "${T}/lib-tree/steamapps/common/Lepton"
STUB
    chmod 0755 "${T}/bin/lepton-dir-tree"
}

snapshot_run() {
    rc=0
    MICROOS_LEPTON_SNAPSHOTS="$1" MICROOS_LEPTON_REVIEWED="$2" MICROOS_LEPTON_STEAM_DIR_CMD="${3}" \
        "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
}

steam_copy
mkdir -p "${T}/reviewed-stars"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772114"
rm -rf "${T}/stars"
mkdir -p "${T}/stars"
snapshot_run "${T}/stars" "${T}/reviewed-stars" "${T}/bin/lepton-dir-tree"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars/25772114" ]] || fail "first snapshot: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/stars/25772114" && ! -e "${T}/stars/.take" ]] || fail "first snapshot: not one buildid dir: $(ls -A "${T}/stars")"
diff -r --no-dereference "${T}/lib-tree/steamapps/common/Lepton" "${T}/stars/25772114" > /dev/null \
    || fail "first snapshot: not a copy of Steam's tree"
grep -qx "microos-lepton: took the snapshot ${T}/stars/25772114" "${STATE}/out" || fail "first snapshot: not logged"
before_stars=$(snapshot "${T}/stars")
snapshot_run "${T}/stars" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars/25772114" ]] || fail "snapshot only: exit ${rc}: $(cat "${STATE}/out")"
[[ "$(snapshot "${T}/stars")" == "${before_stars}" ]] || fail "snapshot only: the snapshot changed: $(snapshot "${T}/stars")"

cp -a "${rt}" "${T}/stars/25772113"
marker "${T}/stars/25772113"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772113"
snapshot_run "${T}/stars" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars/25772114" ]] || fail "two snapshots: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/stars/25772113" ]] || fail "two snapshots: the older one was removed before a new one was taken"
cp -a "${rt}" "${T}/stars/25772112"
marker "${T}/stars/25772112"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772112"
cp -a "${rt}" "${T}/stars/25772111"
marker "${T}/stars/25772111"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772111"
snapshot_run "${T}/stars" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars/25772114" ]] || fail "four snapshots: exit ${rc}: $(cat "${STATE}/out")"
[[ -e "${T}/stars/25772111" ]] || fail "four snapshots: an older build was pruned on a failed deployment list"
rm -rf "${T}/stars/25772114"
sed -i 's/buildid"\t\t"25772114/buildid"\t\t"25772113/' "${T}/lib-tree/steamapps/appmanifest_3029110.acf"
printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772113"\n\t"StateFlags"\t\t"4"\n}\n' \
    > "${T}/lib-tree/steamapps/appmanifest_3029110.acf"
snapshot_run "${T}/stars" "${T}/reviewed-stars" "${T}/bin/lepton-dir-tree"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars/25772113" ]] || fail "new build: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/stars/25772113" ]] || fail "new build: no snapshot for it"
[[ -d "${T}/stars/25772112" ]] || fail "new build: the next lower build was pruned: $(ls -A "${T}/stars")"

rm -rf "${T}/stars-up"
mkdir -p "${T}/stars-up"
cp -a "${rt}" "${T}/stars-up/25772113"
marker "${T}/stars-up/25772113"
echo broken >> "${T}/lib-tree/steamapps/common/Lepton/liblepton/utils.sh"
snapshot_run "${T}/stars-up" "${T}/reviewed-stars" "${T}/bin/lepton-dir-tree"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-up/25772113" && ! -e "${T}/stars-up/25772114" ]] \
    || fail "half updated Steam copy: exit ${rc}: $(cat "${STATE}/out")"
steam_copy
snapshot_run "${T}/stars-up" "${T}/reviewed-stars" "${T}/bin/lepton-dir-tree"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-up/25772114" && -d "${T}/stars-up/25772113" ]] \
    || fail "newer reviewed build in Steam: exit ${rc}: $(cat "${STATE}/out")"
rm -rf "${T}/stars-up"
rm -rf "${T}/stars-readonly"
rc=0
MICROOS_LEPTON_READ_ONLY=1 MICROOS_LEPTON_SNAPSHOTS="${T}/stars-readonly" MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" \
    MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-tree" "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/lib-tree/steamapps/common/Lepton" ]] \
    || fail "a read only runtime: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${T}/stars-readonly/25772114" ]] || fail "a read only runtime took a snapshot: $(ls -A "${T}/stars-readonly")"
rm -rf "${T}/stars-readonly"

rm -rf "${T}/stars-ro-bad"
mkdir -p "${T}/stars-ro-bad"
cp -a "${rt}/." "${T}/stars-ro-bad/25772113/"
printf 'rootfs=3.0.3 lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys\n' > "${T}/stars-ro-bad/.verified.25772112"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772113"
mkdir -p "${T}/stars-ro-bad/25772112"
cp -a "${rt}/." "${T}/stars-ro-bad/25772112/"
printf 'extra\n' > "${T}/stars-ro-bad/25772112/stale"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772112"
rc=0
MICROOS_LEPTON_READ_ONLY=1 MICROOS_LEPTON_SNAPSHOTS="${T}/stars-ro-bad" MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" \
    MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 ]] || fail "a read only runtime with a bad snapshot: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/stars-ro-bad/25772112" ]] || fail "a read only runtime removed a bad snapshot: $(ls -A "${T}/stars-ro-bad")"
[[ -f "${T}/stars-ro-bad/.verified.25772112" ]] || fail "a read only runtime removed a stale marker: $(ls -A "${T}/stars-ro-bad")"
grep -q "a read only run leaves the bad snapshot ${T}/stars-ro-bad/25772112" "${STATE}/out" \
    || fail "a read only runtime: the bad snapshot was not logged: $(cat "${STATE}/out")"
[[ ! -e "${T}/stars-ro-bad/.verified.25772113" ]] \
    || fail "a read only runtime wrote a missing marker: $(ls -A "${T}/stars-ro-bad")"
grep -q "has no verified marker, a read only run leaves it" "${STATE}/out" \
    || fail "a read only runtime: the missing marker was not logged: $(cat "${STATE}/out")"
[[ -d "${T}/stars-ro-bad/25772113" ]] || fail "a read only runtime removed the good snapshot: $(ls -A "${T}/stars-ro-bad")"
rm -rf "${T}/stars-ro-bad"

rm -rf "${T}/stars-ro-prune"
mkdir -p "${T}/stars-ro-prune" "${T}/bin-ostree-null"
for b in 25772114 25772113 25772112; do
    mkdir -p "${T}/stars-ro-prune/${b}"
    cp -a "${rt}/." "${T}/stars-ro-prune/${b}/"
    printf 'rootfs=3.0.3 lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys\n' > "${T}/stars-ro-prune/.verified.${b}"
    cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/${b}"
done
cat > "${T}/bin-ostree-null/ostree" <<'STUB'
#!/usr/bin/bash
case "$1 $2" in
    "admin status") printf '{"deployments": [{"checksum": "%s"}]}\n' "$(printf 'b%.0s' {1..64})"; exit 0 ;;
    "ls "*) exit 0 ;;
esac
exit 1
STUB
chmod 0755 "${T}/bin-ostree-null/ostree"
rc=0
PATH="${T}/bin-ostree-null:${PATH}" MICROOS_LEPTON_READ_ONLY=1 MICROOS_LEPTON_SNAPSHOTS="${T}/stars-ro-prune" \
    MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-tree" \
    "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-ro-prune/25772114" ]] \
    || fail "a read only runtime with three snapshots: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/stars-ro-prune/25772112" ]] || fail "a read only runtime pruned a snapshot: $(ls -A "${T}/stars-ro-prune")"
rc=0
PATH="${T}/bin-ostree-null:${PATH}" MICROOS_LEPTON_SNAPSHOTS="${T}/stars-ro-prune" \
    MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-tree" \
    "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-ro-prune/25772114" ]] \
    || fail "a writable runtime with three snapshots: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${T}/stars-ro-prune/25772112" ]] || fail "a writable runtime kept the oldest snapshot: $(ls -A "${T}/stars-ro-prune")"
[[ -d "${T}/stars-ro-prune/25772113" ]] || fail "a writable runtime pruned the next lower snapshot: $(ls -A "${T}/stars-ro-prune")"
rm -rf "${T}/bin-ostree-null" "${T}/stars-ro-prune"

rm -rf "${T}/stars-ostree-fail" "${T}/bin-ostree-fail"
mkdir -p "${T}/stars-ostree-fail" "${T}/bin-ostree-fail"
for b in 25772114 25772113 25772112; do
    mkdir -p "${T}/stars-ostree-fail/${b}"
    cp -a "${rt}/." "${T}/stars-ostree-fail/${b}/"
    printf 'rootfs=3.0.3 lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys\n' > "${T}/stars-ostree-fail/.verified.${b}"
    cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/${b}"
done
cat > "${T}/bin-ostree-fail/ostree" <<'STUB'
#!/usr/bin/bash
case "$1 $2" in
    "admin status") printf '{"deployments": [{"checksum": "%s"}]}\n' "$(printf 'b%.0s' {1..64})"; exit 0 ;;
    "ls "*) exit 1 ;;
esac
exit 1
STUB
chmod 0755 "${T}/bin-ostree-fail/ostree"
rc=0
PATH="${T}/bin-ostree-fail:${PATH}" MICROOS_LEPTON_SNAPSHOTS="${T}/stars-ostree-fail" \
    MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-tree" \
    "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-ostree-fail/25772114" ]] \
    || fail "an unreadable deployment list: exit ${rc}: $(cat "${STATE}/out")"
grep -qx "microos-lepton: cannot list $(printf 'b%.0s' {1..64}), judging snapshots by the booted one" "${STATE}/out" \
    || fail "an unreadable deployment list: not logged: $(cat "${STATE}/out")"
[[ -d "${T}/stars-ostree-fail/25772112" ]] \
    || fail "an unreadable deployment list pruned a snapshot: $(ls -A "${T}/stars-ostree-fail")"
rm -rf "${T}/bin-ostree-fail" "${T}/stars-ostree-fail"

rm -rf "${T}/stars-legacy"
mkdir -p "${T}/stars-legacy"
cp -a "${rt}" "${T}/stars-legacy/25772114"
printf 'garbage\n' > "${T}/stars-legacy/.verified.25772114"
snapshot_run "${T}/stars-legacy" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 1 ]] || fail "a marker for another rootfs: exit ${rc}: $(cat "${STATE}/out")"
grep -q "is not the snapshot its verified marker names, refusing it" "${STATE}/out" \
    || fail "a marker for another rootfs: no reason: $(cat "${STATE}/out")"
rm -f "${T}/stars-legacy/.verified.25772114"
snapshot_run "${T}/stars-legacy" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 0 && "$(grep -x "${T}/stars-legacy/25772114" "${STATE}/out")" == "${T}/stars-legacy/25772114" ]] \
    || fail "a snapshot with no marker: exit ${rc}: $(cat "${STATE}/out")"
grep -q "has no verified marker yet, writing it" "${STATE}/out" \
    || fail "a snapshot with no marker: not adopted: $(cat "${STATE}/out")"
grep -qx 'rootfs=3.0.3 lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys' "${T}/stars-legacy/.verified.25772114" \
    || fail "a snapshot with no marker: the marker: $(cat "${T}/stars-legacy/.verified.25772114" 2>/dev/null)"
printf 'rootfs=3.0.3 lepton/lepton:11/RQ3A/1:user/release-keys\n' > "${T}/stars-legacy/.verified.25772114"
snapshot_run "${T}/stars-legacy" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 1 ]] || fail "a marker for another non-empty rootfs: exit ${rc}: $(cat "${STATE}/out")"
grep -q "is not the snapshot its verified marker names, refusing it" "${STATE}/out" \
    || fail "a marker for another non-empty rootfs: no reason: $(cat "${STATE}/out")"
grep -qx 'rootfs=3.0.3 lepton/lepton:11/RQ3A/1:user/release-keys' "${T}/stars-legacy/.verified.25772114" \
    || fail "a marker for another non-empty rootfs: the marker was rewritten"
printf 'rootfs=\n' > "${T}/stars-legacy/.verified.25772114"
snapshot_run "${T}/stars-legacy" "${T}/reviewed-stars" /bin/false
[[ "${rc}" == 0 && "$(grep -x "${T}/stars-legacy/25772114" "${STATE}/out")" == "${T}/stars-legacy/25772114" ]] \
    || fail "a legacy empty marker: exit ${rc}: $(cat "${STATE}/out")"
grep -q "has a verified marker with no rootfs identity, writing it" "${STATE}/out" \
    || fail "a legacy empty marker: not rewritten: $(cat "${STATE}/out")"
grep -qx 'rootfs=3.0.3 lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys' "${T}/stars-legacy/.verified.25772114" \
    || fail "a legacy empty marker: the marker: $(cat "${T}/stars-legacy/.verified.25772114" 2>/dev/null)"
printf 'rootfs=\n' > "${T}/stars-legacy/.verified.25772114"
rc=0
MICROOS_LEPTON_READ_ONLY=1 MICROOS_LEPTON_SNAPSHOTS="${T}/stars-legacy" MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" \
    MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/stars-legacy/25772114" ]] \
    || fail "a legacy empty marker in read only: exit ${rc}: $(cat "${STATE}/out")"
grep -q "has a verified marker with no rootfs identity, a read only run leaves it" "${STATE}/out" \
    || fail "a legacy empty marker in read only: not logged: $(cat "${STATE}/out")"
grep -qx 'rootfs=' "${T}/stars-legacy/.verified.25772114" \
    || fail "a legacy empty marker in read only: the marker was rewritten"
rm -rf "${T}/stars-legacy"

rm -rf "${T}/stars-noxattr"
mkdir -p "${T}/stars-noxattr" "${T}/bin-noxattr"
cat > "${T}/bin-noxattr/setfattr" <<STUB
#!/usr/bin/bash
exit 1
STUB
chmod 0755 "${T}/bin-noxattr/setfattr"
rc=0
PATH="${T}/bin-noxattr:${PATH}" MICROOS_LEPTON_SNAPSHOTS="${T}/stars-noxattr" \
    MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir-tree" \
    "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 && "$(tail -n 1 "${STATE}/out")" == "microos-lepton: ${T}/stars-noxattr keeps no xattrs, refusing" ]] \
    || fail "no xattrs: exit ${rc}: $(cat "${STATE}/out")"
[[ "$(ls -A "${T}/stars-noxattr")" == .lock ]] || fail "no xattrs: the half made snapshot was kept: $(ls -A "${T}/stars-noxattr")"

rm -rf "${T}/stars-noxattr" "${T}/bin-noxattr"

rm -rf /dev/shm/microos-otherfs-$$
mkdir -p /dev/shm/microos-otherfs-$$
snapshot_run /dev/shm/microos-otherfs-$$ "${T}/reviewed-stars" "${T}/bin/lepton-dir-tree"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "/dev/shm/microos-otherfs-$$/25772114" ]] \
    || fail "across filesystems: exit ${rc}: $(cat "${STATE}/out")"
grep -qxF "microos-lepton: ${T}/lib-tree/steamapps/common/Lepton is on another filesystem, copied it in full" \
    "${STATE}/out" || fail "across filesystems: not logged: $(cat "${STATE}/out")"
diff -r --no-dereference "${T}/lib-tree/steamapps/common/Lepton" "/dev/shm/microos-otherfs-$$/25772114" > /dev/null \
    || fail "across filesystems: not a full copy"
rm -rf /dev/shm/microos-otherfs-$$

backups="${T}/home/.local/share/microos-android/backups"
bkctx="${contexts}/probe-lh-bk"
seed "${bkctx}"
unseed_modes "${bkctx}"
rm -rf "${backups}"
cycle probe-lh-bk env STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 ]] || fail "context backup: first start exit ${rc}: $(out probe-lh-bk)"
backup="${backups}/probe-lh-bk.pre-25772114.bak"
[[ -d "${backup}" ]] || fail "context backup: not made: $(ls -A "${backups}")"
diff -r --no-dereference "${T}/ctx-before-first-start" "${backup}" > /dev/null 2>&1 \
    || fail "context backup: not the context as it was: $(ls -A "${backup}")"
grep -qx "microos-lepton: kept ${backup}" "${STATE}/out-probe-lh-bk" || fail "context backup: not logged"
echo saved > "${bkctx}/baked/data_overlay/data/com.example.game/save"
cycle probe-lh-bk env STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 && "$(cat "${backup}/baked/data_overlay/data/com.example.game/save")" == save ]] \
    || fail "context backup: taken again on the same runtime"
more=("${backups}"/probe-lh-bk.pre-*.bak)
[[ "${#more[@]}" == 1 ]] || fail "context backup: more than one: $(ls -A "${backups}")"
mkdir -p "${backups}/probe-lh-bk.pre-by-hand.bak"
echo mine > "${backups}/probe-lh-bk.pre-by-hand.bak/keep"
rm -rf "${T}/snaps-old" "${T}/reviewed-old"
mkdir -p "${T}/snaps-old" "${T}/reviewed-old"
cp -a "${rt}" "${T}/snaps-old/25772113"
marker "${T}/snaps-old/25772113"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-old/25772113"
cycle probe-lh-bk env MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-old" MICROOS_LEPTON_REVIEWED="${T}/reviewed-old" \
    STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 ]] || fail "context backup on a new runtime: exit ${rc}: $(out probe-lh-bk)"
[[ -d "${backups}/probe-lh-bk.pre-25772113.bak" ]] || fail "context backup on a new runtime: not made: $(ls -A "${backups}")"
[[ ! -e "${backups}/probe-lh-bk.pre-25772114.bak" ]] || fail "context backup on a new runtime: the last one only: $(ls -A "${backups}")"
[[ "$(cat "${backups}/probe-lh-bk.pre-by-hand.bak/keep" 2>/dev/null)" == mine ]] \
    || fail "context backup on a new runtime: pruned a backup it did not make: $(ls -A "${backups}")"
rm -rf "${backups:?}/probe-lh-bk.pre-by-hand.bak"
rm -rf "${T}/snaps-old" "${T}/reviewed-old"

rm -rf "${backups}"
: > "${backups}"
refused probe-lh-bk env STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
grep -qxF "microos-lepton: cannot make ${backups}" "${STATE}/out-probe-lh-bk" \
    || fail "context backup failure: $(out probe-lh-bk)"
rm -f "${backups}"

rm -rf "${T}/fresh-snaps" "${T}/fresh-review"
mkdir -p "${T}/fresh-review"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/fresh-review/25772114"
printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' \
    > "${T}/steam/steamapps/appmanifest_3029110.acf"
snapshot_run "${T}/fresh-snaps" "${T}/fresh-review" "${MICROOS_LEPTON_STEAM_DIR_CMD}"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/fresh-snaps/25772114" ]] \
    || fail "absent snapshots dir: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/fresh-snaps/25772114" ]] || fail "absent snapshots dir: not made: $(ls -A "${T}/fresh-snaps" 2>/dev/null)"
rm -rf "${T}/fresh-snaps" "${T}/fresh-review"

rm -rf "${T}/library-two"
mkdir -p "${T}/library-two/steamapps/common"
cp -a "${rt}" "${T}/library-two/steamapps/common/Lepton"
printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' \
    > "${T}/library-two/steamapps/appmanifest_3029110.acf"
cat > "${T}/bin/lepton-dir-two" <<STUB
#!/usr/bin/bash
printf '%s\n' "${T}/library-two/steamapps/common/Lepton"
STUB
chmod 0755 "${T}/bin/lepton-dir-two"
rm -rf "${T}/snaps-two" "${T}/reviewed-two"
mkdir -p "${T}/snaps-two" "${T}/reviewed-two"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-two/25772114"
snapshot_run "${T}/snaps-two" "${T}/reviewed-two" "${T}/bin/lepton-dir-two"
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/snaps-two/25772114" ]] \
    || fail "second library: exit ${rc}: $(cat "${STATE}/out")"
diff -r --no-dereference "${T}/library-two/steamapps/common/Lepton" "${T}/snaps-two/25772114" > /dev/null \
    || fail "second library: the snapshot is not from the card library"
printf '"AppState"\n{\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"6"\n}\n' \
    > "${T}/library-two/steamapps/appmanifest_3029110.acf"
rm -rf "${T}/snaps-two"
mkdir -p "${T}/snaps-two"
snapshot_run "${T}/snaps-two" "${T}/reviewed-two" "${T}/bin/lepton-dir-two"
[[ "${rc}" == 1 && "$(tail -n 1 "${STATE}/out")" == "microos-lepton: Lepton is not installed. Install it in Steam." ]] \
    || fail "second library, not installed: exit ${rc}: $(cat "${STATE}/out")"
rm -rf "${T}/library-two" "${T}/snaps-two" "${T}/reviewed-two"

rm -rf "${T}/snaps-keep"
mkdir -p "${T}/snaps-keep" "${T}/snaps-keep/not-a-build" "${T}/snaps-keep/25772100"
cp -a "${rt}" "${T}/snaps-keep/25772114"
marker "${T}/snaps-keep/25772114"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-stars/25772114"
echo keep > "${T}/snaps-keep/not-a-build/file"
echo keep > "${T}/snaps-keep/25772100/file"
rc=0
MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-keep" MICROOS_LEPTON_REVIEWED="${T}/reviewed-stars" \
    MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && "$(tail -n 1 "${STATE}/out")" == "${T}/snaps-keep/25772114" ]] \
    || fail "unreviewed dirs: exit ${rc}: $(cat "${STATE}/out")"
[[ -f "${T}/snaps-keep/not-a-build/file" && -f "${T}/snaps-keep/25772100/file" ]] \
    || fail "unreviewed dirs: a foreign dir was removed: $(ls -A "${T}/snaps-keep")"
rm -rf "${T}/snaps-keep"

rm -rf "${T}/snaps-par" "${T}/reviewed-par"
mkdir -p "${T}/snaps-par" "${T}/reviewed-par"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-par/25772114"
for i in 1 2 3 4; do
    MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-par" MICROOS_LEPTON_REVIEWED="${T}/reviewed-par" \
        "${launcher}" runtime > "${STATE}/par-${i}" 2>&1 &
done
wait
for i in 1 2 3 4; do
    [[ "$(tail -n 1 "${STATE}/par-${i}")" == "${T}/snaps-par/25772114" ]] \
        || fail "parallel runtime ${i}: $(cat "${STATE}/par-${i}")"
done
[[ -f "${XDG_RUNTIME_DIR}/microos-lepton/runtime" ]] || fail "parallel runtime: no runtime file written"
[[ "$(cat "${XDG_RUNTIME_DIR}/microos-lepton/runtime")" == "${T}/snaps-par/25772114" ]] \
    || fail "parallel runtime: the runtime file holds $(cat "${XDG_RUNTIME_DIR}/microos-lepton/runtime")"
stray=("${XDG_RUNTIME_DIR}/microos-lepton/"runtime.*)
[[ ! -e "${stray[0]}" ]] || fail "parallel runtime: a temp file was left: $(ls -A "${XDG_RUNTIME_DIR}/microos-lepton")"
stray=("${T}/snaps-par"/*)
for path in "${stray[@]}"; do
    [[ "$(basename "${path}")" == .lock || "$(basename "${path}")" == 25772114 ]] \
        || fail "parallel runtime: leftover ${path}"
done
rm -rf "${T}/snaps-par" "${T}/reviewed-par"

rm -rf "${T}/snaps-lock"
mkdir -p "${T}/snaps-lock"
: > "${T}/snaps-lock/.lock"
snapshot_run "${T}/snaps-lock" "${T}/reviewed-stars" "${MICROOS_LEPTON_STEAM_DIR_CMD}"
[[ "${rc}" == 0 && -d "${T}/snaps-lock/25772114" ]] || fail "lock file present: exit ${rc}: $(cat "${STATE}/out")"
rm -rf "${T}/snaps-lock"

backup_part="${backup}.part"
rm -rf "${backups}"
mkdir -p "${backups}"
mkdir -p "${backup_part}"
echo stale > "${backup_part}/stale"
mkdir -p "${backup}"
echo old > "${backup}/old"
cycle probe-lh-bk env STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 ]] || fail "backup .part: exit ${rc}: $(out probe-lh-bk)"
[[ ! -e "${backup_part}" ]] || fail "backup .part: a leftover .part was kept"
[[ "$(cat "${backup}/old")" == old ]] || fail "backup .part: the existing backup was replaced"
rm -rf "${backups}"
mkdir -p "${backups}"
mkdir -p "${backup}.part"
echo stale > "${backup}.part/stale"
cycle probe-lh-bk env STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 ]] || fail "backup .part leftover: exit ${rc}: $(out probe-lh-bk)"
[[ ! -e "${backup}.part" && -d "${backup}" ]] || fail "backup .part leftover: $(ls -A "${backups}")"
echo kept > "${backup}/kept"
rm -rf "${T}/snaps-new" "${T}/reviewed-new"
mkdir -p "${T}/snaps-new" "${T}/reviewed-new"
cp -a "${rt}" "${T}/snaps-new/25772113"
marker "${T}/snaps-new/25772113"
cp "${T}/steam/steamapps/common/Lepton.reviewed" "${T}/reviewed-new/25772113"
rm -rf "${backups}/probe-lh-bk.pre-25772113.bak"
cycle probe-lh-bk env MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-new" MICROOS_LEPTON_REVIEWED="${T}/reviewed-new" \
    STEAM_COMPAT_DATA_PATH="${bkctx}" "${launcher}" start probe-lh-bk
[[ "${rc}" == 0 ]] || fail "backup order: exit ${rc}: $(out probe-lh-bk)"
[[ -d "${backups}/probe-lh-bk.pre-25772113.bak" && ! -e "${backups}/probe-lh-bk.pre-25772114.bak" ]] \
    || fail "backup order: not the new one only: $(ls -A "${backups}")"
rm -rf "${T}/snaps-new" "${T}/reviewed-new"

rm -rf "${T}/snaps-links"
mkdir -p "${T}/snaps-links" "${T}/outside-rootfs" "${T}/outside-sysbake"
cp -a "${rt}" "${T}/snaps-links/25772114"
marker "${T}/snaps-links/25772114"
for dir in images/rootfs sysbake; do
    rm -rf "${T}/snaps-links/25772114/${dir}"
    if [[ "${dir}" == images/rootfs ]]; then
        cp -a "${rt}/images/rootfs" "${T}/outside-rootfs/rootfs"
        ln -s "${T}/outside-rootfs/rootfs" "${T}/snaps-links/25772114/${dir}"
    else
        cp -a "${rt}/sysbake" "${T}/outside-sysbake/sysbake"
        ln -s "${T}/outside-sysbake/sysbake" "${T}/snaps-links/25772114/${dir}"
    fi
    rc=0
    MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-links" MICROOS_LEPTON_STEAM_DIR_CMD=/bin/false \
        timeout -k 2 20 "${launcher}" runtime > "${STATE}/out" 2>&1 || rc=$?
    [[ "${rc}" == 1 && "$(head -n 1 "${STATE}/out")" == \
        "microos-lepton: Lepton in ${T}/snaps-links/25772114 has no images/rootfs or sysbake directory, refusing" ]] \
        || fail "${dir} a link: exit ${rc}: $(cat "${STATE}/out")"
    rm -rf "${T}/snaps-links"
    mkdir -p "${T}/snaps-links"
    cp -a "${rt}" "${T}/snaps-links/25772114"
marker "${T}/snaps-links/25772114"
done
rm -rf "${T}/snaps-links" "${T}/outside-rootfs" "${T}/outside-sysbake"

play_run="${repo}/data/usr/libexec/microos/microos-android-run"
play_data="${T}/play-data"
play_home="${play_data}/home"
play_ctx="${play_home}/.local/share/lepton/contexts/android"
mkdir -p "${T}/play-bin" "${play_data}" "${play_ctx}/external"
printf 'storage=0123456789abcdef\n' > "${play_ctx}/microos-android-storage"
echo mmcblk0 > "${T}/play-card"
cat > "${T}/play-bin/pad-nodes" <<'STUB'
#!/usr/bin/bash
exit 0
STUB
cat > "${T}/play-bin/lepton-dir" <<STUB
#!/usr/bin/bash
printf '%s\n' "${rt}"
STUB
chmod 0755 "${T}/play-bin/"*
mkdir -p "${rt}/images/rootfs/system/etc/init"
printf 'on boot\n    keycodes 114 115 116\n' > "${rt}/images/rootfs/system/etc/init/lineage-system.rc"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/play-gamescope-0"
rc=0
XDG_STATE_HOME="${T}/play-state" MICROOS_ANDROID_DATA="${play_data}" MICROOS_POLL_S=0.05 \
    GAMESCOPE_WAYLAND_DISPLAY=play-gamescope-0 \
    MICROOS_DISPLAY_FILE="${repo}/data/usr/share/microos-android/display" \
    MICROOS_GAPPS="${T}/play-gapps" MICROOS_STUB_DIR="${T}/play-stub" \
    MICROOS_OPTS="${repo}/data/usr/share/microos-android/opts" \
    MICROOS_LEPTON="${launcher}" \
    MICROOS_PAD_NODES="${T}/play-bin/pad-nodes" \
    MICROOS_CONTENT="${T}/play-content" MICROOS_SYSTEM_CARD="${T}/play-card" MICROOS_TEST=1 \
    MICROOS_ANDROID_UID="$(id -u)" \
    STEAM_COMPAT_DATA_PATH="${play_ctx}" \
    timeout -k 2 20 "${play_run}" > "${STATE}/out-play-run" 2>&1 || rc=$?
grep -qx "MICROOS_ANDROID_EXTERNAL=${play_ctx}/external" "${STATE}/env-android" \
    || fail "play-run on the real launcher: the external source: $(tail -n 5 "${STATE}/out-play-run")"
grep -qx "STEAM_COMPAT_DATA_PATH=${play_ctx}" "${STATE}/env-android" \
    || fail "play-run on the real launcher: the launcher refused the context: $(tail -n 5 "${STATE}/out-play-run")"
grep -q "microos-lepton: kept ${play_data}/backups/android.pre-" "${STATE}/out-play-run" \
    || fail "play-run on the real launcher: the launcher did not reach its start path: $(tail -n 5 "${STATE}/out-play-run")"
[[ -d "${play_ctx}/internal" ]] || fail "play-run on the real launcher: internal/ not made"
[[ -p "${play_home}/.steam/steam.pipe" ]] || fail "play-run on the real launcher: the FIFO not made under the DATA home"
rm -rf "${play_data:?}" "${T:?}/play-bin" "${T:?}/play-state"

if (( failures )); then
    echo "lepton-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "lepton-test: ok"
