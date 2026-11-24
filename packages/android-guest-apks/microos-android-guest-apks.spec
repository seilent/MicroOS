%{!?ndk:%{error:ndk is not defined}}
%{!?android_api:%{error:android_api is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%undefine _auto_set_build_flags
%global ndkbin %{ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin
%global overlay %{_datadir}/microos-android/overlay
%global hal android.hardware.lights-service.microos

Name:           microos-android-guest-apks
Version:        1
Release:        1%{?dist}.microos
Summary:        The lights HAL of the Waydroid guest, as Waydroid overlay files
License:        GPL-2.0-or-later
URL:            https://github.com/seilent/MicroOS
Source0:        overlay.manifest
Source1:        service.c
Source2:        %{hal}.rc
Source3:        %{hal}.xml
Source4:        build.sh
Source5:        SOURCE.env
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no

%description
An AIDL ILights V1 service for the Waydroid guest that writes the backlight
level the guest sets to /data/microos/backlight, its init service and its VINTF
manifest fragment, built with the Android NDK for API %{android_api}. They sit
at their Waydroid overlay paths under %{overlay}, and
overlay.manifest next to it lists each with its sha256 and mode.
microos-android-overlay copies them into the Waydroid overlay before the
container starts.

%prep
%setup -q -c -T

%build
cc=%{ndkbin}/aarch64-linux-android%{android_api}-clang
sysroot=%{ndk}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/%{android_api}
{
  %{ndkbin}/llvm-nm -D --defined-only --format=just-symbols "$sysroot/libbinder_ndk.so" | sed 's/@.*//'
  printf '%s\n' AServiceManager_addService ABinderProcess_setThreadPoolMaxThreadCount ABinderProcess_joinThreadPool
} | sed 's/.*/void &(void) {}/' > binder_ndk.c
"$cc" -shared -nostdlib -Wl,-soname,libbinder_ndk.so -o libbinder_ndk.so binder_ndk.c
"$cc" -std=c17 -O2 -Wall -Wextra -Werror -o %{hal} %{SOURCE1} libbinder_ndk.so -llog
%{ndkbin}/llvm-strip %{hal}

%install
install -Dpm644 %{SOURCE0} %{buildroot}%{_datadir}/microos-android/overlay.manifest
install -Dm755 %{hal} %{buildroot}%{overlay}/system/bin/hw/%{hal}
install -Dpm644 %{SOURCE2} %{buildroot}%{overlay}/system/etc/init/%{hal}.rc
install -Dpm644 %{SOURCE3} %{buildroot}%{overlay}/system/etc/vintf/manifest/%{hal}.xml

%check
while read -r sum mode path; do
  echo "$sum  %{buildroot}%{overlay}/$path" | sha256sum -c -
  test "$(stat -c %04a "%{buildroot}%{overlay}/$path")" = "$mode"
done < %{SOURCE0}
test "$(find %{buildroot}%{overlay} -type f | wc -l)" = "$(wc -l < %{SOURCE0})"

%files
%dir %{_datadir}/microos-android
%{_datadir}/microos-android/overlay.manifest
%{overlay}/
