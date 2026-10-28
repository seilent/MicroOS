%{!?ndk:%{error:ndk is not defined}}
%{!?android_api:%{error:android_api is not defined}}
%{!?libdrm_version:%{error:libdrm_version is not defined}}
%{!?fossilize_ref:%{error:fossilize_ref is not defined}}
%{!?rapidjson_ref:%{error:rapidjson_ref is not defined}}
%{!?angle_ref:%{error:angle_ref is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%undefine _auto_set_build_flags
%global guestos %{_datadir}/guestos/android
%global ndkbin %{ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin
%global spdx (Apache-2.0 OR MIT) AND (CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception) AND Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND GPL-2.0-only WITH Linux-syscall-note AND GPL-3.0-or-later WITH Bison-exception-2.2 AND HPND-sell-variant AND LicenseRef-NDK-sysroot AND MIT AND SGI-B-2.0

Name:           microos-android-guestos
Version:        26.2.5
Release:        1%{?dist}.microos
Summary:        Mesa and the Fossilize layer for Lepton's Android guests
License:        %{spdx}
URL:            https://github.com/seilent/MicroOS
Source0:        https://archive.mesa3d.org/mesa-%{version}.tar.xz
Source1:        https://github.com/ValveSoftware/Fossilize/archive/%{fossilize_ref}/Fossilize-%{fossilize_ref}.tar.gz
Source2:        https://github.com/Tencent/rapidjson/archive/%{rapidjson_ref}/rapidjson-%{rapidjson_ref}.tar.gz
Source3:        https://dri.freedesktop.org/libdrm/libdrm-%{libdrm_version}.tar.xz
Source4:        microos-noubwc.rc
Source5:        build.sh
Source6:        licenses.py
Source7:        SOURCE.env
Source8:        https://raw.githubusercontent.com/google/angle/%{angle_ref}/LICENSE#/angle-%{angle_ref}-LICENSE
Source9:        fetch.sh
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no
BuildRequires:  bison
BuildRequires:  cmake
BuildRequires:  flex
BuildRequires:  glslang
BuildRequires:  meson >= 1.4
BuildRequires:  ninja-build
BuildRequires:  patchelf
BuildRequires:  python3
BuildRequires:  python3-mako
BuildRequires:  python3-packaging
BuildRequires:  python3-pyyaml

%description
Turnip, the Mesa EGL and GLES libraries with zink, and the Fossilize Vulkan
layer, built with the Android NDK for the Android %{android_api} guests of Steam's
Lepton, which binds every file under %{guestos} into the guest.

%prep
%setup -q -c -n %{name}-%{version} -a 1 -a 2
mkdir -p mesa-%{version}/subprojects/packagecache
cp %{SOURCE3} mesa-%{version}/subprojects/packagecache/

%build
jobs=$(nproc)
if read -r quota period < /sys/fs/cgroup/cpu.max && [[ $quota != max ]]; then
  jobs=$(( quota / period ))
fi
(( jobs >= 1 )) || jobs=1
cat > android-aarch64.ini <<EOF
[binaries]
c = [%{?ccache:'ccache', }'%{ndkbin}/aarch64-linux-android%{android_api}-clang']
cpp = [%{?ccache:'ccache', }'%{ndkbin}/aarch64-linux-android%{android_api}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
ar = '%{ndkbin}/llvm-ar'
strip = '%{ndkbin}/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF
meson setup build-mesa mesa-%{version} \
  --cross-file android-aarch64.ini \
  --wrap-mode=nodownload \
  --buildtype=release \
  -Dplatforms=android \
  -Dplatform-sdk-version=%{android_api} \
  -Dandroid-stub=true \
  -Dandroid-libbacktrace=disabled \
  -Dallow-fallback-for=libdrm \
  -Dlibdrm:default_library=static \
  -Dvulkan-drivers=freedreno \
  -Dfreedreno-kmds=msm \
  -Dgallium-drivers=zink \
  -Degl=enabled \
  -Dgles1=enabled \
  -Dgles2=enabled \
  -Dgbm=disabled \
  -Degl-lib-suffix=_mesa \
  -Dgles-lib-suffix=_mesa \
  -Dllvm=disabled \
  -Dexpat=disabled \
  -Dvideo-codecs=
ninja -C build-mesa -j "$jobs"

cmake -S Fossilize-%{fossilize_ref} -B build-fossilize -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=%{ndk}/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-%{android_api} \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  %{?ccache:-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache} \
  -DFOSSILIZE_CLI=OFF \
  -DFOSSILIZE_TESTS=OFF \
  -DFOSSILIZE_VULKAN_LAYER=ON \
  -DFOSSILIZE_RAPIDJSON_INCLUDE_PATH="$PWD/rapidjson-%{rapidjson_ref}/include"
ninja -C build-fossilize -j "$jobs" VkLayer_fossilize

%install
vendor=%{buildroot}%{guestos}/vendor
install -Dm644 build-mesa/src/freedreno/vulkan/libvulkan_freedreno.so "$vendor/lib64/hw/vulkan.freedreno.so"
install -Dm644 -t "$vendor/lib64/egl" \
  build-mesa/src/egl/libEGL_mesa.so \
  build-mesa/src/mesa/glapi/es1api/libGLESv1_CM_mesa.so \
  build-mesa/src/mesa/glapi/es2api/libGLESv2_mesa.so
install -Dm644 -t "$vendor/lib64" build-mesa/src/gallium/targets/dri/libgallium_dri.so
install -Dm644 -t "$vendor/vulkan_layers" build-fossilize/layer/libVkLayer_fossilize.so
for lib in "$vendor"/lib64/hw/*.so "$vendor"/lib64/egl/*.so "$vendor"/lib64/*.so "$vendor"/vulkan_layers/*.so; do
  %{ndkbin}/llvm-strip --strip-unneeded "$lib"
  patchelf --remove-rpath "$lib"
done
patchelf --set-soname vulkan.freedreno.so "$vendor/lib64/hw/vulkan.freedreno.so"
install -Dm644 %{SOURCE4} "$vendor/etc/init/microos-noubwc.rc"
install -d %{buildroot}%{_datadir}/vulkan/guestos-android
sed 's|@FOSSILIZE_LAYER_PATH@|%{guestos}/vendor/vulkan_layers/libVkLayer_fossilize.so|' \
  Fossilize-%{fossilize_ref}/layer/VkLayer_fossilize.json.in \
  > %{buildroot}%{_datadir}/vulkan/guestos-android/VkLayer_fossilize.json
tag=$(python3 %{SOURCE6} \
  --ndk %{ndk} \
  --clangxx %{ndkbin}/aarch64-linux-android%{android_api}-clang++ \
  --out %{buildroot}%{_licensedir}/%{name} \
  --license mesa-%{version}/include/EGL/eglext_angle.h=%{SOURCE8} \
  build-mesa/src/freedreno/vulkan/libvulkan_freedreno.so \
  build-mesa/src/egl/libEGL_mesa.so \
  build-mesa/src/mesa/glapi/es1api/libGLESv1_CM_mesa.so \
  build-mesa/src/mesa/glapi/es2api/libGLESv2_mesa.so \
  build-mesa/src/gallium/targets/dri/libgallium_dri.so \
  build-fossilize/layer/libVkLayer_fossilize.so)
if [[ $tag != "%{spdx}" ]]; then
  echo "License of the compiled sources: $tag" >&2
  exit 1
fi

%files
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/SOURCES.tsv
%license %{_licensedir}/%{name}/LICENSES
%dir %{_datadir}/guestos
%{guestos}
%dir %{_datadir}/vulkan/guestos-android
%{_datadir}/vulkan/guestos-android/VkLayer_fossilize.json
