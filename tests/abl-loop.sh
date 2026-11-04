#!/usr/bin/env bash
set -uo pipefail

me=abl-loop
here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tool=$tree/usr/libexec/microos/microos-abl

fail() { echo "FAIL: $me: $*" >&2; exit 1; }
((EUID == 0)) || fail "run as root"
command -v losetup > /dev/null || fail "no losetup"
[[ -f $tool ]] || fail "no $tool"

work=$(mktemp -d)
loops=()
cleanup() {
  local l
  for l in "${loops[@]}"; do
    losetup -d "$l" 2> /dev/null || true
  done
  rm -rf "${work:?}"
}
trap cleanup EXIT

python3 - "$work" <<'PY'
import hashlib
import os
import struct
import sys
import uuid
import zlib

work = sys.argv[1]
ssz = 4096


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data, mode=0o644):
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    os.chmod(path, mode)


def make_elf(body=b"CODE" * 256, sections=2):
    phoff = 52
    phentsize = 32
    base = phoff + phentsize * 2
    shoff = base + len(body)
    shentsize = 40
    total = shoff + shentsize * sections
    data = bytearray(total)
    data[:4] = b"\x7fELF"
    data[4] = 1
    data[5] = 1
    data[6] = 1
    struct.pack_into("<I", data, 28, phoff)
    struct.pack_into("<H", data, 42, phentsize)
    struct.pack_into("<H", data, 44, 2)
    struct.pack_into("<I", data, 32, shoff)
    struct.pack_into("<H", data, 46, shentsize)
    struct.pack_into("<H", data, 48, sections)
    end = base + len(body)
    struct.pack_into("<I", data, phoff + 4, 0)
    struct.pack_into("<I", data, phoff + 16, end)
    data[base:end] = body
    return bytes(data), max(end, shoff + shentsize * sections)


