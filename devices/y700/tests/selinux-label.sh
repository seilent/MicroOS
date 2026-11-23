#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
label=$tree/usr/lib/dracut/modules.d/94microos-selinux-label/microos-selinux-label
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export FAKE_STATE=$tmp/fake PATH=$here/selinux-label/bin:$PATH MICROOS_UPTIME=$tmp/uptime
A=$(printf 'a%.0s' {1..64}).0
B=$(printf 'b%.0s' {1..64}).0
C=$(printf 'c%.0s' {1..64}).0
root=$tmp/root
sr=$root/ostree/deploy/default
sys=$tmp/sysroot
efi=$tmp/efi
run=$tmp/run
envf=$run/selinux-label.env
txt=$efi/logs/selinux-label.txt
fc=$sys/etc/selinux/targeted/contexts/files/file_contexts
g="initrd=7.4.0-rc2-microos 20261123T051150Z id=0123456789ab test=none count=1"

mkdep() {
  local e=$sr/deploy/$1/etc f
  mkdir -p "$e/ssh" "$e/selinux/targeted/contexts/files"
  for f in passwd shadow group gshadow hostname ssh/sshd_config ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub; do
    echo "$1 $f" > "$e/$f"
  done
  printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' > "$e/selinux/config"
  for f in file_contexts file_contexts.bin file_contexts.homedirs.bin file_contexts.local; do
    echo "$1 $f" > "$e/selinux/targeted/contexts/files/$f"
  done
  : > "$sr/deploy/$1.origin"
}
reset() {
  rm -rf "$root" "$sys" "$efi" "$run" "$FAKE_STATE" "$tmp/selinux" "$tmp/kmsg" "$tmp/label.err" "$tmp/other"
  mkdir -p "$FAKE_STATE" "$run" "$efi/logs" "$sys"
  mkdep "$A"
  mkdep "$B"
  for f in lib/microos/state log/journal/system.journal home/micro/.ssh/authorized_keys home/micro/notes cache/man/index.db; do
    mkdir -p "$(dirname "$sr/var/$f")"
    echo "$f" > "$sr/var/$f"
  done
  for f in loader/entries/ostree-1.conf ostree/default-c/vmlinuz; do
    mkdir -p "$(dirname "$root/boot/$f")"
    echo "$f" > "$root/boot/$f"
  done
  mkdir -p "$root/boot/efi"
  ln -s "$sr/deploy/$B/etc" "$sys/etc"
  echo "capability,landlock,lockdown,yama,loadpin,safesetid,ipe,selinux,bpf" > "$tmp/lsm"
  echo "root=PARTLABEL=microos ostree=/ostree/boot.1/default/x/0 microos.deploy=$B microos.id=0123456789ab" > "$tmp/cmdline"
  echo "100.00 300.00" > "$tmp/uptime"
  : > "$efi/logs/guard.txt"
  find "$root" -type f ! -name '*.origin' | LC_ALL=C sort > "$FAKE_STATE/unlabeled"
}
labelrun() {
  env MICROOS_CMDLINE="$tmp/cmdline" MICROOS_LSM="$tmp/lsm" MICROOS_SYSROOT="$sys" MICROOS_RUNDIR="$run" \
    MICROOS_ROOT_DEV="$tmp/dev/microos" MICROOS_EFI_DEV="$tmp/dev/microos_efi" MICROOS_LABEL_MNT="$root" \
    MICROOS_LABEL_EFI="$efi" MICROOS_INITRD_SELINUX="$tmp/selinux" MICROOS_KMSG="$tmp/kmsg" \
    MICROOS_MOUNTS="$FAKE_STATE/mounts" SERVICE_RESULT="${result:-success}" sh "$label" "$1" 2>> "$tmp/label.err"
}
boot() {
  ecode=0
  vcode=none
  rcode=none
  labelrun etc || ecode=$?
  [[ -f $envf ]] || return 0
  vcode=0
  labelrun var || vcode=$?
  rcode=0
  if [[ $vcode == 0 ]]; then
    result=success labelrun result || rcode=$?
  else
    result=exit-code labelrun result || rcode=$?
  fi
}
fchash() {
  (cd "$sr/deploy/$1/etc/selinux/targeted/contexts/files" &&
    sha256sum file_contexts file_contexts.bin file_contexts.homedirs.bin file_contexts.local) | sha256sum | cut -c1-12
}
last() { tail -n 1 "$efi/logs/guard.txt"; }
kmsg() { cat "$tmp/kmsg" 2> /dev/null || true; }
key() { sed -n "s/^$1=//p" "$envf"; }
unlabeled() { grep -qxF "$1" "$FAKE_STATE/unlabeled"; }
mounted() { [[ -s $FAKE_STATE/mounts ]]; }
calls() { cat "$FAKE_STATE/$1.log" 2> /dev/null || true; }
fatal() {
  [[ $ecode != 0 && ! -e $envf && $vcode == none ]] || fail "$1: etc exit $ecode, env $(cat "$envf" 2> /dev/null)"
  ! mounted || fail "$1: left mounted: $(cat "$FAKE_STATE/mounts")"
  [[ -z $(kmsg) && ! -s $efi/logs/guard.txt ]] || fail "$1: a label line written"
}
skipped() {
  [[ $ecode == 0 && ! -e $envf && $vcode == none && ! -e $FAKE_STATE/mount.log && ! -e $FAKE_STATE/setfiles.log ]] \
    || fail "$1: etc exit $ecode, mounts $(calls mount)"
  [[ -z $(kmsg) && ! -s $efi/logs/guard.txt ]] || fail "$1: a label line written"
}

