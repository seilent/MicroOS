#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
dev=${MICROOS_KERNEL_DEV:-}

if [[ -n $dev ]]; then
  top=$dev/work
  rm -rf "$top"
  mkdir -p "$top"
elif [[ -n ${CCACHE_DIR:-} ]]; then
  top=/var/tmp/microos-kernel
  rm -rf "$top"
  mkdir -p "$top"
else
  top=$(mktemp -d)
fi
trap 'rm -rf "$top"' EXIT

dev_sync() {
  local g=(git -C "$tree" -c safe.directory='*' -c user.name=microos -c user.email=microos@localhost)
  local commit p n=0 want=() have=()
  if [[ ! -d $tree/.git ]]; then
    rm -rf "$tree"
    git init -q "$tree"
    "${g[@]}" fetch -q --depth 1 "$KERNEL_GIT" "refs/tags/$KERNEL_TAG"
    commit=$("${g[@]}" rev-parse 'FETCH_HEAD^{commit}')
    if [[ $commit != "$KERNEL_COMMIT" ]]; then
      echo "$KERNEL_TAG is $commit, expected $KERNEL_COMMIT" >&2
      exit 1
    fi
    "${g[@]}" checkout -q -b dev "$commit"
  fi
  [[ ! -d $tree/.git/rebase-apply ]] || "${g[@]}" am --abort
  [[ $("${g[@]}" merge-base --is-ancestor "$KERNEL_COMMIT" HEAD && echo y) == y ]] ||
    { echo "$tree is not on $KERNEL_TAG" >&2; exit 1; }
  if [[ -f $src/patches/series ]]; then
    while read -r p; do
      want+=("$(git patch-id --stable < "$src/patches/$p" | cut -d' ' -f1)")
    done < "$src/patches/series"
  fi
  while read -r commit; do
    have+=("$("${g[@]}" show "$commit" | git patch-id --stable | cut -d' ' -f1)")
  done < <("${g[@]}" rev-list --reverse "$KERNEL_COMMIT..HEAD")
  while (( n < ${#want[@]} && n < ${#have[@]} )) && [[ ${want[n]} == "${have[n]}" ]]; do
    n=$((n + 1))
  done
  if (( n < ${#have[@]} )); then
    "${g[@]}" reset -q --hard "HEAD~$(( ${#have[@]} - n ))"
  fi
  if (( n < ${#want[@]} )); then
    sed -n "$((n + 1)),\$p" "$src/patches/series" | while read -r p; do
      "${g[@]}" am -q "$src/patches/$p"
    done
  fi
  echo "build.sh: dev tree $tree, $n of ${#want[@]} patches kept, $(( ${#want[@]} - n )) applied"
}

if [[ -n $dev ]]; then
  tree=$dev/src
  obj=$dev/obj
  mkdir -p "$obj"
  dev_sync
else
  tree=$top/linux
  obj=$tree
  mkdir "$tree"
  if [[ -n ${KERNEL_URL:-} ]]; then
    tarball=$top/${KERNEL_URL##*/}
    curl -fsSL --retry 3 -o "$tarball" "$KERNEL_URL"
    echo "$KERNEL_SHA256  $tarball" | sha256sum -c -
    tar -xf "$tarball" -C "$tree" --strip-components=1
    rm "$tarball"
  else
    git init -q "$top/git"
    git -C "$top/git" fetch -q --depth 1 "$KERNEL_GIT" "refs/tags/$KERNEL_TAG"
    commit=$(git -C "$top/git" rev-parse 'FETCH_HEAD^{commit}')
    if [[ $commit != "$KERNEL_COMMIT" ]]; then
      echo "$KERNEL_TAG is $commit, expected $KERNEL_COMMIT" >&2
      exit 1
    fi
    git -C "$top/git" archive "$commit" | tar -x -C "$tree"
    rm -rf "$top/git"
  fi

  if [[ -f $src/patches/series ]]; then
    while read -r p; do
      patch -d "$tree" -p1 -F0 -N -s --no-backup-if-mismatch < "$src/patches/$p"
    done < "$src/patches/series"
  fi
fi

dtbs=(sm8650-lenovo-tb321fu sm8650-lenovo-tb321fu-csot sm8650-lenovo-tb321fu-abl)
for f in "$src"/dts/*.dts "$src"/dts/*.dtsi; do
  t=$tree/arch/arm64/boot/dts/qcom/${f##*/}
  cmp -s "$f" "$t" || cp "$f" "$t"
done

export ARCH=arm64 KBUILD_BUILD_USER=microos KBUILD_BUILD_HOST=microos
if [[ $(uname -m) != aarch64 ]]; then
  export CROSS_COMPILE=aarch64-linux-gnu-
fi
cc=${CROSS_COMPILE:-}gcc
if [[ -n ${CCACHE_DIR:-} ]] && command -v ccache >/dev/null; then
  ccache -M 5G >/dev/null
  export CCACHE_SLOPPINESS=include_file_ctime,include_file_mtime,time_macros
  cc="ccache $cc"
fi
mk=(make -C "$tree" --no-print-directory -j"$(nproc)" CC="$cc" LOCALVERSION=)

frags=("$src/tb321fu.config" "$src/microos.config")
cfg=$tree
cmk=("${mk[@]}")
if [[ -n $dev ]]; then
  frags+=("$src/dev.config")
  cfg=$top/config
  mkdir "$cfg"
  cmk+=(O="$cfg")
fi
"${cmk[@]}" -s defconfig
"$tree/scripts/kconfig/merge_config.sh" -m -O "$cfg" "$cfg/.config" "${frags[@]}" >/dev/null
"${cmk[@]}" -s olddefconfig
over=$(sed -n 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p; s/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p' "${frags[@]:2}" /dev/null)
lost=$(cat "${frags[@]}" | grep -vxF -f "$cfg/.config" | grep -vwF -f <(printf '%s\n' "$over" | sed '/^$/d') || true)
if [[ -n $lost ]]; then
  echo "config lines missing from .config:" >&2
  echo "$lost" >&2
  exit 1
fi
if [[ -n $dev ]]; then
  if ! grep -qx 'CONFIG_DEBUG_INFO_NONE=y' "$cfg/.config" || grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$cfg/.config"; then
    echo "dev .config still has debug info or BTF" >&2
    exit 1
  fi
  cmp -s "$cfg/.config" "$obj/.config" || cp "$cfg/.config" "$obj/.config"
  mk+=(O="$obj")
fi

"${mk[@]}" Image modules $(printf "qcom/%s.dtb " "${dtbs[@]}")

kversion=$("${mk[@]}" -s kernelversion)
kver=$("${mk[@]}" -s kernelrelease)
if [[ $kver != "$kversion-microos" ]]; then
  echo "kernelrelease is $kver, expected $kversion-microos" >&2
  exit 1
fi

stage=$top/stage
moddir=$stage/usr/lib/modules/$kver
"${mk[@]}" -s INSTALL_MOD_PATH="$stage/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$moddir/build" "$moddir/source"
install -Dm644 "$obj/arch/arm64/boot/Image" "$moddir/vmlinuz"
for d in "${dtbs[@]}"; do
  install -Dm644 "$obj/arch/arm64/boot/dts/qcom/$d.dtb" "$moddir/dtb/qcom/$d.dtb"
done
"$obj/scripts/dtc/dtc" -q -I dts -O dtb -o "$top/dtbo.dtb" "$src/dts/sm8650-lenovo-tb321fu-dtbo.dtso"
python3 "$src/dtbo.py" "$top/dtbo.img" "$top/dtbo.dtb"
install -Dm644 "$top/dtbo.img" "$moddir/dtb/qcom/sm8650-lenovo-tb321fu-dtbo.img"
install -Dm644 "$obj/.config" "$moddir/config"
install -Dm644 "$obj/System.map" "$moddir/System.map"
install -Dm644 "$src/LICENSE.kernel" "$stage/usr/share/licenses/microos-kernel/LICENSE.kernel"

payload=w19T0.zstdio
[[ -z $dev ]] || payload=w3T0.zstdio
rpmbuild -bb --target aarch64 \
  --define "_topdir $top/rpm" \
  --define "_binary_payload $payload" \
  --define "kversion ${kversion//-/\~}" \
  --define "kver $kver" \
  --define "kuname ${kver/-rc/\~rc}" \
  --define "stage $stage" \
  "$src/microos-kernel.spec"

find "$top/rpm/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