def gpt(path, size, parts):
    sectors = size // ssz
    disk = uuid.uuid4()
    table = bytearray(128 * 128)
    for index, (label, first, last, attrs) in enumerate(parts):
        entry = bytearray(128)
        entry[0:16] = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le
        entry[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQQ", entry, 32, first, last, attrs)
        name = label.encode("utf-16-le")[:72]
        entry[56:56 + len(name)] = name
        table[index * 128:(index + 1) * 128] = entry
    ecrc = zlib.crc32(bytes(table)) & 0xffffffff

    def header(lba, alt, elba):
        head = bytearray(92)
        head[0:8] = b"EFI PART"
        struct.pack_into("<I", head, 8, 0x00010000)
        struct.pack_into("<I", head, 12, 92)
        struct.pack_into("<Q", head, 24, lba)
        struct.pack_into("<Q", head, 32, alt)
        struct.pack_into("<Q", head, 40, 34)
        struct.pack_into("<Q", head, 48, sectors - 34)
        head[56:72] = disk.bytes_le
        struct.pack_into("<Q", head, 72, elba)
        struct.pack_into("<I", head, 80, 128)
        struct.pack_into("<I", head, 84, 128)
        struct.pack_into("<I", head, 88, ecrc)
        struct.pack_into("<I", head, 16, zlib.crc32(bytes(head)) & 0xffffffff)
        return bytes(head)

    mbr = bytearray(512)
    mbr[446 + 1:446 + 4] = b"\x00\x02\x00"
    mbr[446 + 4] = 0xEE
    mbr[446 + 5:446 + 8] = b"\xff\xff\xff"
    struct.pack_into("<I", mbr, 446 + 8, 1)
    struct.pack_into("<I", mbr, 446 + 12, sectors - 1)
    mbr[510:512] = b"\x55\xaa"
    with open(path, "wb") as f:
        f.truncate(size)
        f.seek(0)
        f.write(mbr)
        f.seek(ssz)
        f.write(header(1, sectors - 1, 2))
        f.seek(2 * ssz)
        f.write(table)
        f.seek((sectors - 33) * ssz)
        f.write(table)
        f.seek((sectors - 1) * ssz)
        f.write(header(sectors - 1, 1, sectors - 33))


def make_root(root):
    os.makedirs(os.path.join(root, "esp"))
    data, length = make_elf()
    digest = sha(data)
    write(os.path.join(root, "abl_signed-SM8250.elf"), data)
    write(os.path.join(root, "abl_signed-SM8250.elf.sha256"), f"{digest}  abl_signed-SM8250.elf\n")
    write(os.path.join(root, "manifest"),
          f"MICROOS_ABL_FORMAT=1\nMICROOS_ABL_VERSION=9.9\nMICROOS_ABL_SOC=SM8250\n"
          f"MICROOS_ABL_LENGTH={length}\nMICROOS_ABL_SHA256={digest}\nMICROOS_ABL_ADMITTED={digest}\n")
    for name in ("README",):
        write(os.path.join(root, "esp", name), "# ROCKNIX ABL\n")
    for name in ("backup_abl.sh", "flash_abl.sh", "restore_backup_abl.sh"):
        write(os.path.join(root, "esp", name), f"#!/system/bin/sh\necho {name[:-3]}\n", 0o755)
    older, older_length = make_elf(b"OLD" * 2000)
    rows = "order\tversion\tsoc\tlength\tsha256\n"
    rows += f"1\t1.2\tSM8250\t{older_length}\t{sha(older[:older_length])}\n"
    rows += f"2\t9.9\tSM8250\t{length}\t{sha(data[:length])}\n"
    write(os.path.join(root, "releases.tsv"), rows)
    slot = older + bytes([0xFF]) * (256 * 1024 - len(older))
    write(os.path.join(work, "older.img"), slot)
    write(os.path.join(work, "payload-length"), f"{length}\n")


os.makedirs(os.path.join(work, "esp"))
os.makedirs(os.path.join(work, "state"))
os.makedirs(os.path.join(work, "run"))
os.makedirs(os.path.join(work, "dt"))
os.makedirs(os.path.join(work, "power", "ac"))
os.makedirs(os.path.join(work, "stubs", "bootimg"))
os.makedirs(os.path.join(work, "bin"))
make_root(os.path.join(work, "payload"))
write(os.path.join(work, "dt", "compatible"), b"ayaneo,pocket-micro2\0qcom,sm8250\0")
write(os.path.join(work, "cmdline"), "quiet microos.deploy=" + "a" * 64 + ".0\n")
write(os.path.join(work, "bootid"), "0123456789abcdef\n")
write(os.path.join(work, "state", "confirmed"), "a" * 64 + ".0\n")
write(os.path.join(work, "power", "ac", "type"), "Mains\n")
write(os.path.join(work, "power", "ac", "online"), "1\n")
write(os.path.join(work, "stubs", "bootimg", "rc"), "0\n")

stubs = {
    "systemd-inhibit": """#!/usr/bin/env bash
printf 'inhibit %s\\n' "$*" >> "$CALLS"
while [[ $# -gt 0 ]]; do
  case $1 in
    --what=*|--mode=*|--who=*|--why=*) shift ;;
    *) break ;;
  esac
done
MICROOS_ABL_INHIBITED=1 exec "$@"
""",
    "bootimg-update": """#!/usr/bin/env bash
printf 'bootimg %s\\n' "$*" >> "$CALLS"
exit "$(cat "$STUB_DIR/bootimg/rc")"
""",
}
for name, text in stubs.items():
    write(os.path.join(work, "bin", name), text, 0o755)

gpt(os.path.join(work, "disk1.img"), 16 * 1024 * 1024,
    [("boot_a", 34, 49, 0x4), ("boot_b", 50, 65, 0x0),
     ("abl_a", 66, 129, 0x0), ("abl_b", 130, 193, 0x0)])
gpt(os.path.join(work, "disk2.img"), 8 * 1024 * 1024,
    [("boot_a", 34, 49, 0x4), ("boot_b", 50, 65, 0x0), ("abl_a", 66, 129, 0x0)])
PY

loop1=$(losetup --sector-size 4096 --show --find --partscan "$work/disk1.img") || fail "losetup disk1"
loops+=("$loop1")
loop2=$(losetup --sector-size 4096 --show --find --partscan "$work/disk2.img") || fail "losetup disk2"
loops+=("$loop2")
for _ in $(seq 50); do
  [[ -b ${loop1}p4 && -b ${loop2}p3 ]] && break
  sleep 0.1
done
[[ -b ${loop1}p3 && -b ${loop1}p4 ]] || fail "no partition nodes on $loop1"
[[ -b ${loop2}p3 ]] || fail "no partition node on $loop2"

dd if="$work/older.img" of="${loop1}p3" bs=4096 conv=fsync status=none || fail "cannot seed abl_a"
dd if="$work/older.img" of="${loop1}p4" bs=4096 conv=fsync status=none || fail "cannot seed abl_b"
dd if="$work/older.img" of="${loop2}p3" bs=4096 conv=fsync status=none || fail "cannot seed the second abl_a"

length=$(< "$work/payload-length")
digest=$(sha256sum "$work/payload/abl_signed-SM8250.elf" | cut -d' ' -f1)
zero=$(printf '0%.0s' $(seq 64))
run() {
  env -u MICROOS_ABL_INHIBITED \
    MICROOS_ESP="$work/esp" \
    MICROOS_RUNDIR="$work/run" \
    MICROOS_STATEDIR="$work/state" \
    MICROOS_BOOTIMG_UPDATE="$work/bin/bootimg-update" \
    MICROOS_SYSTEMD_INHIBIT="$work/bin/systemd-inhibit" \
    MICROOS_DT="$work/dt" \
    MICROOS_POWER_SUPPLY="$work/power" \
    MICROOS_CMDLINE="$work/cmdline" \
    MICROOS_BOOTID="$work/bootid" \
    MICROOS_ABL_ROOT="$work/payload" \
    MICROOS_ABL_CATALOG="$work/payload/releases.tsv" \
    MICROOS_ABL_SCAN="$1" \
    CALLS="$work/calls.log" \
    STUB_DIR="$work/stubs" \
    python3 "$tool" "${@:2}"
}

status=$(run "$loop1" status 2>&1) || fail "status failed: $status"
[[ $(tail -n 1 <<< "$status") == "microos-abl: eligible" ]] ||
  fail "status is '$(tail -n 1 <<< "$status")', not eligible"
grep -q "slot a 1.2" <<< "$status" || fail "status does not name slot a as 1.2"
grep -qx "microos-abl: confirmed yes" <<< "$status" || fail "status is not confirmed"

dd if="${loop1}p3" of="$work/before-a.img" bs=4096 status=none
dd if="${loop1}p4" of="$work/before-b.img" bs=4096 status=none
out=$(run "$loop1" update "$zero" 2>&1) && fail "a wrong hash was accepted: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: refused: confirm" ]] ||
  fail "wrong hash: $(tail -n 1 <<< "$out")"