[[ -x $label ]] || { echo "FAIL: $label missing"; exit 1; }

reset
etcn=$(find "$sr/deploy/$B/etc" -type f | wc -l)
varn=$(find "$sr/var" "$root/boot" -type f | wc -l)
hb=$(fchash "$B")
boot
[[ $ecode == 0 && $vcode == 0 && $rcode == 0 ]] || fail "plain: etc exit $ecode, var exit $vcode, result exit $rcode: $(cat "$tmp/label.err")"
[[ $(key dep) == "$sr/deploy/$B" && $(key sr) == "$sr" && $(key fc) == "$fc" && $(key hash) == "$hb" ]] \
  || fail "plain: env $(cat "$envf")"
[[ $(key etcn) == "$etcn" && $(key etc) == ok ]] || fail "plain: etc count $(key etcn) $(key etc), want $etcn ok"
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" ]] || fail "plain: guard.txt $(last)"
[[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var $varn in 5 s" ]] || fail "plain: kmsg $(kmsg)"
[[ -e $txt && ! -s $txt ]] || fail "plain: selinux-label.txt $(cat "$txt" 2> /dev/null)"
[[ $(calls setfiles | head -n 2) == "setfiles -m -v -T 0 -r $sr/deploy/$B $fc $sr/deploy/$B/etc
setfiles -m -n -v -r $sr/deploy/$B $fc $sr/deploy/$B/etc/passwd $sr/deploy/$B/etc/shadow $sr/deploy/$B/etc/group \
$sr/deploy/$B/etc/gshadow $sr/deploy/$B/etc/ssh/sshd_config $sr/deploy/$B/etc/ssh/ssh_host_ed25519_key \
$sr/deploy/$B/etc/selinux/config" ]] || fail "plain: /etc pass and check $(calls setfiles | head -n 2)"
[[ $(calls timeout) == "timeout -k 10 270 setfiles -m -v -T 0 -r $sr $fc $sr/var/lib
timeout -k 10 269 setfiles -m -v -T 0 -r $sr $fc $sr/var/log
timeout -k 10 268 setfiles -m -v -T 0 -r $sr $fc $sr/var/home/micro/.ssh
timeout -k 10 267 setfiles -m -v -T 0 -r $root $fc $root/boot
timeout -k 10 266 setfiles -m -v -T 0 -r $sr -e $sr/var/lib -e $sr/var/log -e $sr/var/home/micro/.ssh $fc $sr/var" ]] \
  || fail "plain: /var and /boot passes $(calls timeout)"
! grep -q -- ' -F' "$FAKE_STATE/setfiles.log" || fail "plain: setfiles run with -F"
[[ $(grep -c '^setfiles -m ' "$FAKE_STATE/setfiles.log") == $(wc -l < "$FAKE_STATE/setfiles.log") ]] \
  || fail "plain: setfiles run without -m: $(calls setfiles)"
grep -qxF "mount -t btrfs -o rw,subvol=root $tmp/dev/microos $root" "$FAKE_STATE/mount.log" || fail "plain: $(calls mount)"
grep -qxF "mount -t vfat -o umask=0077 $tmp/dev/microos_efi $efi" "$FAKE_STATE/mount.log" || fail "plain: $(calls mount)"
[[ $(calls umount) == "umount $root
umount $efi
umount $root" ]] || fail "plain: unmounts $(calls umount)"
! mounted || fail "plain: left mounted: $(cat "$FAKE_STATE/mounts")"
[[ $(readlink "$tmp/selinux") == "$sys/etc/selinux" ]] || fail "plain: $tmp/selinux links to $(readlink "$tmp/selinux")"
unlabeled "$sr/deploy/$A/etc/passwd" || fail "plain: the other deployment's /etc labeled"
! grep -qF -e "$sr/deploy/$B/" -e "$sr/var/" -e "$root/boot/" "$FAKE_STATE/unlabeled" || fail "plain: left unlabeled: $(cat "$FAKE_STATE/unlabeled")"

reset
mkdir -p "$root/ostree/boot.1/default/$C"
ln -s "../../../deploy/default/deploy/$A" "$root/ostree/boot.1/default/$C/0"
echo "root=PARTLABEL=microos ostree=/ostree/boot.1/default/$C/0 microos.deploy=$B microos.id=0123456789ab" > "$tmp/cmdline"
echo "/ostree/boot.1/default/$C/0 /ostree/boot.0/default/$C/1" > "$run/remapped"
boot
[[ $ecode == 0 && $(key dep) == "$sr/deploy/$B" && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" ]] \
  || fail "remapped: etc exit $ecode, dep $(key dep), $(last)"
unlabeled "$sr/deploy/$A/etc/passwd" || fail "remapped: the deployment ostree= names labeled"
! unlabeled "$sr/deploy/$B/etc/passwd" || fail "remapped: the booted deployment's /etc not labeled"

reset
cp -a "$sr/deploy/$B/etc" "$tmp/other"
rm "$sys/etc"
ln -s "$tmp/other" "$sys/etc"
boot
fatal "no stat match"
[[ ! -e $FAKE_STATE/setfiles.log ]] || fail "no stat match: setfiles ran: $(calls setfiles)"
grep -q "0 deployments under $root hold $sys/etc" "$tmp/label.err" || fail "no stat match: $(cat "$tmp/label.err")"

reset
mkdir -p "$sr/deploy/$C"
ln -s "$sr/deploy/$B/etc" "$sr/deploy/$C/etc"
boot
fatal "two stat matches"
[[ ! -e $FAKE_STATE/setfiles.log ]] || fail "two stat matches: setfiles ran: $(calls setfiles)"
grep -q "2 deployments under $root hold $sys/etc" "$tmp/label.err" || fail "two stat matches: $(cat "$tmp/label.err")"

reset
echo broken >> "$sr/deploy/$B/etc/selinux/targeted/contexts/files/file_contexts"
boot
fatal "unloadable file_contexts"
unlabeled "$sr/deploy/$B/etc/passwd" || fail "unloadable file_contexts: passwd labeled"

reset
rm "$sr/deploy/$B/etc/selinux/targeted/contexts/files/file_contexts"
boot
fatal "no file_contexts"
[[ ! -e $FAKE_STATE/mount.log ]] || fail "no file_contexts: mounted $(calls mount)"

reset
printf '%s\tNo space left on device\n' "$sr/deploy/$B/etc/hostname" > "$FAKE_STATE/fail"
boot
[[ $ecode == 0 && $vcode == 0 && $(key etc) == partial && $(key etcn) == $(( etcn - 1 )) ]] \
  || fail "ENOSPC on hostname: etc exit $ecode, $(key etc), $(key etcn)"
[[ $(last) == "selinux-label fc=$hb dep=$B etc=partial var=walked" ]] || fail "ENOSPC on hostname: guard.txt $(last)"
[[ $(kmsg) == "selinux-label: dep $B etc $(( etcn - 1 )) partial var $varn in 5 s" ]] || fail "ENOSPC on hostname: kmsg $(kmsg)"
[[ $(< "$txt") == "errors 1
setfiles: Could not set context for $sr/deploy/$B/etc/hostname:  No space left on device" ]] \
  || fail "ENOSPC on hostname: selinux-label.txt $(cat "$txt")"
! mounted || fail "ENOSPC on hostname: left mounted"

reset
printf '%s\tNo space left on device\n' "$sr/deploy/$B/etc/shadow" > "$FAKE_STATE/fail"
boot
fatal "ENOSPC on shadow"
grep -qF "left without their labels: $sr/deploy/$B/etc/shadow" "$tmp/label.err" || fail "ENOSPC on shadow: $(cat "$tmp/label.err")"

reset
printf '%s\tNo space left on device\n' "$sr/deploy/$B/etc/ssh/ssh_host_ed25519_key" > "$FAKE_STATE/fail"
boot
fatal "ENOSPC on a host key"

reset
printf '%s\tInput/output error\n%s\tNo space left on device\n' "$sr/var/log/journal/system.journal" \
  "$sr/var/home/micro/notes" > "$FAKE_STATE/fail"
boot
[[ $ecode == 0 && $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] \
  || fail "/var errors: etc exit $ecode, var exit $vcode, $(last)"
[[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var partial in 5 s" ]] || fail "/var errors: kmsg $(kmsg)"
[[ $(< "$txt") == "errors 2
setfiles: Could not set context for $sr/var/log/journal/system.journal:  Input/output error
setfiles: Could not set context for $sr/var/home/micro/notes:  No space left on device" ]] \
  || fail "/var errors: selinux-label.txt $(cat "$txt")"
! unlabeled "$sr/var/cache/man/index.db" || fail "/var errors: the rest of /var not walked"
! mounted || fail "/var errors: left mounted"
rm "$FAKE_STATE/fail" "$envf"
boot
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" && -e $txt && ! -s $txt ]] \
  || fail "clean boot after errors: $(last), selinux-label.txt $(cat "$txt")"
[[ $(grep -c '^selinux-label ' "$efi/logs/guard.txt") == 2 ]] || fail "clean boot after errors: guard.txt $(cat "$efi/logs/guard.txt")"
! unlabeled "$sr/var/home/micro/notes" || fail "clean boot after errors: notes not walked again"

reset
printf '%s\tNo space left on device\n' "$root/boot/loader/entries/ostree-1.conf" > "$FAKE_STATE/fail"
boot
[[ $ecode == 0 && $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] \
  || fail "/boot errors: etc exit $ecode, var exit $vcode, $(last)"
[[ $(< "$txt") == "errors 1
setfiles: Could not set context for $root/boot/loader/entries/ostree-1.conf:  No space left on device" ]] \
  || fail "/boot errors: selinux-label.txt $(cat "$txt")"
! unlabeled "$root/boot/ostree/default-c/vmlinuz" || fail "/boot errors: the rest of /boot not walked"
! unlabeled "$sr/var/cache/man/index.db" || fail "/boot errors: the rest of /var not walked"
! mounted || fail "/boot errors: left mounted"

reset
rm -rf "${root:?}/boot"
boot
[[ $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" && $(calls timeout | wc -l) == 4 ]] \
  || fail "no /boot: $(last), $(calls timeout)"
! grep -qF -- "-r $root " "$FAKE_STATE/timeout.log" || fail "no /boot: walked $(calls timeout)"

reset
printf '%s 100\n%s 100\n%s 50\n%s 10\n%s 100\n' "$sr/var/lib" "$sr/var/log" "$sr/var/home/micro/.ssh" "$root/boot" "$sr/var" \
  > "$FAKE_STATE/dur"
boot
[[ $(calls timeout | cut -d' ' -f2-4) == "-k 10 270
-k 10 170
-k 10 70
-k 10 20
-k 10 10" ]] || fail "four /var paths and /boot past the cap: $(calls timeout)"
[[ $(< "$tmp/uptime") == "370.00 0.00" ]] || fail "four /var paths and /boot past the cap: ended at $(cat "$tmp/uptime"), want 370"
[[ $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "four /var paths and /boot past the cap: $(last)"
grep -qF "$sr/var stopped at the 270 s deadline" "$tmp/label.err" || fail "four /var paths and /boot past the cap: $(cat "$tmp/label.err")"
unlabeled "$sr/var/cache/man/index.db" || fail "four /var paths and /boot past the cap: the stopped pass labeled"
! unlabeled "$root/boot/loader/entries/ostree-1.conf" || fail "four /var paths and /boot past the cap: /boot not labeled"

reset
printf '%s 400\n' "$sr/var/lib" > "$FAKE_STATE/dur"
boot
[[ $(calls timeout) == "timeout -k 10 270 setfiles -m -v -T 0 -r $sr $fc $sr/var/lib" ]] || fail "past the remainder: $(calls timeout)"
[[ $(< "$tmp/uptime") == "370.00 0.00" ]] || fail "past the remainder: ended at $(cat "$tmp/uptime")"
[[ $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "past the remainder: $(last)"
for p in "$sr/var/log" "$root/boot" "$sr/var"; do
  grep -qF "the 270 s deadline passed, $p not walked" "$tmp/label.err" || fail "past the remainder: $p: $(cat "$tmp/label.err")"
done

lb="selinux-label fc=$hb dep=$A etc=ok var=walked"
gated() {
  local name=$1 want=$2 line=$3
  shift 3
  reset
  printf '%s\n' "$@" > "$efi/logs/guard.txt"
  [[ -z $line ]] || echo "$line" > "$run/guard-line"
  boot
  if [[ $want == skip ]]; then
    [[ $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=skipped" && -z $(calls timeout) ]] \
      || fail "gate $name: $(last), $(calls timeout)"
    [[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var skipped in 0 s" ]] || fail "gate $name: kmsg $(kmsg)"
    unlabeled "$sr/var/home/micro/notes" || fail "gate $name: /var walked"
    unlabeled "$root/boot/loader/entries/ostree-1.conf" || fail "gate $name: /boot walked"
  else
    [[ $vcode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" && $(calls timeout | wc -l) == 5 ]] \
      || fail "gate $name: $(last), $(calls timeout)"
  fi
  ! mounted || fail "gate $name: left mounted"
}
gated "after a walk" skip "$g" "$g" "$lb" "$g"
gated "after a skip" skip "$g" "$lb" "$g" "${lb/var=walked/var=skipped}" "$g"
gated "after a boot without SELinux" walk "$g" "$lb" "$g" "$g"
gated "with the previous guard line last" walk "" "$g" "$lb"
gated "with another boot's guard line last" walk "$g" "$g" "$lb" "${g/0123456789ab/ba9876543210}"
gated "at count=2" walk "${g/count=1/count=2}" "$g" "$lb" "${g/count=1/count=2}"
gated "at test=once" walk "${g/test=none/test=once}" "$g" "$lb" "${g/test=none/test=once}"
gated "with another fc hash" walk "$g" "$g" "${lb/fc=$hb/fc=000000000000}" "$g"
gated "after a partial walk" walk "$g" "$g" "${lb/var=walked/var=partial}" "$g"
gated "after a restore line" walk "$g" "$lb" "$g" \
  "restored 2c7a7f15c317 from boot-prev.img to /dev/disk/by-partlabel/boot_b after 3 starts of 0123456789ab" "$g"
gated "as the first line" walk "$g" "$g"

reset
printf '%s\n' "$g" "$lb" "$g" > "$efi/logs/guard.txt"
echo "$g" > "$run/guard-line"
labelrun etc
FAKE_MOUNT_FAIL=vfat labelrun var || fail "no ESP: var exit $?"
FAKE_MOUNT_FAIL=vfat result=success labelrun result
[[ $(calls timeout | wc -l) == 5 && $(last) == "$g" ]] || fail "no ESP: $(last), $(calls timeout)"
[[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var $varn in 5 s" ]] || fail "no ESP: kmsg $(kmsg)"
! mounted || fail "no ESP: left mounted"

reset
labelrun etc
labelrun var
result=timeout labelrun result
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "unit timeout after the walk: $(last)"
! mounted || fail "unit timeout after the walk: left mounted: $(cat "$FAKE_STATE/mounts")"
reset
labelrun etc
result=timeout labelrun result
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "unit timeout with no result: $(last)"
[[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var partial in 0 s" ]] || fail "unit timeout with no result: kmsg $(kmsg)"
! mounted || fail "unit timeout with no result: left mounted"
reset
labelrun etc
code=0
FAKE_MOUNT_FAIL=btrfs labelrun var || code=$?
result=exit-code labelrun result
[[ $code != 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "var mount fails: exit $code, $(last)"

reset
rm -rf "${sr:?}/var"
boot
[[ $ecode == 0 && $vcode == 1 && $rcode == 1 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] \
  || fail "no /var under sr: var exit $vcode, result exit $rcode, $(last)"
grep -qF "no $sr/var, /var not labeled" "$tmp/label.err" || fail "no /var under sr: $(cat "$tmp/label.err")"
! mounted || fail "no /var under sr: left mounted"
reset
labelrun etc
sed -i '/^sr=/d' "$envf"
code=0
labelrun var || code=$?
rcode=0
result=exit-code labelrun result || rcode=$?
[[ $code == 1 && $rcode == 1 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" && -z $(calls timeout) ]] \
  || fail "no sr= in the env: var exit $code, result exit $rcode, $(last)"
! mounted || fail "no sr= in the env: left mounted"

reset
FAKE_UMOUNT_FAIL=1 labelrun etc || fail "unmount fails: etc exit $?"
[[ -e $envf ]] || fail "unmount fails: no env"
grep -qF "cannot unmount $root" "$tmp/label.err" || fail "unmount fails: $(cat "$tmp/label.err")"
[[ $(calls umount) == "umount $root" ]] || fail "unmount fails: $(calls umount)"

reset
FAKE_EROFS=1 FAKE_MOUNT_RO=1 boot
fatal "read only label mount, listed files unlabeled"
grep -qF "left without their labels: $sr/deploy/$B/etc/passwd" "$tmp/label.err" \
  || fail "read only label mount, listed files unlabeled: $(cat "$tmp/label.err")"
reset
listed=()
for f in passwd shadow group gshadow ssh/sshd_config ssh/ssh_host_ed25519_key selinux/config; do
  listed+=(-e "$sr/deploy/$B/etc/$f")
done
grep -vxF "${listed[@]}" "$FAKE_STATE/unlabeled" > "$tmp/unlabeled"
mv "$tmp/unlabeled" "$FAKE_STATE/unlabeled"
FAKE_EROFS=1 FAKE_MOUNT_RO=1 labelrun etc || fail "read only /etc: etc exit $?"
labelrun var
result=success labelrun result
[[ $(key etc) == partial && $(key etcn) == 0 && $(key etcerr) == $(( etcn - 7 + 1 )) ]] \
  || fail "read only /etc: etc=$(key etc) etcn=$(key etcn) etcerr=$(key etcerr)"
[[ $(last) == "selinux-label fc=$hb dep=$B etc=partial var=walked" ]] || fail "read only /etc: $(last)"
[[ $(sed -n 1,2p "$txt") == "errors $(( etcn - 7 + 1 ))
$root is not mounted read write: ro,subvol=root" ]] || fail "read only /etc: selinux-label.txt $(cat "$txt")"
[[ $(grep -c '^Read only filesystem, relabel not possible: ' "$txt") == $(( etcn - 7 )) ]] \
  || fail "read only /etc: selinux-label.txt $(cat "$txt")"
reset
labelrun etc
FAKE_EROFS=1 labelrun var
result=success labelrun result
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "EROFS lines on /var: $(last)"
[[ $(kmsg) == "selinux-label: dep $B etc $etcn ok var partial in 5 s" ]] || fail "EROFS lines on /var: kmsg $(kmsg)"
[[ $(head -n 1 "$txt") == "errors $varn" && $(grep -c '^Read only filesystem, relabel not possible: ' "$txt") == "$varn" ]] \
  || fail "EROFS lines on /var: selinux-label.txt $(cat "$txt")"
unlabeled "$sr/var/home/micro/notes" || fail "EROFS lines on /var: notes counted as labeled"
reset
labelrun etc
FAKE_MOUNT_RO=1 labelrun var
result=success labelrun result
[[ $(last) == "selinux-label fc=$hb dep=$B etc=ok var=partial" ]] || fail "read only /var mount: $(last)"
[[ $(head -n 1 "$txt") == "errors 5" && $(grep -cxF "$root is not mounted read write: ro,subvol=root" "$txt") == 5 ]] \
  || fail "read only /var mount: selinux-label.txt $(cat "$txt")"

reset
ln -s /nonexistent "$tmp/selinux"
boot
[[ $ecode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=partial var=partial" ]] || fail "initrd selinux link: $(last)"
[[ $(< "$txt") == "errors 2
$tmp/selinux is not a link to $sys/etc/selinux
$tmp/selinux is not a link to $sys/etc/selinux" ]] || fail "initrd selinux link: selinux-label.txt $(cat "$txt")"
grep -qF "$tmp/selinux is not a link to $sys/etc/selinux, customizable types are relabeled" "$tmp/label.err" \
  || fail "initrd selinux link: $(cat "$tmp/label.err")"

reset
rm "$tmp/lsm"
boot
[[ $ecode == 0 && -e $envf && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" ]] || fail "unreadable LSM list: $(last)"
reset
echo "capability,landlock,lockdown,yama,loadpin,safesetid,ipe,bpf" > "$tmp/lsm"
boot
skipped "no selinux in the LSM list"
reset
echo "root=PARTLABEL=microos selinux=0 microos.deploy=$B" > "$tmp/cmdline"
boot
skipped "selinux=0"
reset
printf 'SELINUX=disabled\nSELINUXTYPE=targeted\n' > "$sr/deploy/$B/etc/selinux/config"
boot
skipped "SELINUX=disabled"
reset
printf 'SELINUX=permissive\nSELINUXTYPE=targeted\n' > "$sr/deploy/$B/etc/selinux/config"
boot
[[ $ecode == 0 && $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" ]] || fail "SELINUX=permissive: $(last)"

config() {
  local name=$1 want=$2 type=$3
  reset
  printf '%b' "$4" > "$sr/deploy/$B/etc/selinux/config"
  [[ $type == targeted ]] || cp -a "$sr/deploy/$B/etc/selinux/targeted" "$sr/deploy/$B/etc/selinux/$type"
  boot
  if [[ $want == label ]]; then
    [[ $ecode == 0 && $(key fc) == "$sys/etc/selinux/$type/contexts/files/file_contexts" && \
      $(last) == "selinux-label fc=$hb dep=$B etc=ok var=walked" ]] || fail "config $name: etc exit $ecode, fc $(key fc), $(last)"
  else
    skipped "config $name"
  fi
}
config "SELINUX=Enforcing" label targeted 'SELINUX=Enforcing\nSELINUXTYPE=targeted\n'
config "SELINUX= enforcing" label targeted 'SELINUX= enforcing\nSELINUXTYPE=targeted\n'
config "a trailing space" label targeted 'SELINUX=enforcing \nSELINUXTYPE=targeted \n'
config "PERMISSIVE with no newline" label targeted 'SELINUXTYPE=targeted\nSELINUX=PERMISSIVE'
config "the first known value" label targeted 'SELINUX=bogus\nSELINUX=permissive\nSELINUX=disabled\n'
config "SELINUX=Disabled" skip targeted 'SELINUX=Disabled\nSELINUXTYPE=targeted\n'
config "SELINUX= not in column 0" skip targeted ' SELINUX=enforcing\nSELINUXTYPE=targeted\n'
config "a commented SELINUX=" skip targeted '#SELINUX=enforcing\nSELINUXTYPE=targeted\n'
config "a padded SELINUXTYPE" label mls 'SELINUX=enforcing\n  SelinuxType=  mls \t\r\n'
config "the last SELINUXTYPE" label mls 'SELINUX=enforcing\nSELINUXTYPE=targeted\nSELINUXTYPE=mls\n'
config "a commented SELINUXTYPE" label targeted 'SELINUX=enforcing\nSELINUXTYPE=targeted\n# SELINUXTYPE=mls\n'
config "no SELINUXTYPE" label targeted 'SELINUX=enforcing\n'

if (( rc == 0 )); then
  echo "selinux-label: all cases passed"
fi
exit "$rc"
