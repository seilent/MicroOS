#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-mangohud.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${MANGOHUD_VERSION:?SOURCE.env has no MANGOHUD_VERSION}
arch=$(uname -m)

rpm=$(find "$dir" -maxdepth 1 -name "mangohud-$version-*.microos.$arch.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one mangohud $arch RPM in $dir" >&2
  exit 1
fi
srpm=$(find "$dir" -maxdepth 1 -name "mangohud-$version-*.src.rpm")
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one mangohud SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/bin/mangoapp \
  /usr/bin/mangohud \
  /usr/lib64/mangohud/libMangoHud.so \
  /usr/share/licenses/mangohud/LICENSE \
  "/usr/share/vulkan/implicit_layer.d/MangoHud.$arch.json"; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done

listed=$(grep -o '`[0-9]\{4\}-[^`]*\.patch`' "$dir/PATCHES.md" | tr -d '`' | sort -u)
carried=$(rpm -qp --qf '[%{PATCH}\n]' "$srpm" | sort -u)
if [[ -z $listed || $listed != "$carried" ]]; then fail "SRPM patches differ from PATCHES.md: $carried"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"
ulimit -c 0

rpmbuild -rp --nodeps --define "_topdir $work/top" --define "commit $MANGOHUD_REF" "$srpm" >"$work/prep.log" 2>&1 \
  || { cat "$work/prep.log" >&2; echo "FAIL: rpmbuild -rp" >&2; exit 1; }
patched=$(find "$work/top/BUILD" -maxdepth 2 -type d -name "MangoHud-$MANGOHUD_REF" | head -n1)
[[ -n $patched ]] || { echo "FAIL: no prepped tree" >&2; exit 1; }
mkdir "$work/bare"
tar -xzf "$work/top/SOURCES/mangohud-$MANGOHUD_REF.tar.gz" -C "$work/bare"
bare=$work/bare/MangoHud-$MANGOHUD_REF

read -ra spdlog_cflags <<<"$(pkg-config --cflags spdlog)"
read -ra spdlog_libs <<<"$(pkg-config --libs spdlog)"
build() {
  local tree=$1 bin=$2
  (
    cd "$tree"
    gcc -c -DTEST_ONLY -Iinclude -Isrc -Isrc/mesa src/mesa/util/os_time.c -o "$bin.os_time.o"
    g++ -std=c++17 -DTEST_ONLY "${spdlog_cflags[@]}" -Iinclude -Isrc -Isrc/mesa \
      "$here/pkg-mangohud/metrics.cpp" src/gpu_fdinfo.cpp src/battery.cpp src/file_utils.cpp "$bin.os_time.o" \
      -o "$bin" "${spdlog_libs[@]}" -lpthread
  )
}
build "$patched" "$work/patched" || { echo "FAIL: harness build against the patched tree" >&2; exit 1; }
build "$bare" "$work/bare-v$version" || { echo "FAIL: harness build against bare v$version" >&2; exit 1; }

fixture() {
  local d=$1
  mkdir -p "$d/class/devfreq/3d00000.gpu" "$d/class/hwmon/hwmon15" "$d/class/drm/renderD128" \
    "$d/class/power_supply/battery" "$d/fdinfo"
  echo 305000000 >"$d/class/devfreq/3d00000.gpu/cur_freq"
  echo gpu_top_thermal >"$d/class/hwmon/hwmon15/name"
  echo 48000 >"$d/class/hwmon/hwmon15/temp1_input"
  echo Battery >"$d/class/power_supply/battery/type"
  echo 57 >"$d/class/power_supply/battery/capacity"
  echo Discharging >"$d/class/power_supply/battery/status"
  echo -1000000 >"$d/class/power_supply/battery/current_now"
  echo 4000000 >"$d/class/power_supply/battery/voltage_now"
}

run() {
  local bin=$1 what=$2 status=0
  case $what in
    nd-*)
      setpriv --reuid=65534 --regid=65534 --clear-groups "$bin" "$what" || status=$?
      ;;
    *)
      local fix
      fix=$(mktemp -d "$work/fix.XXXXXX")
      fixture "$fix"
      unshare --user --map-root-user --mount sh -c 'mount --bind "$1/class" /sys/class && exec "$2" "$3" "$1"' \
        sh "$fix" "$bin" "$what" || status=$?
      ;;
  esac
  return "$status"
}

for what in clock temp load vram battery nd-fd nd-lib; do
  status=0
  run "$work/patched" "$what" || status=$?
  if (( status != 0 )); then fail "patched $what exit $status"; fi
done

for what in clock temp load vram battery nd-fd nd-lib; do
  status=0
  run "$work/bare-v$version" "$what" 2>/dev/null || status=$?
  echo "bare v$version $what exit $status"
  case $what in
    nd-*) if (( status != 134 )); then fail "bare v$version $what exit $status, not SIGABRT"; fi ;;
    *) if (( status != 1 )); then fail "bare v$version $what exit $status, not a failed metric"; fi ;;
  esac
done

exit "$rc"