cmp "$work/before-a.img" "${loop1}p3" || fail "abl_a changed after a refused confirmation"
cmp "$work/before-b.img" "${loop1}p4" || fail "abl_b changed after a refused confirmation"
echo "abl-loop: a wrong confirmation leaves both slots untouched"

out=$(run "$loop1" update "$digest") || fail "update failed: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: updated 9.9" ]] || fail "update: $(tail -n 1 <<< "$out")"
cmp -n "$length" "$work/payload/abl_signed-SM8250.elf" "${loop1}p3" || fail "abl_a does not hold the payload"
cmp -n "$length" "$work/payload/abl_signed-SM8250.elf" "${loop1}p4" || fail "abl_b does not hold the payload"
python3 - "$work/state/abl/journal.json" <<'PY' || fail "the journal does not name the write order"
import json
import sys
journal = json.load(open(sys.argv[1]))
assert journal["order"] == ["b", "a"], journal["order"]
assert journal["written"] == ["a", "b"], journal["written"]
assert journal["phase"] == "done", journal["phase"]
PY
grep -q "inhibit --what=sleep --mode=block --who=microos-abl" "$work/calls.log" ||
  fail "the sleep inhibitor was not asked for"
echo "abl-loop: wrote the inactive slot first and read both back under the inhibitor"

out=$(run "$loop1" update "$digest") || fail "rerun failed: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: current" ]] || fail "rerun: $(tail -n 1 <<< "$out")"
echo "abl-loop: a rerun prints current"

