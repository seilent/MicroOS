#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tool=$tree/usr/libexec/microos/microos-groups
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

r=$tmp/root
mk() {
  rm -rf "$r"
  mkdir -p "$r/etc" "$r/usr/etc" "$r/usr/lib/sysusers.d"
  cp "$tree/usr/lib/sysusers.d/microos.conf" "$r/usr/lib/sysusers.d/"
  printf 'root:x:0:\nwheel:x:10:micro\nsystemd-journal:x:190:micro\nmicro:x:1000:\nsddm:x:973:\n' > "$r/etc/group"
  printf 'root:::\nwheel:::micro\nmicro:!::\nsddm:!::\n' > "$r/etc/gshadow"
  printf 'root:x:0:0::/root:/bin/bash\nmicro:x:1000:1000:MicroOS:/var/home/micro:/bin/bash\n' > "$r/etc/passwd"
  printf 'root:!locked::0:::::\nmicro:$6$h::0:::::\n' > "$r/etc/shadow"
  printf 'root:x:0:\nwheel:x:10:micro\nvideo:x:39:micro\nmicro:x:1000:\nsddm:x:975:\nnewgrp:x:960:\nclash:x:973:\n' > "$r/usr/etc/group"
  printf 'root:::\nvideo:!::micro\nnewgrp:!::\nclash:!::\n' > "$r/usr/etc/gshadow"
  printf 'root:x:0:0::/root:/bin/bash\nnewusr:x:960:960::/:/usr/sbin/nologin\nmicro:x:1000:1000::/var/home/micro:/bin/bash\n' > "$r/usr/etc/passwd"
  printf 'root:!locked::0:::::\nnewusr:!*::0:::::\n' > "$r/usr/etc/shadow"
  printf 'video:x:39:\nrender:x:105:\n' > "$r/usr/lib/group"
}
run() { out=$("$tool" "$r" 2>&1) && code=0 || code=$?; }
count() { grep -c "^$1:" "$2" || true; }

[[ -x $tool ]] || { echo "FAIL: $tool missing"; exit 1; }

mk
cp "$r/etc/group" "$tmp/group.before"
run
[[ $code == 0 ]] || fail "exit $code: $out"
grep -qx 'video:x:39:micro' "$r/etc/group" || fail "video line not copied from /usr/etc/group"
grep -qx 'video:!::micro' "$r/etc/gshadow" || fail "video gshadow line not copied"
grep -qx 'newgrp:x:960:' "$r/etc/group" || fail "newgrp not copied"
grep -qx 'newusr:x:960:960::/:/usr/sbin/nologin' "$r/etc/passwd" || fail "newusr not copied"
grep -qx 'newusr:!\*::0:::::' "$r/etc/shadow" || fail "newusr shadow line not copied"
grep -qx 'sddm:x:973:' "$r/etc/group" || fail "sddm renumbered"
[[ $(count sddm "$r/etc/group") == 1 ]] || fail "sddm added twice"
[[ $(count clash "$r/etc/group") == 0 ]] || fail "clash added with a taken GID"
grep -q 'clash in /usr/etc/group has id 973, which is taken' <<< "$out" || fail "no message for clash: $out"
[[ $(count micro "$r/etc/passwd") == 1 ]] || fail "micro added twice"
[[ $(head -n 5 "$r/etc/group") == "$(cat "$tmp/group.before")" ]] || fail "existing group lines changed"
[[ $(count render "$r/etc/group") == 0 ]] || fail "render copied, micro is not a member"

mk
printf 'orphan:x:961:959::/:/usr/sbin/nologin\n' >> "$r/usr/etc/passwd"
run
[[ $(count orphan "$r/etc/passwd") == 0 ]] || fail "orphan added without its group"
grep -q 'orphan in /usr/etc/passwd has group 959, which no group file holds' <<< "$out" || fail "no message for orphan: $out"

cp "$r/etc/group" "$tmp/group.once"
cp "$r/etc/passwd" "$tmp/passwd.once"
run
[[ $code == 0 ]] || fail "second run exit $code"
cmp -s "$r/etc/group" "$tmp/group.once" || fail "second run changed /etc/group"
cmp -s "$r/etc/passwd" "$tmp/passwd.once" || fail "second run changed /etc/passwd"

mk
sed -i '/^video:/d' "$r/usr/etc/group"
run
grep -qx 'video:x:39:' "$r/etc/group" || fail "video not copied from /usr/lib/group for the m micro line"

mk
sed -i '/^video:/d' "$r/usr/etc/group" "$r/usr/lib/group"
run
[[ $code == 0 ]] || fail "a group in neither file: exit $code"
[[ $(count video "$r/etc/group") == 0 ]] || fail "video invented"

mk
rm -r "$r/usr/etc"
run
[[ $code == 0 ]] || fail "build root without /usr/etc: exit $code"
grep -qx 'video:x:39:' "$r/etc/group" || fail "build root: video not copied from /usr/lib/group"

if command -v systemd-sysusers > /dev/null; then
  mk
  sed -i '/^video:/d' "$r/usr/etc/group"
  run
  systemd-sysusers --root="$r" "$r/usr/lib/sysusers.d/microos.conf" > /dev/null 2>&1 || fail "systemd-sysusers --root failed"
  grep -qx 'video:x:39:micro' "$r/etc/group" || fail "sysusers did not add micro to video: $(grep '^video:' "$r/etc/group")"
fi

if (( rc == 0 )); then
  echo "groups: all cases passed"
fi
exit "$rc"
