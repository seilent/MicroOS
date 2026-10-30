#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
storage=$tree/usr/libexec/microos/microos-storage
fixtures=$here/storage
tmp=$(mktemp -d)
holder=""
trap '[[ -z $holder ]] || kill "$holder" 2> /dev/null; rm -rf "$tmp"' EXIT
rc=0
checks=0
fail() { echo "FAIL: $*" >&2; rc=1; }

bin=$tmp/bin
mkdir -p "$bin"
cat > "$bin/stub" <<'EOF'
#!/usr/bin/env bash
n=${0##*/}
{ printf '%s' "$n"; printf ' %q' "$@"; echo; } >> "$CALLS"
if [[ ${SEQ_BUMP:-} == "$n" ]]; then
  echo 99 > "$SEQ_FILE"
fi
rcvar=RC_${n//[^A-Za-z0-9]/_}
exit "${!rcvar:-0}"
EOF
for n in lsblk udevadm fsck.ext4 f3probe wipefs sfdisk mkfs.ext4 mkfs.exfat fstrim systemd-run umount; do
  ln -s stub "$bin/$n"
done
cat > "$bin/passthru" <<'EOF'
#!/usr/bin/env bash
n=${0##*/}
{ printf '%s' "$n"; printf ' %q' "$@"; echo; } >> "$CALLS"
exec "/usr/bin/$n" "$@"
EOF
for n in mv ln stat realpath readlink; do
  ln -s passthru "$bin/$n"
done
cat > "$bin/microos-pad-hold" <<'EOF'
#!/usr/bin/env bash
hint=no
if [[ -e $MICROOS_RUN/hold/storage ]]; then
  { read -r pid; read -r dev; } < "$MICROOS_RUN/hold/storage"
  hint=$(stat -c %a "$MICROOS_RUN/hold/storage"):$pid:$dev:$(wc -l < "$MICROOS_RUN/hold/storage")
  [[ $hint =~ ^644:[1-9][0-9]*:/dev/mmcblk[0-9]:2$ ]] && kill -0 "$pid" 2> /dev/null && hint=live:$dev
fi
if flock -n "$MICROOS_RUN/lock/format.lock" true; then lock=free; else lock=held; fi
{ printf 'microos-pad-hold'; printf ' %q' "$@"; echo " hint=$hint lock=$lock"; } >> "$CALLS"
(( ! ${RC_pad_hold:-0} )) || echo "microos-pad-hold: refused: BTN_SOUTH not held for 1 s" >&2
exit "${RC_pad_hold:-0}"
EOF
cat > "$bin/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOGGER_LOG"
EOF
cat > "$bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ $1 == passwd && $2 == micro ]] || exit 2
echo "micro:x:1000:1000::/var/home/micro:/bin/bash"
EOF
cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if flock -n -s "$LOCK_NODE" true; then lock=free; else lock=held; fi
if [[ ${SEQ_BUMP:-} == systemctl ]]; then
  echo 99 > "$SEQ_FILE"
fi
{ printf 'systemctl'; printf ' %q' "$@"; echo " lock=$lock"; } >> "$CALLS"
exit "${RC_systemctl:-0}"
EOF
cat > "$bin/findmnt" <<'EOF'
#!/usr/bin/env bash
{ printf 'findmnt'; printf ' %q' "$@"; echo; } >> "$FINDMNT_CALLS"
case "$*" in
  "-rno SOURCE,FSTYPE,UUID --mountpoint "*)
    t=${*: -1}
    [[ ${FINDMNT_FAIL:-} != "$t" ]] || exit 1
    awk -v t="$t" '$1 == t { sub(/^[^ ]* /, ""); print; f = 1 } END { exit !f }' "$FINDMNT_ROWS"
    ;;
  "-rno TARGET --source "*)
    awk -v s="${*: -1}" '$1 == s { print $2; f = 1 } END { exit !f }' "$MOUNTS"
    ;;
  "-rnv -t ext4,btrfs -O rw -o SOURCE,TARGET,FSTYPE")
    awk '($3 == "ext4" || $3 == "btrfs") && ($4 == "rw" || $4 ~ /^rw,/) { print $1, $2, $3; f = 1 } END { exit !f }' "$MOUNTS"
    ;;
  "-rno SOURCE,TARGET")
    if flock -n "$CONTENT_LOCK" true; then lock=free; else lock=held; fi
    echo "content lock=$lock" >> "$FINDMNT_CALLS"
    [[ -z ${FINDMNT_TABLE_FAIL:-} ]] || exit 1
    awk '{ print $1, $2 }' "$MOUNTS"
    ;;
  *--poll*)
    n=$(( $(cat "$POLL_COUNT" 2> /dev/null || echo 0) + 1 ))
    echo "$n" > "$POLL_COUNT"
    [[ $* == "--poll --first-only --timeout 5000" ]] || echo "bad poll $*" >> "$POLL_LOG"
    echo "$n $(wc -l < "$BLKID_CALLS") $(/usr/bin/stat -c %y "$CONTENT_LINK" 2> /dev/null || echo none)" >> "$POLL_LOG"
    [[ $n != "${POLL_ADD:-}" ]] || printf '%s\n' "$POLL_ROW" >> "$MOUNTS"
    (( n < ${POLL_KILL:-1} )) || kill -TERM "$PPID"
    ;;
  *)
    echo "findmnt stub: unexpected $*" >&2
    exit 99
    ;;
esac
EOF
cat > "$bin/blkid" <<'EOF'
#!/usr/bin/env bash
{ printf 'blkid'; printf ' %q' "$@"; echo; } >> "$BLKID_CALLS"
[[ $# == 4 && $1 == -p && $2 == -o && $3 == export ]] || exit 4
[[ ${BLKID_FAIL:-} != "$4" ]] || exit 8
if [[ -n ${BLKID_FAIL_ONCE:-} && -e $BLKID_FAIL_ONCE ]]; then
  rm "$BLKID_FAIL_ONCE"
  exit 8
fi
out=$(jq -r --arg p "$4" '.. | objects | select(.path? == $p) |
  (if .fstype then "TYPE=\(.fstype)" else empty end),
  (if .label then "LABEL=\(.label)" else empty end),
  (if .uuid then "UUID=\(.uuid)" else empty end),
  (if .partlabel then "PART_ENTRY_NAME=\(.partlabel)" else empty end)' "$BLKID_JSON")
[[ -n $out ]] || exit 2
echo "$out"
EOF
cat > "$bin/busctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'busctl'; printf ' %q' "$@"; echo; } >> "$CALLS"
for a; do
  case $a in
    /org/freedesktop/UDisks2/block_devices/*) part=${a##*/} ;;
    Mount | Unmount) method=$a ;;
  esac
done
src=/dev/$part
want=/run/media/micro/${BUS_NAME:-}
if [[ $method == Mount && -n ${BUS_UNKNOWN:-} ]]; then
  n=$(cat "$BUS_COUNT" 2> /dev/null || echo 0)
  echo $(( n + 1 )) > "$BUS_COUNT"
  if (( n < BUS_UNKNOWN )); then
    echo "Call failed: Object does not exist at path “/org/freedesktop/UDisks2/block_devices/$part”" >&2
    exit 1
  fi
fi
if [[ $method == Unmount ]]; then
  [[ ${BUS_UNMOUNT:-ok} == ok ]] || exit 1
  awk -v s="$src" '$1 != s' "$MOUNTS" > "$MOUNTS.new"
  mv "$MOUNTS.new" "$MOUNTS"
  exit 0
fi
case ${BUS_MODE:-ok} in
  ok)
    echo "$src $want ext4 rw,noatime 1" >> "$MOUNTS"
    printf '{"type":"s","data":["%s"]}\n' "$want"
    ;;
  other)
    echo "$src ${want}1 ext4 rw,noatime 1" >> "$MOUNTS"
    printf '{"type":"s","data":["%s1"]}\n' "$want"
    ;;
  already)
    echo "$src $want ext4 rw,noatime 1" >> "$MOUNTS"
    echo "Call failed: Device $src is already mounted at \`$want'." >&2
    exit 1
    ;;
  *)
    echo "Call failed: Error mounting $src: wrong fs type" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$bin"/*

