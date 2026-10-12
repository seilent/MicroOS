#!/usr/bin/env bash
set -euo pipefail

fail() { echo "image: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || fail "expected one modules dir, found ${mods[*]}"
kver=${mods[0]##*/}
rpm -q microos-kernel >/dev/null || fail "microos-kernel not installed"
[[ -z $(rpm -qa 'kernel*') ]] || fail "Fedora kernel rpms left: $(rpm -qa 'kernel*' | tr '\n' ' ')"
[[ -z $(rpm -qa 'fedora-release*') ]] || fail "fedora-release rpms left"
rpm -q generic-release generic-logos >/dev/null || fail "generic-release or generic-logos missing"

for kv in ID=microos NAME=MicroOS ID_LIKE=fedora VERSION_ID=44 DEFAULT_HOSTNAME=microos; do
  grep -qx "$kv" /usr/lib/os-release || fail "os-release lacks $kv"
done
grep -qx "$(cat /usr/lib/microos/version)" /usr/lib/os-release || fail "version file and os-release differ"
[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || fail "/etc/os-release is not the relative symlink"

for u in bootloader-update.service systemd-backlight@.service systemd-hibernate.service systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service bootc-fetch-apply-updates.timer; do
  [[ $(readlink "/etc/systemd/system/$u") == /dev/null ]] || fail "$u is not masked"
done

for u in microos-boot-ok.service microos-update-applied.service microos-update.service microos-update-check.service \
  microos-update-check.timer; do
  [[ -f /usr/lib/systemd/system/$u ]] || fail "$u missing"
done
units=()
for u in /usr/lib/systemd/system/microos-*; do
  [[ -f $u ]] || continue
  units+=("$u")
  if grep -q '^\[Install\]' "$u"; then
    [[ $(systemctl is-enabled "${u##*/}") == enabled ]] || fail "${u##*/} is not enabled"
  fi
done
(( ${#units[@]} )) || fail "no MicroOS units"
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no "${units[@]}" \
  /usr/lib/systemd/system/sshd.service /usr/lib/systemd/system/bootc-generic-growpart.service \
  /usr/lib/systemd/system/ostree-finalize-staged.service || fail "systemd-analyze verify"

[[ $(grep '^ExecStop=' /usr/lib/systemd/system/ostree-finalize-staged.service) == 'ExecStop=/usr/bin/ostree admin finalize-staged' ]] \
  || fail "ostree-finalize-staged.service ExecStop changed"
stops=$(systemctl cat ostree-finalize-staged.service \
  | awk '/^ExecStop=/ { sub(/^ExecStop=/, ""); if ($0 == "") n = 0; else l[++n] = $0 } END { for (i = 1; i <= n; i++) print l[i] }') \
  || fail "systemctl cat ostree-finalize-staged.service"
[[ $stops == '/usr/libexec/microos/microos-bootlog run finalize-staged -- /usr/bin/ostree admin finalize-staged'$'\n''-/usr/libexec/microos/microos-bootlog run finalize -- /usr/libexec/microos/microos-bootimg-update' ]] \
  || fail "effective ostree-finalize-staged.service ExecStop: $stops"
after=$(systemctl cat microos-boot-ok.service | sed -n 's/^After=//p' | tr ' ' '\n') || fail "systemctl cat microos-boot-ok.service"
for u in ostree-finalize-staged.service microos-bootimg-regen.service; do
  grep -qx "$u" <<< "$after" || fail "microos-boot-ok.service is not After=$u"
done

pol=/etc/containers/policy.json
keys=(/usr/share/microos/keys/microos.pub /usr/share/microos/keys/microos-backup.pub /usr/share/microos/keys/microos-next.pub)
jq -e '.default == [{"type": "reject"}]' "$pol" >/dev/null || fail "policy default is not reject"
jq -e '.transports.docker["ghcr.io/seilent/microos"] == [{"type": "sigstoreSigned", "keyPaths": $ARGS.positional,
  "signedIdentity": {"type": "matchRepository"}}]' --args "${keys[@]}" < "$pol" >/dev/null || fail "policy scope ghcr.io/seilent/microos"
for k in "${keys[@]}"; do
  openssl pkey -pubin -noout -in "$k" 2>/dev/null || fail "$k is not a public key"
done
[[ $(< /etc/containers/registries.d/ghcr-microos.yaml) == $'docker:\n  ghcr.io/seilent/microos:\n    use-sigstore-attachments: true' ]] \
  || fail "registries.d ghcr-microos.yaml"

mkdir -p "$tmp/etc/ssh"
ssh-keygen -A -f "$tmp" >/dev/null
hk=()
for k in "$tmp"/etc/ssh/ssh_host_*_key; do hk+=(-h "$k"); done
sshd -T "${hk[@]}" > "$tmp/sshd"
for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no' 'allowusers micro' \
  'authenticationmethods publickey' 'x11forwarding no' 'gssapiauthentication no'; do
  grep -qx "$kv" "$tmp/sshd" || fail "sshd -T lacks '$kv'"
done

systemd-sysusers >/dev/null 2>&1
[[ $(id -u micro):$(id -g micro) == 1000:1000 ]] || fail "micro is not 1000:1000"
groups=$(id -nG micro)
for g in wheel systemd-journal input video render audio; do
  [[ " $groups " == *" $g "* ]] || fail "micro is not in $g"
done
[[ $(getent passwd micro | cut -d: -f6,7) == /var/home/micro:/bin/bash ]] || fail "micro home or shell"
rules=$(sudo -l -U micro)
grep -q '(ALL) ALL' <<< "$rules" || fail "micro has no wheel sudo rule"
! grep -q NOPASSWD <<< "$rules" || fail "micro has a NOPASSWD rule"

img=/usr/lib/modules/$kver/initramfs.img
list=$(lsinitrd "$img")
for m in erofs overlay btrfs sdhci-msm ufs-qcom; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" "/usr/lib/modules/$kver/modules.builtin" || fail "initramfs lacks $m"
done
dropin=usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir "$dropin"; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
[[ $(lsinitrd -f "$dropin" "$img") == $'[Service]\nExecStart=\nExecStart=/usr/libexec/microos/prepare-root' ]] || fail "remap drop-in content"
lsinitrd -f usr/lib/systemd/system/ostree-prepare-root.service "$img" | grep -qx 'ExecStart=/usr/lib/ostree/ostree-prepare-root /sysroot' \
  || fail "ostree-prepare-root.service ExecStart changed"

[[ -x /usr/bin/microos-update ]] || fail "/usr/bin/microos-update missing"
scripts=(/usr/libexec/microos/* /usr/lib/microos/* /usr/lib/dracut/modules.d/91microos-ostree-remap/* /usr/bin/microos-*)
etc=$(grep -n '/etc/' "${scripts[@]}" \
  | grep -vxE '/usr/bin/microos-update:[0-9]+:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/etc/containers/policy\.json' || true)
[[ -z $etc ]] || fail "MicroOS scripts reference /etc: $etc"

chmod 711 "$tmp"
esp=$tmp/esp
mkdir -p "$esp/microos"
printf '[connection]\nid=home\ntype=wifi\n' > "$esp/microos/home.nmconnection"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA test\n' > "$esp/microos/authorized_keys"
printf 'pw:with colon\n' > "$esp/microos/password"
env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nm" MICROOS_HOME="$tmp/home" \
  /usr/libexec/microos/microos-provision >/dev/null || fail "provision failed"
[[ -z $(ls -A "$esp/microos") ]] || fail "provision left files on the ESP: $(ls -A "$esp/microos")"
[[ $(stat -c '%a %U' "$tmp/nm/home.nmconnection") == '600 root' ]] || fail "nmconnection mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh") == '700 micro' ]] || fail ".ssh mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh/authorized_keys") == '600 micro' ]] || fail "authorized_keys mode"
hash=$(getent shadow micro | cut -d: -f2)
[[ $hash == \$* ]] || fail "micro password not set"
[[ -e $tmp/run/bootimg.lock ]] || fail "provision did not take the bootimg lock"

printf '[connection]\nid=kept\n' > "$esp/microos/kept.nmconnection"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB test\n' > "$esp/microos/authorized_keys"
touch "$tmp/nmfile"
if env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nmfile/sub" MICROOS_HOME="$tmp/home" \
  /usr/libexec/microos/microos-provision >/dev/null 2>&1; then
  fail "provision passed with an unwritable connection dir"
fi
[[ -f $esp/microos/kept.nmconnection ]] || fail "failed import removed the file"
[[ ! -e $esp/microos/authorized_keys ]] || fail "authorized_keys not imported next to a failed import"

install -d -m 0755 "$tmp/victim"
for kind in symlink file; do
  rm -rf "$tmp/home2"
  install -d -m 0700 -o micro -g micro "$tmp/home2"
  if [[ $kind == symlink ]]; then
    ln -s "$tmp/victim" "$tmp/home2/.ssh"
  else
    touch "$tmp/home2/.ssh"
  fi
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC test\n' > "$esp/microos/authorized_keys"
  if env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nm" MICROOS_HOME="$tmp/home2" \
    /usr/libexec/microos/microos-provision >/dev/null 2>&1; then
    fail "provision passed with a $kind .ssh"
  fi
  [[ -f $esp/microos/authorized_keys ]] || fail "$kind .ssh: authorized_keys removed from the ESP"
done
[[ $(stat -c '%a %U %G' "$tmp/victim") == '755 root root' ]] || fail "symlinked .ssh changed its target"
[[ ! -e $tmp/victim/authorized_keys ]] || fail "symlinked .ssh: key written into the target"
rm -f "$esp/microos/authorized_keys" "$esp/microos/kept.nmconnection"

root=$tmp/initrd
mkdir -p "$root"
(cd "$root" && lsinitrd --unpack "$img")
[[ -x $root/usr/libexec/microos/prepare-root && -x $root/usr/bin/sh ]] || fail "unpacked initramfs lacks the wrapper"

s=$tmp/sysroot
a=$(printf 'a%.0s' {1..64}).0
b=$(printf 'b%.0s' {1..64}).0
ca=$(printf 'c%.0s' {1..64})
cb=$(printf 'd%.0s' {1..64})
mkdir -p "$s/ostree/deploy/default/deploy/$a" "$s/ostree/deploy/default/deploy/$b" "$s/ostree/boot.1.1/default/$ca" \
  "$s/ostree/boot.1.1/default/$cb"
ln -s boot.1.1 "$s/ostree/boot.1"
ln -s "../../../deploy/default/deploy/$a" "$s/ostree/boot.1.1/default/$ca/0"
ln -s "../../../deploy/default/deploy/$b" "$s/ostree/boot.1.1/default/$cb/1"

cat > "$tmp/prep" <<'PREP'
#!/bin/sh
printf '%s\n' "$#" "$@" > "$PREP_OUT"
PREP
chmod 755 "$tmp/prep"

remap() {
  local path=$1 cmdline=$2
  printf '%s\n' "$cmdline" > "$tmp/cmdline"
  rm -rf "$tmp/rrun" "$tmp/out"
  env -i PATH="$path" PREP_OUT="$tmp/out" MICROOS_PREPARE_ROOT="$tmp/prep" MICROOS_SYSROOT="$s" \
    MICROOS_CMDLINE="$tmp/cmdline" MICROOS_RUNDIR="$tmp/rrun" MICROOS_KMSG="$tmp/kmsg" \
    "$root/usr/bin/sh" "$root/usr/libexec/microos/prepare-root"
}
ipath=$root/usr/bin:$root/usr/sbin
base="root=UUID=x rw rootflags=subvol=root,noatime,compress=zstd:1 console=tty0"
expect_unchanged() {
  [[ $(cat "$tmp/out") == "1"$'\n'"$s" ]] || fail "$1: expected unchanged, got $(tr '\n' ' ' < "$tmp/out")"
  [[ ! -e $tmp/rrun/remapped ]] || fail "$1: remapped written"
}
expect_remap() {
  [[ $(cat "$tmp/out") == "2"$'\n'"$s"$'\n'"$2" ]] || fail "$1: got $(tr '\n' ' ' < "$tmp/out")"
  [[ $(cat "$tmp/rrun/remapped") == "$3 $4" ]] || fail "$1: remapped is $(cat "$tmp/rrun/remapped")"
}

good=/ostree/boot.1/default/$ca/0
remap "$ipath" "ostree=$good $base microos.deploy=$a"
expect_unchanged match

remap "$ipath" "ostree=$good $base"
expect_unchanged "no microos.deploy"

stale=/ostree/boot.0/default/$ca/0
remap "$ipath" "ostree=$stale $base microos.deploy=$a"
expect_remap "stale, one match" "ostree=$good $base microos.deploy=$a" "$stale" "$good"

remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
expect_remap "link names another deployment" "ostree=$good $base microos.deploy=$a" "/ostree/boot.1/default/$cb/1" "$good"

remap "$ipath" "ostree=$stale $base microos.deploy=$(printf 'e%.0s' {1..64}).0"
expect_unchanged "stale, no match"

mkdir -p "$s/ostree/boot.0.1/default/$ca"
ln -s boot.0.1 "$s/ostree/boot.0"
ln -s "../../../deploy/default/deploy/$a" "$s/ostree/boot.0.1/default/$ca/0"
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
[[ $(sed -n 1p "$tmp/out") == 2 ]] || fail "same dir via both boot.N: not remapped"
grep -qE "^ostree=/ostree/boot\.[01]/default/$ca/0 " <(sed -n 3p "$tmp/out") || fail "same dir via both boot.N: wrong link"

mkdir -p "$s/ostree/deploy/other/deploy/$a" "$s/ostree/boot.1.1/other/$ca"
ln -s "../../../deploy/other/deploy/$a" "$s/ostree/boot.1.1/other/$ca/0"
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
expect_unchanged "two different dirs"
rm -rf "$s/ostree/boot.1.1/other" "$s/ostree/deploy/other"

mkdir -p "$tmp/broken"
cp -a "$root/usr/bin/." "$tmp/broken/"
printf '#!/bin/sh\nexit 1\n' > "$tmp/broken/realpath"
chmod 755 "$tmp/broken/realpath"
remap "$tmp/broken:$root/usr/sbin" "ostree=$stale $base microos.deploy=$a"
expect_unchanged "broken realpath"
printf '#!/bin/sh\necho\n' > "$tmp/broken/realpath"
remap "$tmp/broken:$root/usr/sbin" "ostree=$stale $base microos.deploy=$a"
expect_unchanged "empty realpath"

echo "image: ok ($kver)"