dd if="$work/older.img" of="${loop1}p3" bs=4096 conv=fsync status=none || fail "cannot reseed abl_a"
dd if="$work/older.img" of="${loop1}p4" bs=4096 conv=fsync status=none || fail "cannot reseed abl_b"
python3 - "$work/state/abl/journal.json" <<'PY' || fail "cannot craft the torn journal"
import json
import sys
path = sys.argv[1]
journal = json.load(open(path))
journal["phase"] = "writing-b"
journal["written"] = []
with open(path, "w") as f:
    json.dump(journal, f, sort_keys=True)
    f.write("\n")
PY
dd if="$work/payload/abl_signed-SM8250.elf" of="${loop1}p4" bs=4096 count=1 conv=fsync status=none ||
  fail "cannot tear abl_b"
out=$(run "$loop1" update "$digest") || fail "resume failed: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: updated 9.9" ]] || fail "resume: $(tail -n 1 <<< "$out")"
cmp -n "$length" "$work/payload/abl_signed-SM8250.elf" "${loop1}p4" || fail "abl_b was not resumed"
cmp -n "$length" "$work/payload/abl_signed-SM8250.elf" "${loop1}p3" || fail "abl_a was not written"
echo "abl-loop: a torn slot on 4096 byte sectors resumes"

name=$(python3 - "$work/state/abl/journal.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["original"]["a"]["name"])
PY
)
image=$work/esp/rocknix_abl/SM8250/microos-backup/$name
[[ -f $image ]] || fail "no backup $image"
out=$(run "$loop1" restore a "$image") || fail "restore failed: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: restored a $(sha256sum "$image" | cut -d' ' -f1)" ]] ||
  fail "restore: $(tail -n 1 <<< "$out")"
cmp "$image" "${loop1}p3" || fail "abl_a does not hold the restored backup"
echo "abl-loop: restored abl_a from its backup"

out=$(run "$loop1 $loop2" update "$digest" 2> /dev/null) && fail "a second abl_a was not refused: $out"
[[ $(tail -n 1 <<< "$out") == "microos-abl: refused: partitions" ]] || fail "duplicate: $(tail -n 1 <<< "$out")"
echo "abl-loop: a second device carrying abl_a is refused"

if command -v mksh > /dev/null; then
  block=$work/block
  mkdir -p "$block" "$work/backups" "$work/empty"
  ln -s "${loop1}p3" "$block/abl_a"
  ln -s "${loop1}p4" "$block/abl_b"
  esp=$work/payload/esp
  if ! out=$(ABL_BLOCK_DIR=$block ABL_BACKUP=$work/backups ABL_PAYLOAD=$esp mksh "$esp/backup_abl.sh" 2>&1); then
    fail "backup_abl.sh: $out"
  fi
  img=$(awk 'NR == 1 { print $3 }' <<< "$out")
  printf 'x\n' >> "$img"
  if ABL_BLOCK_DIR=$block ABL_BACKUP=$work/backups ABL_PAYLOAD=$esp mksh "$esp/backup_abl.sh" > /dev/null 2>&1; then
    fail "backup_abl.sh accepted a colliding image"
  fi
  out=$(ABL_BLOCK_DIR=$block ABL_BACKUP=$work/backups ABL_PAYLOAD=$esp mksh "$esp/restore_backup_abl.sh" a "$img" 2>&1) &&
    fail "restore_backup_abl.sh accepted a corrupted image: $out"
  ABL_BLOCK_DIR=$block ABL_BACKUP=$work/empty ABL_PAYLOAD=$esp mksh "$esp/flash_abl.sh" > /dev/null 2>&1 &&
    fail "flash_abl.sh ran without backups"
  ABL_BLOCK_DIR=$block ABL_BACKUP=$work/backups ABL_PAYLOAD=$esp mksh "$esp/flash_abl.sh" > /dev/null 2>&1 &&
    fail "flash_abl.sh wrote a slot at the payload's own order"
  echo "abl-loop: the ESP scripts refuse what they must under mksh"
else
  echo "abl-loop: SKIP the ESP script checks, mksh is not installed"
fi

echo "abl-loop: ok"