sys=$tmp/sys
dev=$tmp/dev
build() {
  local fx=$fixtures/$1 t=$tmp/tpl/$1 disk part path value uuid name
  local s=$t/sys d=$t/dev
  mkdir -p "$s/class/block" "$s/block" "$d"
  cp "$fx/findmnt" "$t/findmnt"
  jq -s '.[1].blockdevices as $f | {blockdevices: ($f + [.[0].blockdevices[] | select(.name as $n | all($f[]; .name != $n))])}' \
    "$fixtures/internal/lsblk.json" "$fx/lsblk.json" > "$t/lsblk.json"
  while read -r disk part size; do
    mkdir -p "$s/devices/fixture/block/$disk"
    [[ -e $s/block/$disk ]] || ln -s "../devices/fixture/block/$disk" "$s/block/$disk"
    [[ -e $s/class/block/$disk ]] || ln -s "../../devices/fixture/block/$disk" "$s/class/block/$disk"
    : > "$d/$disk"
    [[ $part != - ]] || continue
    mkdir -p "$s/devices/fixture/block/$disk/$part"
    echo "${part##*[!0-9]}" > "$s/devices/fixture/block/$disk/$part/partition"
    [[ $size == null ]] || echo $(( size / 512 )) > "$s/devices/fixture/block/$disk/$part/size"
    ln -s "../../devices/fixture/block/$disk/$part" "$s/class/block/$part"
    : > "$d/$part"
  done < <(jq -r '.blockdevices[] | if .children then "\(.name) \(.children[] | "\(.name) \(.size)")" else "\(.name) - null" end' "$t/lsblk.json")
  while read -r path value; do
    mkdir -p "$(dirname "$s/$path")"
    echo "$value" > "$s/$path"
  done < "$fx/sysfs"
  read -r path name < "$fx/btrfs-devices"
  path=${path%:}
  uuid=${path#/sys/fs/btrfs/}
  uuid=${uuid%/devices}
  mkdir -p "$s/fs/btrfs/$uuid/devices"
  ln -s "../../../../class/block/$name" "$s/fs/btrfs/$uuid/devices/$name"
}
for fx in internal internal-coldplug microos-sd booted-sd; do
  build "$fx"
done

setup() {
  local t=$tmp/tpl/$1
  rm -rf "$sys" "$dev"
  cp -a "$t/sys" "$sys"
  cp -a "$t/dev" "$dev"
  cp "$t/findmnt" "$tmp/findmnt"
  cp "$t/lsblk.json" "$tmp/lsblk.json"
  : > "$tmp/mounts"
  rm -rf "$tmp/run"
  mkdir -p "$tmp/run/lock" "$tmp/run/hold"
}

run() {
  local -a vars=()
  while [[ $1 == *=* ]]; do
    vars+=("$1")
    shift
  done
  : > "$tmp/calls"
  : > "$tmp/log"
  : > "$tmp/fcalls"
  : > "$tmp/bcalls"
  rm -f "$tmp/buscount" "$tmp/pollcount"
  : > "$tmp/poll"
  r=0
  env -i PATH="${STUB_PATH:-$bin}:${SYS_PATH:-/usr/bin:/bin}" CALLS="$tmp/calls" LOGGER_LOG="$tmp/log" FINDMNT_CALLS="$tmp/fcalls" \
    BLKID_CALLS="$tmp/bcalls" FINDMNT_ROWS="$tmp/findmnt" MOUNTS="$tmp/mounts" BLKID_JSON="$tmp/lsblk.json" \
    MICROOS_SYSFS="$sys" MICROOS_DEV="$dev" MICROOS_STORAGE_LOCK_WAIT=2 BUS_COUNT="$tmp/buscount" SEQ_FILE="$sys/block/mmcblk0/diskseq" \
    LOCK_NODE="$dev/mmcblk0" MICROOS_PAD_HOLD="$bin/microos-pad-hold" BUS_NAME=e8ea5deb-1451-4895-9312-7f169786ad58 MICROOS_RUN="$tmp/run" \
    CONTENT_LOCK="$tmp/run/lock/content" CONTENT_LINK="$tmp/run/content" POLL_COUNT="$tmp/pollcount" POLL_LOG="$tmp/poll" \
    "${vars[@]}" "$storage" "$@" > "$tmp/out" 2>&1 ||
    r=$?
}
code() { checks=$(( checks + 1 )); (( r == $1 )) || fail "$2: exit $r, want $1: $(cat "$tmp/out")"; }
out_is() { checks=$(( checks + 1 )); [[ $(< "$tmp/out") == "$1" ]] || fail "$2: printed '$(< "$tmp/out")', want '$1'"; }
called() { checks=$(( checks + 1 )); grep -q -- "$1" "$tmp/calls" || fail "$2: no call matching '$1' in: $(cat "$tmp/calls")"; }
not_called() { checks=$(( checks + 1 )); ! grep -q -- "$1" "$tmp/calls" || fail "$2: unexpected call: $(grep -- "$1" "$tmp/calls")"; }
writers='^\(f3probe\|wipefs\|sfdisk\|mkfs\.ext4\|mkfs\.exfat\) '
no_writer() { checks=$(( checks + 1 )); ! grep -q "$writers" "$tmp/calls" || fail "$1: writer called: $(grep "$writers" "$tmp/calls")"; }
logged() { checks=$(( checks + 1 )); grep -q -- "$1" "$tmp/log" || fail "$2: no log line matching '$1' in: $(cat "$tmp/log")"; }
log_lines() { checks=$(( checks + 1 )); (( $(wc -l < "$tmp/log") == $1 )) || fail "$2: $(wc -l < "$tmp/log") log lines, want $1: $(cat "$tmp/log")"; }
link_is() {
  local l
  checks=$(( checks + 1 ))
  l=$(readlink "$tmp/run/content") || l=""
  [[ $l == "$1" ]] || fail "$2: link '$l', want '$1'"
  [[ -n $1 || ! -e $tmp/run/content && ! -L $tmp/run/content ]] || fail "$2: $tmp/run/content left"
}
content_locked() {
  checks=$(( checks + 1 ))
  grep -qxF "content lock=held" "$tmp/fcalls" || fail "$1: mount table not read: $(cat "$tmp/fcalls")"
  ! grep -qxF "content lock=free" "$tmp/fcalls" || fail "$1: mount table read without the content lock"
}
card_untouched() {
  checks=$(( checks + 1 ))
  ! grep -E '/run/media/' "$tmp/calls" | grep -qvE '^ln -sfn -- ' ||
    fail "$1: path under the card used: $(grep -E '/run/media/' "$tmp/calls" | grep -vE '^ln -sfn -- ')"
  ! grep -qE '^(stat|realpath) .*/run/media/' "$tmp/calls" || fail "$1: stat or realpath under the card"
}
mtime() { /usr/bin/stat -c %y "$tmp/run/content" 2> /dev/null || echo none; }
line_of() {
  local n
  n=$(grep -n -- "$1" "$tmp/calls" | head -n 1 | cut -d: -f1)
  echo "${n:-0}"
}

classify() {
  run classify "$1"
  code 0 "classify $1 ($3)"
  out_is "$2" "classify $1 ($3)"
}

card=e8ea5deb-1451-4895-9312-7f169786ad58
media=/run/media/micro/$card

setup internal
classify mmcblk0 data "internal boot, card"
grep -q 'blkid -p -o export /dev/mmcblk0p1' "$tmp/bcalls" || fail "classify did not probe mmcblk0p1 with blkid -p"
for t in / /sysroot /var /etc /boot /boot/efi; do
  grep -qxF "findmnt -rno SOURCE\\,FSTYPE\\,UUID --mountpoint $t" "$tmp/fcalls" || fail "classify did not look up $t"
done
classify /dev/mmcblk0 data "internal boot, card by /dev path"
classify sda system "internal boot, UFS"
classify /dev/sda system "internal boot, UFS by /dev path"
classify /sys/block/mmcblk0 system "sysfs path"
classify ../mmcblk0 system "relative path"
classify mmcblk0p1 system "partition name"
classify sdb system "other UFS LUN"

setup internal
sed -i 's|^/ composefs overlay $|/ overlay overlay |' "$tmp/findmnt"
classify mmcblk0 system "/ overlay overlay is not skipped"
setup internal
sed -i 's|^/ composefs overlay $|/ composefs ext4 |' "$tmp/findmnt"
classify mmcblk0 system "/ composefs ext4 is not skipped"
setup internal
sed -i "s|^/ composefs overlay \$|/ /dev/mmcblk0p1 ext4 $card|" "$tmp/findmnt"
classify mmcblk0 system "/ on the card resolves"
setup internal
sed -i "s|^/ composefs overlay \$|/ /dev/sda21 ext4 x|" "$tmp/findmnt"
classify mmcblk0 data "/ on sda21 resolves"
setup internal
sed -i 's|^/boot /dev/sda21 |/boot composefs |' "$tmp/findmnt"
classify mmcblk0 system "composefs at /boot"

setup internal
rm "$sys/fs/btrfs/4acb1123-998a-460a-a5a5-e2c85d82d9b4/devices/sda22"
classify mmcblk0 system "empty btrfs devices dir"
setup internal
rm -r "$sys/fs/btrfs/4acb1123-998a-460a-a5a5-e2c85d82d9b4"
classify mmcblk0 system "missing btrfs devices dir"
setup internal
ln -s ../../../../devices/fixture/block/mmcblk0/mmcblk0p1 "$sys/fs/btrfs/4acb1123-998a-460a-a5a5-e2c85d82d9b4/devices/mmcblk0p1"
classify mmcblk0 system "card in the root btrfs"
setup internal
ln -s ../../../../devices/fixture/block/sda/nope "$sys/fs/btrfs/4acb1123-998a-460a-a5a5-e2c85d82d9b4/devices/nope"
classify mmcblk0 system "unresolved btrfs device"
setup internal
rm "$sys/class/block/sda21"
classify mmcblk0 system "/boot device missing from sysfs"
for t in / /sysroot /var /etc /boot /boot/efi; do
  setup internal
  run FINDMNT_FAIL="$t" classify mmcblk0
  out_is system "findmnt error on $t"
done
setup internal
sed -i 's|^/boot/efi /dev/sda20 |/boot/efi /dev/sda20[/x] |' "$tmp/findmnt"
classify mmcblk0 system "bracketed vfat source"
setup internal-coldplug
classify mmcblk0 system "coldplug without /boot"
classify sda system "coldplug UFS"

setup internal
mkdir -p "$sys/devices/virtual/block/dm-0/slaves"
ln -s ../../devices/virtual/block/dm-0 "$sys/class/block/dm-0"
ln -s ../../../../fixture/block/mmcblk0/mmcblk0p1 "$sys/devices/virtual/block/dm-0/slaves/mmcblk0p1"
sed -i 's|^/boot /dev/sda21 |/boot /dev/dm-0 |' "$tmp/findmnt"
classify mmcblk0 system "/boot on dm over the card"
rm "$sys/devices/virtual/block/dm-0/slaves/mmcblk0p1"
classify mmcblk0 data "/boot on dm with no slaves"

setup booted-sd
classify mmcblk0 system "booted from the MicroOS SD"
grep -q 'blkid' "$tmp/bcalls" && fail "booted from the MicroOS SD: rule 1 did not decide before blkid"
classify sda system "UFS while booted from the MicroOS SD"
for p in mmcblk0p1 mmcblk0p2 mmcblk0p3; do
  setup booted-sd
  echo "/dev/$p /x ext4 rw 1" >> "$tmp/mounts"
  run BUS_UNMOUNT=fail unmount "$p"
  code 0 "unmount $p booted from the MicroOS SD"
  not_called '^busctl' "unmount $p booted from the MicroOS SD"
  not_called '^umount' "unmount $p booted from the MicroOS SD"
  grep -q blkid "$tmp/bcalls" && fail "unmount $p booted from the MicroOS SD: blkid ran"
  run mount "$p"
  code 0 "mount $p booted from the MicroOS SD"
  not_called '^busctl' "mount $p booted from the MicroOS SD"
  not_called '^fsck' "mount $p booted from the MicroOS SD"
  grep -q blkid "$tmp/bcalls" && fail "mount $p booted from the MicroOS SD: blkid ran"
done

setup internal
echo MMC > "$sys/block/mmcblk0/device/type"
classify mmcblk0 system "device/type MMC"
setup internal
rm "$sys/block/mmcblk0/device/type"
classify mmcblk0 system "no device/type"
setup internal
run BLKID_FAIL=/dev/mmcblk0p1 classify mmcblk0
out_is system "blkid error"
setup internal
jq '(.. | objects | select(.name? == "mmcblk0p1")).partlabel = "ARMADA_ROOT"' "$tmp/lsblk.json" > "$tmp/j" && mv "$tmp/j" "$tmp/lsblk.json"
classify mmcblk0 system "card with partlabel ARMADA_ROOT"
setup internal
jq '(.. | objects | select(.name? == "mmcblk0p1")).label = "MICROOS"' "$tmp/lsblk.json" > "$tmp/j" && mv "$tmp/j" "$tmp/lsblk.json"
classify mmcblk0 system "card with label MICROOS"

setup microos-sd
classify mmcblk0 system "MicroOS SD hot inserted"
classify sda system "UFS with the MicroOS SD in"
run mount mmcblk0p2
code 0 "mount MicroOS SD p2"
not_called '^fsck.ext4' "mount MicroOS SD p2"
not_called '^busctl' "mount MicroOS SD p2"
log_lines 1 "mount MicroOS SD p2"
logged 'system disk' "mount MicroOS SD p2"
grep -q 'blkid -p -o export /dev/mmcblk0p1' "$tmp/bcalls" || fail "mount p2 did not probe p1 with blkid -p"

setup internal
run mount mmcblk0p1
code 0 "mount card"
called "^busctl call --allow-interactive-authorization=false --expect-reply=true --json=short org.freedesktop.UDisks2 /org/freedesktop/UDisks2/block_devices/mmcblk0p1 org.freedesktop.UDisks2.Filesystem Mount a\\\\{sv\\\\} 3 as-user s micro auth.no_user_interaction b true options s noatime\$" "mount card"
called '^fsck.ext4 -y /dev/mmcblk0p1$' "mount card"
(( $(line_of '^fsck.ext4') < $(line_of '^busctl') )) || fail "mount card: fsck after the mount"
not_called '^systemd-run' "mount card"
logged "mounted at $media (noatime)" "mount card"
logged 'fsck.ext4 started' "mount card"
logged 'fsck.ext4 ended with status 0' "mount card"

run mount mmcblk0p1
code 0 "mount card already mounted"
not_called '^fsck.ext4' "mount card already mounted"
not_called '^busctl' "mount card already mounted"

setup internal
run RC_fsck_ext4=4 mount mmcblk0p1
code 0 "mount card fsck 4"
called 'options s noatime\\,ro$' "mount card fsck 4"
called '^systemd-run -M micro@ --user --collect --quiet /usr/bin/steam -ifrunning steam://system/devicemountresult/%6d%6d%63%62%6c%6b%30%70%31%2f%31$' "mount card fsck 4"

setup internal
run RC_fsck_ext4=1 mount mmcblk0p1
code 0 "mount card fsck 1"
called 'options s noatime$' "mount card fsck 1"
not_called '^systemd-run' "mount card fsck 1"

setup internal
run BUS_MODE=already mount mmcblk0p1
code 0 "mount AlreadyMounted"
logged "mounted at $media (noatime)" "mount AlreadyMounted"

setup internal
run BUS_MODE=other mount mmcblk0p1
code 0 "mount at uuid1"
logged "mounted at ${media}1, expected $media" "mount at uuid1"

setup internal
run BUS_MODE=fail mount mmcblk0p1
code 1 "mount failure"
called 'steam://system/devicemountresult/%6d%6d%63%62%6c%6b%30%70%31%2f%32$' "mount failure"

setup internal
run BUS_UNKNOWN=2 mount mmcblk0p1
code 0 "mount after UnknownObject twice"
(( $(grep -c '^busctl call .* Mount ' "$tmp/calls") == 3 )) || fail "mount after UnknownObject twice: $(cat "$tmp/calls")"
logged "mounted at $media (noatime)" "mount after UnknownObject twice"
setup internal
run BUS_UNKNOWN=1000 MICROOS_STORAGE_MOUNT_RETRY=1 mount mmcblk0p1
code 1 "mount UnknownObject past the retry window"
(( $(grep -c '^busctl call .* Mount ' "$tmp/calls") == 3 )) || fail "mount UnknownObject past the retry window: $(cat "$tmp/calls")"
called 'devicemountresult/%6d%6d%63%62%6c%6b%30%70%31%2f%32$' "mount UnknownObject past the retry window"
setup internal
run BUS_MODE=fail mount mmcblk0p1
(( $(grep -c '^busctl call .* Mount ' "$tmp/calls") == 1 )) || fail "mount other error retried: $(cat "$tmp/calls")"

setup internal
jq '(.. | objects | select(.name? == "mmcblk0p1")).fstype = "ntfs"' "$tmp/lsblk.json" > "$tmp/j" && mv "$tmp/j" "$tmp/lsblk.json"
run mount mmcblk0p1
code 0 "mount ntfs"
not_called '^busctl' "mount ntfs"
not_called '^fsck' "mount ntfs"
for fs in btrfs exfat vfat; do
  setup internal
  jq --arg f "$fs" '(.. | objects | select(.name? == "mmcblk0p1")).fstype = $f' "$tmp/lsblk.json" > "$tmp/j" && mv "$tmp/j" "$tmp/lsblk.json"
  run mount mmcblk0p1
  code 0 "mount $fs"
  called '^busctl call .* Mount ' "mount $fs"
  not_called '^fsck' "mount $fs"
done

setup internal
run mount sda22
code 0 "mount sda22"
not_called '^busctl' "mount sda22"
setup internal
echo MMC > "$sys/block/mmcblk0/device/type"
run mount mmcblk0p1
code 0 "mount MMC type"
not_called '^busctl' "mount MMC type"
not_called '^fsck' "mount MMC type"
log_lines 1 "mount MMC type"

setup internal
run unmount mmcblk0p1
code 0 "unmount not mounted"
not_called '^busctl' "unmount not mounted"
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 1" >> "$tmp/mounts"
run unmount mmcblk0p1
code 0 "unmount"
called '^busctl call .* Unmount a\\{sv\\} 1 auth.no_user_interaction b true$' "unmount"
not_called '^umount' "unmount"
[[ ! -s $tmp/mounts ]] || fail "unmount: still mounted"
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 1" >> "$tmp/mounts"
run BUS_UNMOUNT=fail unmount mmcblk0p1
code 0 "unmount fallback"
called "^umount -l $media\$" "unmount fallback"
setup internal
rm "$dev/mmcblk0"
run unmount mmcblk0p1
code 0 "unmount pulled card"
not_called '^busctl' "unmount pulled card"
not_called '^umount' "unmount pulled card"
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 1" >> "$tmp/mounts"
run unmount mmcblk0p1
code 0 "unmount pulled card with a leftover mount"
called "^umount -l $media\$" "unmount pulled card with a leftover mount"
not_called '^busctl' "unmount pulled card with a leftover mount"
run RC_umount=32 unmount mmcblk0p1
code 1 "unmount pulled card, umount -l fails"
setup microos-sd
echo "/dev/mmcblk0p3 /sysroot btrfs rw 1" >> "$tmp/mounts"
run BUS_UNMOUNT=fail unmount mmcblk0p3
code 0 "unmount MicroOS SD root"
not_called '^busctl' "unmount MicroOS SD root"
not_called '^umount' "unmount MicroOS SD root"

setup internal
flock -o -x "$dev/mmcblk0" sleep 1 &
holder=$!
sleep 0.3
start=$(date +%s%N)
run MICROOS_STORAGE_LOCK_WAIT=5 mount mmcblk0p1
took=$(( ($(date +%s%N) - start) / 1000000 ))
code 0 "mount behind a held lock"
called '^busctl call .* Mount ' "mount behind a held lock"
(( took >= 400 )) || fail "mount behind a held lock: took $took ms, did not wait"
wait "$holder" || true
setup internal
flock -o -x "$dev/mmcblk0" sleep 6 &
holder=$!
sleep 0.3
run mount mmcblk0p1
code 1 "mount lock timeout"
not_called '^busctl' "mount lock timeout"
not_called '^fsck' "mount lock timeout"
log_lines 1 "mount lock timeout"
run format --skip-validation --device /dev/mmcblk0
code 53 "format with a held lock"
no_writer "format with a held lock"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
holder=""

setup internal
run format --version
code 0 "format --version"
out_is 1 "format --version"
run format --skip-validation --device /dev/mmcblk0
code 0 "format"
called '^mkfs.ext4 -m 0 -O casefold -E nodiscard\\,root_owner=1000:1000 -F /dev/mmcblk0p1$' "format default owner"
called '^wipefs -a /dev/mmcblk0p1$' "format"
called '^wipefs -a /dev/mmcblk0$' "format"
called '^sfdisk -q /dev/mmcblk0$' "format"
not_called '^f3probe' "format --skip-validation"
called '^systemctl stop microos-automount@mmcblk0p1.service lock=free$' "format stop before the lock"
called '^systemctl start microos-automount@mmcblk0p1.service lock=free$' "format start after release"
called '^udevadm settle$' "format"
(( $(line_of '^wipefs -a /dev/mmcblk0p1') < $(line_of '^wipefs -a /dev/mmcblk0$') )) || fail "format: disk wiped before the partition"
(( $(line_of '^wipefs -a /dev/mmcblk0$') < $(line_of '^sfdisk') && $(line_of '^sfdisk') < $(line_of '^mkfs.ext4') &&
  $(line_of '^mkfs.ext4') < $(line_of '^udevadm') && $(line_of '^udevadm') < $(line_of '^systemctl start') )) ||
  fail "format: writer order: $(cat "$tmp/calls")"
called '^microos-pad-hold BTN_SOUTH 1 15 hint=live:/dev/mmcblk0 lock=held$' "format hold"
called "^mv -f -- $tmp/run/hold/\.storage\.[A-Za-z0-9]\{6\} $tmp/run/hold/storage\$" "format hint written by rename"
(( $(line_of '^mv -f -- .*/hold/') < $(line_of '^microos-pad-hold') )) || fail "format: hint renamed after the hold started"
[[ -z $(find "$tmp/run/hold" -name '.storage.*') ]] || fail "format: hint temp file left: $(ls -A "$tmp/run/hold")"
(( $(line_of '^microos-pad-hold') < $(line_of '^systemctl stop') )) || fail "format: units stopped before the hold"
[[ ! -e $tmp/run/hold/storage ]] || fail "format: hint file left"
run RC_pad_hold=1 format --skip-validation --device /dev/mmcblk0
code 77 "format without the hold"
no_writer "format without the hold"
not_called '^systemctl' "format without the hold"
logged 'A not held for 1 s within 15 s, nothing written' "format without the hold"
logged '^-t microos-pad-hold microos-pad-hold: refused: BTN_SOUTH not held for 1 s$' "format without the hold"
grep -q 'refused: BTN_SOUTH not held' "$tmp/out" || fail "format without the hold: helper reason not on stderr: $(cat "$tmp/out")"
[[ ! -e $tmp/run/hold/storage ]] || fail "format without the hold: hint file left"
run RC_pad_hold=3 format --skip-validation --device /dev/mmcblk0
code 53 "format while another A hold waits"
no_writer "format while another A hold waits"
logged 'another A hold is waiting, nothing written' "format while another A hold waits"
[[ ! -e $tmp/run/hold/storage ]] || fail "format while another A hold waits: hint file left"
flock -o -x "$tmp/run/lock/format.lock" sleep 4 &
holder=$!
sleep 0.3
run format --skip-validation --device /dev/mmcblk0
code 53 "format while another format waits"
not_called '^microos-pad-hold' "format while another format waits"
no_writer "format while another format waits"
not_called '^systemctl' "format while another format waits"
[[ ! -e $tmp/run/hold/storage ]] || fail "format while another format waits: hint file written"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
holder=""
run RC_pad_hold=1 format --dry-run --device /dev/mmcblk0
code 0 "format --dry-run without the hold"
not_called '^microos-pad-hold' "format --dry-run"
run RC_pad_hold=1 format --version
code 0 "format --version without the hold"
not_called '^microos-pad-hold' "format --version"
run format --label "" --skip-validation --device /dev/mmcblk0
code 0 "format empty label"
not_called ' -L ' "format empty label"
run format --label "Steam Deck SD" --full --owner 1001:1002 --skip-validation --device /dev/mmcblk0
code 0 "format label"
called '^mkfs.ext4 -m 0 -O casefold -E discard\\,root_owner=1001:1002 -L Steam\\ Deck\\ SD -F /dev/mmcblk0p1$' "format label full owner"
run format --force --quick --full --quick --device /dev/mmcblk0
code 0 "format --force"
not_called '^f3probe' "format --force"
called '-E nodiscard' "format --quick last"
run format --device /dev/mmcblk0
code 0 "format validated"
called '^f3probe --destructive /dev/mmcblk0$' "format validated"
(( $(line_of '^f3probe') < $(line_of '^wipefs') )) || fail "format validated: f3probe after wipefs"
not_called '^mkfs.exfat' "format validated"

for args in "--bogus" "--label 12345678901234567" "--label $(printf 'a\tb')" "--owner micro" "--owner 1000" "--owner 1000:1000:1" \
  "--device /dev/mmcblk0 extra"; do
  read -ra a <<< "$args"
  [[ $args != *$'\t'* ]] || a=(--label "$(printf 'a\tb')")
  run format --skip-validation "${a[@]}" --device /dev/mmcblk0
  code 22 "format $args"
  no_writer "format $args"
  not_called '^systemctl' "format $args"
done
for l in MICROOS microos MicroOs; do
  run format --skip-validation --label "$l" --device /dev/mmcblk0
  code 22 "format --label $l"
  no_writer "format --label $l"
  not_called '^systemctl' "format --label $l"
done
run format --skip-validation --label 1234567890123456 --device /dev/mmcblk0
code 0 "format 16 byte label"
for d in /dev/sda /dev/mmcblk0p1 "/dev/mmcblk0 " /dev/mmcblk10 mmcblk0 /dev/mmcblk1 ""; do
  run format --skip-validation --device "$d"
  code 19 "format --device '$d'"
  no_writer "format --device '$d'"
  not_called '^systemctl' "format --device '$d'"
done
run format --skip-validation
code 19 "format without --device"

setup microos-sd
for args in "--skip-validation" "" "--dry-run" "--dry-run --skip-validation"; do
  read -ra a <<< "$args"
  run format "${a[@]}" --device /dev/mmcblk0
  code 13 "format MicroOS SD $args"
  no_writer "format MicroOS SD $args"
  not_called '^systemctl' "format MicroOS SD $args"
done
setup booted-sd
for args in "--skip-validation" "" "--dry-run" "--dry-run --skip-validation"; do
  read -ra a <<< "$args"
  run format "${a[@]}" --device /dev/mmcblk0
  code 13 "format booted MicroOS SD $args"
  not_called '^microos-pad-hold' "format booted MicroOS SD $args"
  no_writer "format booted MicroOS SD $args"
  not_called '^systemctl' "format booted MicroOS SD $args"
  grep -q blkid "$tmp/bcalls" && fail "format booted MicroOS SD $args: blkid ran"
done
setup internal
echo MMC > "$sys/block/mmcblk0/device/type"
run format --skip-validation --device /dev/mmcblk0
code 13 "format MMC type"
no_writer "format MMC type"

setup internal
run SEQ_BUMP=wipefs format --skip-validation --device /dev/mmcblk0
code 16 "format diskseq change after wipefs"
called '^wipefs -a /dev/mmcblk0p1$' "format diskseq change after wipefs"
not_called '^wipefs -a /dev/mmcblk0$' "format diskseq change after wipefs"
not_called '^sfdisk' "format diskseq change after wipefs"
not_called '^mkfs' "format diskseq change after wipefs"
not_called '^systemctl start' "format diskseq change after wipefs"
setup internal
run SEQ_BUMP=systemctl format --skip-validation --device /dev/mmcblk0
code 16 "format diskseq change at the unit stop"
no_writer "format diskseq change at the unit stop"
setup internal
run SEQ_BUMP=f3probe format --device /dev/mmcblk0
code 16 "format diskseq change after f3probe"
not_called '^wipefs' "format diskseq change after f3probe"

setup internal
run RC_f3probe=1 format --device /dev/mmcblk0
code 14 "format fake card"
called '^mkfs.exfat /dev/mmcblk0p1$' "format fake card"
called "^sfdisk -q /dev/mmcblk0\$" "format fake card"
not_called '^mkfs.ext4' "format fake card"
not_called '^systemctl start' "format fake card"
setup internal
run RC_f3probe=1 SEQ_BUMP=sfdisk format --device /dev/mmcblk0
code 16 "format fake card diskseq change after sfdisk"
not_called '^mkfs.exfat' "format fake card diskseq change after sfdisk"

setup internal
run RC_systemctl=1 format --skip-validation --device /dev/mmcblk0
code 5 "format unit failed"
called '^mkfs.ext4' "format unit failed"

setup internal
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 1" >> "$tmp/mounts"
run format --skip-validation --device /dev/mmcblk0
code 32 "format mounted child"
no_writer "format mounted child"
called '^systemctl stop microos-automount@mmcblk0p1.service lock=free$' "format mounted child"
not_called '^systemctl start' "format mounted child"

setup internal
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 1" >> "$tmp/mounts"
run format --dry-run --device /dev/mmcblk0
code 0 "format --dry-run mounted"
no_writer "format --dry-run mounted"
not_called '^systemctl' "format --dry-run mounted"
not_called '^udevadm' "format --dry-run mounted"
grep -qxF "systemctl stop microos-automount@mmcblk0p1.service" "$tmp/out" || fail "format --dry-run: no stop line: $(cat "$tmp/out")"
grep -qxF "release /dev/mmcblk0p1 $media" "$tmp/out" || fail "format --dry-run: no release line: $(cat "$tmp/out")"
for l in "f3probe --destructive /dev/mmcblk0" "wipefs -a /dev/mmcblk0p1" "wipefs -a /dev/mmcblk0" \
  "sfdisk -q /dev/mmcblk0 <<< \$'label: gpt\\nstart=2048, type=L'" \
  "mkfs.ext4 -m 0 -O casefold -E nodiscard\\,root_owner=1000:1000 -F /dev/mmcblk0p1" \
  "systemctl start microos-automount@mmcblk0p1.service"; do
  grep -qxF -- "$l" "$tmp/out" || fail "format --dry-run: missing '$l' in: $(cat "$tmp/out")"
done
[[ $(< "$tmp/mounts") == "/dev/mmcblk0p1 $media ext4 rw,noatime 1" ]] || fail "format --dry-run: card unmounted"
run format --dry-run --device /dev/sda
code 19 "format --dry-run /dev/sda"
run SEQ_BUMP=nothing format --dry-run --device /dev/mmcblk0
code 0 "format --dry-run again"
echo 10 > "$sys/block/mmcblk0/diskseq"
flock -o -x "$dev/mmcblk0" sleep 5 &
holder=$!
sleep 0.3
run format --dry-run --device /dev/mmcblk0
code 53 "format --dry-run with a held lock"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
flock -o -s "$dev/mmcblk0" sleep 1 &
holder=$!
sleep 0.3
run format --dry-run --device /dev/mmcblk0
code 0 "format --dry-run behind a brief shared lock"
wait "$holder" 2> /dev/null || true
holder=""

mkdir -p "$tmp/badlog"
for f in "$bin"/*; do
  [[ ${f##*/} == logger ]] || ln -s "$f" "$tmp/badlog/${f##*/}"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/badlog/logger"
chmod +x "$tmp/badlog/logger"
setup microos-sd
STUB_PATH=$tmp/badlog run format --skip-validation --device /dev/mmcblk0
code 13 "format system disk with a failing logger"
setup internal
STUB_PATH=$tmp/badlog run mount mmcblk0p1
code 0 "mount with a failing logger"

mkdir -p "$tmp/nof3"
for f in "$bin"/*; do
  [[ ${f##*/} == f3probe ]] || ln -s "$f" "$tmp/nof3/${f##*/}"
done
mkdir -p "$tmp/nof3sys"
for f in /usr/bin/* /bin/*; do
  [[ ${f##*/} == f3probe || -e $tmp/nof3sys/${f##*/} ]] || ln -s "$f" "$tmp/nof3sys/${f##*/}"
done
setup internal
STUB_PATH=$tmp/nof3 SYS_PATH=$tmp/nof3sys run format --device /dev/mmcblk0
code 2 "format without f3probe"
no_writer "format without f3probe"
not_called '^systemctl' "format without f3probe"
STUB_PATH=$tmp/nof3 SYS_PATH=$tmp/nof3sys run format --skip-validation --device /dev/mmcblk0
code 0 "format without f3probe, skipped validation"

sdcard=$tmp/format-sdcard.sh
sed "s|/usr/libexec/microos/microos-storage|$storage|" "$tree/usr/lib/hwsupport/format-sdcard.sh" > "$sdcard"
chmod +x "$sdcard"
setup microos-sd
storage=$sdcard run --skip-validation
code 19 "format-sdcard.sh with only system disks"
no_writer "format-sdcard.sh with only system disks"
setup booted-sd
storage=$sdcard run --skip-validation
code 19 "format-sdcard.sh booted from the MicroOS SD"
not_called '^microos-pad-hold' "format-sdcard.sh booted from the MicroOS SD"
no_writer "format-sdcard.sh booted from the MicroOS SD"
grep -q blkid "$tmp/bcalls" && fail "format-sdcard.sh booted from the MicroOS SD: blkid ran"
setup internal
storage=$sdcard run --skip-validation
code 0 "format-sdcard.sh with the card"
called '^mkfs.ext4 .* -F /dev/mmcblk0p1$' "format-sdcard.sh with the card"
storage=$tree/usr/libexec/microos/microos-storage

setup internal
[[ $(< "$sys/class/block/mmcblk0p1/size") == 966520832 ]] || fail "fixture: mmcblk0p1 size $(< "$sys/class/block/mmcblk0p1/size")"
echo 5767168 > "$sys/class/block/mmcblk0p1/size"
printf '%s\n' "/dev/mmcblk0p1 $media ext4 rw,noatime" "/dev/sda22 /sysroot btrfs rw,noatime" \
  "/dev/sda22 /var btrfs rw,noatime" "/dev/sda21 /boot ext4 ro,relatime" "/dev/sda2 /persist ext4 rw,relatime" \
  "/dev/sda20 /boot/efi vfat rw,relatime" > "$tmp/mounts"
run RC_pad_hold=1 trim
code 0 "trim"
not_called "^microos-pad-hold" "trim"
want=$(printf '%s\n' "fstrim -o 0 -l 1073741824 $media" "fstrim -o 1073741824 -l 1073741824 $media" \
  "fstrim -o 2147483648 -l 1073741824 $media" "fstrim /sysroot" "fstrim -o 0 -l 1073741824 /persist")
[[ $(grep '^fstrim' "$tmp/calls") == "$want" ]] || fail "trim: $(cat "$tmp/calls")"
echo 0x000003 > "$sys/block/mmcblk0/device/manfid"
run trim
code 0 "trim manfid 0x000003"
not_called "^fstrim .* $media\$" "trim manfid 0x000003"
called '^fstrim /sysroot$' "trim manfid 0x000003"
logged 'not safe to trim' "trim manfid 0x000003"
echo 1 > "$sys/block/mmcblk0/device/safe_trim_quirk"
run trim
called "^fstrim -o 0 -l 1073741824 $media\$" "trim manfid 0x000003 with safe_trim_quirk 1"
echo 0x000002 > "$sys/block/mmcblk0/device/manfid"
rm "$sys/block/mmcblk0/device/safe_trim_quirk"
echo 0x5344 > "$sys/block/mmcblk0/device/oemid"
run trim
not_called "^fstrim .* $media\$" "trim oemid 0x5344"
setup internal
echo "/dev/mmcblk0p1 $media ext4 rw,noatime 3221225472" > "$tmp/mounts"
run RC_fstrim=1 trim
code 1 "trim failure"
log_lines 1 "trim failure"
rm "$sys/class/block/mmcblk0p1/size"
run trim
code 1 "trim without a partition size"
not_called '^fstrim' "trim without a partition size"
logged 'no size' "trim without a partition size"
: > "$tmp/mounts"
run trim
code 0 "trim nothing mounted"
not_called '^fstrim' "trim nothing mounted"
setup booted-sd
printf '%s\n' "/dev/mmcblk0p3 /sysroot btrfs rw,noatime" "/dev/mmcblk0p3 /var btrfs rw,noatime" \
  "/dev/mmcblk0p2 /boot ext4 ro,relatime" "/dev/mmcblk0p1 /boot/efi vfat rw,relatime" > "$tmp/mounts"
run trim
code 0 "trim booted from the MicroOS SD"
not_called '^fstrim' "trim booted from the MicroOS SD"
logged '/sysroot: mmcblk0 is not safe to trim, skipped' "trim booted from the MicroOS SD"
grep -q blkid "$tmp/bcalls" && fail "trim booted from the MicroOS SD: blkid ran"
echo 0x000002 > "$sys/block/mmcblk0/device/manfid"
echo 0x544d > "$sys/block/mmcblk0/device/oemid"
run trim
code 0 "trim booted from the MicroOS SD with manfid and oemid"
[[ $(grep '^fstrim' "$tmp/calls") == "fstrim /sysroot" ]] || fail "trim booted from the MicroOS SD with manfid and oemid: $(cat "$tmp/calls")"
grep -q blkid "$tmp/bcalls" && fail "trim booted from the MicroOS SD with manfid and oemid: blkid ran"

probe=$fixtures/internal/mounts
setup internal
cp "$probe" "$tmp/mounts"
run content
code 0 "content rw card"
link_is "$media" "content rw card"
content_locked "content rw card"
card_untouched "content rw card"
called "^mv -T -- $tmp/run/content.new $tmp/run/content\$" "content rw card"
not_called "^ln -sfn -- [^ ]* $tmp/run/content\$" "content rw card"
log_lines 1 "content rw card"
logged "mmcblk0p1 at $media is the content card" "content rw card"
grep -q 'blkid -p -o export /dev/mmcblk0p1' "$tmp/bcalls" || fail "content rw card: is_data did not probe mmcblk0p1"
grep -qvE '/dev/mmcblk' "$tmp/bcalls" && fail "content rw card: blkid on a non card device: $(cat "$tmp/bcalls")"
before=$(mtime)
run content
code 0 "content unchanged"
link_is "$media" "content unchanged"
[[ $(mtime) == "$before" ]] || fail "content unchanged: link rewritten"
not_called '^mv ' "content unchanged"
log_lines 0 "content unchanged"

setup internal
sed 's|^\(/dev/mmcblk0p1 [^ ]* ext4 \)rw,|\1ro,|' "$probe" > "$tmp/mounts"
grep -q '^/dev/mmcblk0p1 .* ro,' "$tmp/mounts" || fail "content ro card: fixture not ro"
run content
code 0 "content ro card"
link_is "$media" "content ro card"

setup internal
ln -s "$media" "$tmp/run/content"
grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
run content
code 0 "content no card"
link_is "" "content no card"
logged 'no content card' "content no card"
grep -q blkid "$tmp/bcalls" && fail "content no card: blkid ran"
run content
code 0 "content no card again"
log_lines 0 "content no card again"

setup microos-sd
grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
echo "/dev/mmcblk0p2 /run/media/micro/MICROOS_ROOT ext4 rw,nosuid,nodev" >> "$tmp/mounts"
run content
code 0 "content MicroOS SD"
link_is "" "content MicroOS SD"
logged 'mmcblk0p2 is on a system disk' "content MicroOS SD"

setup booted-sd
cp "$fixtures/booted-sd/mounts" "$tmp/mounts"
run content
code 0 "content booted from the MicroOS SD"
link_is "" "content booted from the MicroOS SD"
log_lines 0 "content booted from the MicroOS SD"
grep -q blkid "$tmp/bcalls" && fail "content booted from the MicroOS SD: blkid ran"
run FINDMNT_FAIL=/boot content
code 0 "content booted from the MicroOS SD, system disks not read"
logged 'mmcblk0p2 at /boot refused' "content booted from the MicroOS SD, system disks not read"
logged 'mmcblk0p1 at /boot/efi refused' "content booted from the MicroOS SD, system disks not read"

setup internal
grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
printf '%s\n' "/dev/mmcblk0p10 /run/media/micro/ten ext4 rw" "/dev/mmcblk0p2 /run/media/micro/two ext4 rw" \
  "/dev/mmcblk0p1 $media ext4 rw" >> "$tmp/mounts"
run content
code 0 "content two partitions"
link_is "$media" "content two partitions"
logged 'mmcblk0p2 not used, /dev/mmcblk0p1 is the content card' "content two partitions"
logged 'mmcblk0p10 not used, /dev/mmcblk0p1 is the content card' "content two partitions"
(( $(grep -c 'blkid -p -o export /dev/mmcblk0p1$' "$tmp/bcalls") == 1 )) || fail "content two partitions: is_data ran per partition"

setup internal
grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
printf '%s\n' '/dev/mmcblk0p1 /run/media/micro/Steam\x20Deck exfat rw' >> "$tmp/mounts"
run content
code 0 "content label with a space"
link_is "/run/media/micro/Steam Deck" "content label with a space"

for row in "/dev/loop0 /run/media/micro/disk ext4 rw|no content card" \
  "/dev/mmcblk0p1[/sub] $media btrfs rw|no content card" \
  "/dev/mmcblk10p1 $media ext4 rw|no content card" \
  "/dev/mmcblk0p1 /mnt/card ext4 rw|refused" \
  "/dev/mmcblk0p1 /run/media/micro ext4 rw|refused" \
  "/dev/mmcblk0p1 /run/media/micro/a/b ext4 rw|refused" \
  "/dev/mmcblk0p1 /run/media/micro/.. ext4 rw|refused" \
  "/dev/mmcblk0p1 /run/media/micro/. ext4 rw|refused" \
  "/dev/mmcblk0p1 /run/media/other/$card ext4 rw|refused" \
  '/dev/mmcblk0p1 /run/media/micro/a\x22b ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\x0ab ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\x0a ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\x0db ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\x09b ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\xffb ext4 rw|refused' \
  '/dev/mmcblk0p1 /run/media/micro/a\xc3 ext4 rw|refused'; do
  setup internal
  ln -s "$media" "$tmp/run/content"
  grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
  echo "${row%|*}" >> "$tmp/mounts"
  run content
  code 0 "content ${row%|*}"
  link_is "" "content ${row%|*}"
  logged "${row##*|}" "content ${row%|*}"
  grep -q blkid "$tmp/bcalls" && fail "content ${row%|*}: blkid ran before the target checks"
done

setup internal
grep -v '^/dev/mmcblk' "$probe" > "$tmp/mounts"
{ run POLL_ADD=1 POLL_ROW="/dev/mmcblk0p1 $media ext4 rw,nosuid,nodev,noatime,errors=remount-ro" POLL_KILL=3 content-watch; } 2> /dev/null
code 143 "content-watch"
link_is "$media" "content-watch late mount"
! grep -q '^bad poll' "$tmp/poll" || fail "content-watch: $(grep '^bad poll' "$tmp/poll")"
grep -qxF 'findmnt --poll --first-only --timeout 5000' "$tmp/fcalls" || fail "content-watch: poll argv: $(grep poll "$tmp/fcalls")"
mapfile -t ticks < "$tmp/poll"
(( ${#ticks[@]} == 3 )) || fail "content-watch: ${#ticks[@]} ticks: ${ticks[*]}"
[[ ${ticks[0]} == "1 0 none" ]] || fail "content-watch: first tick '${ticks[0]}'"
read -r b2 m2 <<< "${ticks[1]#* }"
read -r b3 m3 <<< "${ticks[2]#* }"
(( b2 > 0 )) || fail "content-watch: no blkid after the mount: ${ticks[*]}"
(( b3 == b2 )) || fail "content-watch: blkid on an unchanged candidate set: ${ticks[*]}"
[[ $m2 != none && $m3 == "$m2" ]] || fail "content-watch: link mtime changed on an unchanged set: ${ticks[*]}"
content_locked "content-watch"
card_untouched "content-watch"
(( $(grep -c '^mv -T ' "$tmp/calls") == 1 )) || fail "content-watch: link written $(grep -c '^mv -T ' "$tmp/calls") times"

setup internal
cp "$probe" "$tmp/mounts"
: > "$tmp/blkid-once"
{ run BLKID_FAIL_ONCE="$tmp/blkid-once" POLL_KILL=2 content-watch; } 2> /dev/null
code 143 "content-watch blkid error"
link_is "$media" "content-watch blkid error"
mapfile -t ticks < "$tmp/poll"
[[ ${ticks[0]} == "1 1 none" ]] || fail "content-watch blkid error: first tick '${ticks[0]}'"
[[ ${ticks[1]} == "2 2 "* && ${ticks[1]} != *none ]] || fail "content-watch blkid error: second tick '${ticks[1]}'"
logged 'mmcblk0 not readable, /dev/mmcblk0p1 checked again at the next tick' "content-watch blkid error"

setup internal
ln -s "$media" "$tmp/run/content"
cp "$probe" "$tmp/mounts"
{ run BLKID_FAIL=/dev/mmcblk0p1 POLL_KILL=3 content-watch; } 2> /dev/null
code 143 "content-watch lasting blkid error"
link_is "$media" "content-watch lasting blkid error"
(( $(grep -c 'not readable' "$tmp/log") == 1 )) ||
  fail "content-watch lasting blkid error: logged $(grep -c 'not readable' "$tmp/log") times"
(( $(grep -c '^blkid ' "$tmp/bcalls") == 3 )) ||
  fail "content-watch lasting blkid error: $(grep -c '^blkid ' "$tmp/bcalls") blkid runs, want one per tick"

setup internal
cp "$probe" "$tmp/mounts"
echo "/dev/loop0 /run/media/micro/disk ext4 rw" >> "$tmp/mounts"
{ run POLL_KILL=3 POLL_ADD=1 POLL_ROW="/dev/loop1 /run/media/micro/disk2 ext4 rw" content-watch; } 2> /dev/null
code 143 "content-watch loop mounts"
link_is "$media" "content-watch loop mounts"
(( $(grep -c '^blkid ' "$tmp/bcalls") == 1 )) ||
  fail "content-watch loop mounts: $(grep -c '^blkid ' "$tmp/bcalls") blkid runs, want 1"
log_lines 1 "content-watch loop mounts"
setup internal
ln -s "$media" "$tmp/run/content"
cp "$probe" "$tmp/mounts"
run BLKID_FAIL=/dev/mmcblk0p1 content
code 0 "content blkid error keeps the link"
link_is "$media" "content blkid error keeps the link"

setup internal
ln -s "$media" "$tmp/run/content"
cp "$probe" "$tmp/mounts"
run FINDMNT_TABLE_FAIL=1 content
code 1 "content mount table error keeps the link"
link_is "$media" "content mount table error keeps the link"
logged 'mount table not read' "content mount table error keeps the link"
: > "$tmp/mounts"
run content
code 0 "content empty mount table"
link_is "" "content empty mount table"

setup internal
run mount mmcblk0p1
code 0 "content after mount"
link_is "$media" "content after mount"
content_locked "content after mount"
(( $(line_of '^busctl call .* Mount ') < $(line_of '^mv -T ') )) || fail "content after mount: link before the mount"
run mount mmcblk0p1
code 0 "content after mount, already mounted"
link_is "$media" "content after mount, already mounted"
run unmount mmcblk0p1
code 0 "content after unmount"
link_is "" "content after unmount"
content_locked "content after unmount"
logged 'no content card' "content after unmount"
setup internal
ln -s "$media" "$tmp/run/content"
rm "$dev/mmcblk0"
run unmount mmcblk0p1
code 0 "content after a pulled card"
link_is "" "content after a pulled card"
setup internal
run BUS_MODE=fail mount mmcblk0p1
code 1 "content after a failed mount"
link_is "" "content after a failed mount"

setup internal
cp "$probe" "$tmp/mounts"
flock -o -x "$tmp/run/lock/content" sleep 1 &
holder=$!
sleep 0.3
run content
code 0 "content behind a held lock"
link_is "$media" "content behind a held lock"
wait "$holder" || true
rm "$tmp/run/content"
flock -o -x "$tmp/run/lock/content" sleep 6 &
holder=$!
sleep 0.3
run content
code 1 "content lock timeout"
link_is "" "content lock timeout"
logged 'lock not taken' "content lock timeout"
: > "$tmp/mounts"
run mount mmcblk0p1
code 0 "mount with the content lock held"
logged 'lock not taken' "mount with the content lock held"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
holder=""
setup internal
rmdir "$tmp/run/lock"
cp "$probe" "$tmp/mounts"
run content
code 1 "content without the lock dir"
link_is "" "content without the lock dir"

cunit=$tree/usr/lib/systemd/system/microos-content.service
for l in 'Type=simple' 'ExecStartPre=/usr/libexec/microos/microos-storage content' \
  'ExecStart=/usr/libexec/microos/microos-storage content-watch' 'Before=display-manager.service' 'Restart=always' \
  'RestartSec=1' 'StartLimitIntervalSec=120' 'StartLimitBurst=30' 'WantedBy=multi-user.target'; do
  grep -qxF -- "$l" "$cunit" || fail "content unit lacks $l"
done
after=$(sed -n 's/^After=//p' "$cunit")
for a in local-fs.target udisks2.service; do
  [[ " $after " == *" $a "* ]] || fail "content unit After= lacks $a: $after"
done

rules=$tree/usr/lib/udev/rules.d/61-microos-automount.rules
unit=$tree/usr/lib/systemd/system/microos-automount@.service
sysrules=/usr/lib/udev/rules.d
if [[ -e $sysrules/60-persistent-storage.rules && -e $sysrules/99-systemd.rules ]]; then
  listing=$( (ls "$sysrules"; echo "${rules##*/}") | LC_ALL=C sort -u)
else
  listing=$(printf '%s\n' 99-systemd.rules "${rules##*/}" 60-persistent-storage.rules | LC_ALL=C sort)
fi
at() { grep -nxF "$1" <<< "$listing" | cut -d: -f1; }
(( $(at 60-persistent-storage.rules) < $(at "${rules##*/}") && $(at "${rules##*/}") < $(at 99-systemd.rules) )) ||
  fail "rule order: $(paste -sd' ' <<< "$listing")"
for m in 'SUBSYSTEM=="block"' 'ACTION!="remove"' 'KERNEL=="mmcblk[0-9]p[0-9]*"' 'ENV{ID_FS_USAGE}=="filesystem"' \
  'ENV{UDISKS_AUTO}="0"' 'TAG+="systemd"' 'ENV{SYSTEMD_WANTS}+="microos-automount@%k.service"'; do
  grep -qF -- "$m" "$rules" || fail "rule lacks $m"
done
! grep -qE 'RUN|PROGRAM|IMPORT' "$rules" || fail "rule runs a program"
if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$rules" || fail "automount rules do not verify"
else
  fail "udevadm missing, automount rules unchecked"
fi
for l in 'BindsTo=dev-%i.device' 'Type=oneshot' 'RemainAfterExit=yes' \
  'ExecStart=/usr/libexec/microos/microos-storage mount %i' 'ExecStop=/usr/libexec/microos/microos-storage unmount %i' \
  'TimeoutStartSec=infinity' 'TimeoutStopSec=30'; do
  grep -qxF -- "$l" "$unit" || fail "unit lacks $l"
done
after=$(sed -n 's/^After=//p' "$unit")
for a in local-fs.target dev-%i.device udisks2.service; do
  [[ " $after " == *" $a "* ]] || fail "unit After= lacks $a: $after"
done
if [[ -x /usr/libexec/microos/microos-storage ]] && command -v systemd-analyze > /dev/null; then
  d=$tmp/units
  mkdir -p "$d"
  cp "$unit" "$d/"
  systemd-analyze verify --man=no "$d/microos-automount@mmcblk0p1.service" || fail "unit does not verify"
fi

if (( rc == 0 )); then
  echo "storage: ok ($checks checks)"
fi
exit "$rc"
