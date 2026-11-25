%{!?ndk:%{error:ndk is not defined}}
%{!?android_api:%{error:android_api is not defined}}
%{!?build_tools:%{error:build_tools is not defined}}
%{!?platform:%{error:platform is not defined}}
%{!?sdk_api:%{error:sdk_api is not defined}}
%{!?testkey:%{error:testkey is not defined}}
%{!?helper_store:%{error:helper_store is not defined}}
%{!?helper_alias:%{error:helper_alias is not defined}}
%{!?helper_cert:%{error:helper_cert is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%undefine _auto_set_build_flags
%global ndkbin %{ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin
%global overlay %{_datadir}/microos-android/overlay
%global hal android.hardware.lights-service.microos
%global vibrator android.hardware.vibrator-service.microos

Name:           microos-android-guest-apks
Version:        1
Release:        1%{?dist}.microos
Summary:        The Waydroid guest's composer, HALs, helper, overlays, volume curves and VINTF manifest as overlay files
License:        GPL-2.0-or-later AND Apache-2.0 AND MIT AND BSD-2-Clause AND BSD-3-Clause AND HPND AND HPND-sell-variant AND GPL-3.0-or-later WITH Bison-exception-2.2
URL:            https://github.com/seilent/MicroOS
Source0:        overlay.manifest
Source1:        service.c
Source2:        %{hal}.rc
Source3:        %{hal}.xml
Source4:        build.sh
Source5:        SOURCE.env
Source6:        %{name}-helper.tar.gz
Source7:        %{name}-telephony.tar.gz
Source8:        audio_policy_volumes.xml
Source9:        hwcomposer.waydroid.so
Source10:       0001-hwc-private-roundtrip-queue.patch
Source11:       hwc.env
Source12:       COPYING.wayland
Source13:       COPYING.wayland-protocols
Source14:       LICENSE.hardware-waydroid
Source15:       LICENSE.libffi
Source16:       LICENSE.libxkbcommon
Source17:       NOTICE.bionic
Source18:       NOTICE.hardware-waydroid
Source19:       NOTICE.libxkbcommon-parser
Source20:       %{name}-display.tar.gz
Source21:       vibrator.c
Source22:       %{vibrator}.rc
Source23:       %{vibrator}.xml
Source24:       manifest.xml
Source25:       0002-hwc-pen-on-touch-device.patch
Source26:       0003-hwc-vsync-presented-grid.patch
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no

%description
An AIDL ILights V1 service for the Waydroid guest that writes the backlight
level the guest sets to /data/microos/backlight, and an AIDL IVibrator V2
service that writes each vibration as its length in ms and its amplitude to
/data/microos/vibrator, each with its init service and its VINTF manifest
fragment, built with the Android NDK for API %{android_api}. The MicroOS
helper, a privileged app built with the API %{sdk_api} SDK and signed with its
own key: Internet and Bluetooth quick settings tiles with their pages, and the
guest's volume, airplane mode and power menu, linked to microos-android-bridge
on the host over binder. Static overlays of the framework, signed with the AOSP
test key: voice calls and SMS off, no prompt for an adb key the guest does not
list, and adaptive brightness on with the Y700's stock lux to brightness curve
where the guest has
ro.vendor.microos.light_sensor=1. The vendor's audio_policy_volumes.xml with
flat music stream curves. The vendor's VINTF manifest.xml without its media.omx
HAL, which the vendor image declares but does not ship. Waydroid's
hwcomposer.waydroid.so with three patches: it waits for Wayland roundtrips on a
private event queue (0001-hwc-private-roundtrip-queue.patch), sends tablet tools
to the guest as pens on the touch device and drops finger touches while a pen
is down (0002-hwc-pen-on-touch-device.patch), and reports vsync on the grid of
the last presented time (0003-hwc-vsync-presented-grid.patch). It is built in a
LineageOS 20 tree and carried as a prebuilt with the patches and the tree's pins
in hwc.env; the license texts of its parts are in %{_licensedir}/%{name}. They
sit at their Waydroid overlay paths under %{overlay}, overlay.manifest next to
it lists each with its sha256 and mode, and overlay.vendor names the sha256 of
the vendor image zip they were made for. microos-android-overlay copies them
into the Waydroid overlay before the container starts.

%prep
%setup -q -c -T
tar -xzf %{SOURCE6}
tar -xzf %{SOURCE7}
tar -xzf %{SOURCE20}

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
"$cc" -std=c17 -O2 -Wall -Wextra -Werror -o %{vibrator} %{SOURCE21} libbinder_ndk.so -llog
%{ndkbin}/llvm-strip %{vibrator}

export TZ=UTC
jar=%{platform}/android.jar
signer="java --enable-native-access=ALL-UNNAMED -jar %{build_tools}/lib/apksigner.jar"
mkdir helper-gen helper-classes helper-dex
%{build_tools}/aapt2 compile --dir helper/res -o helper-res.zip
%{build_tools}/aapt2 link --manifest helper/AndroidManifest.xml -I "$jar" --min-sdk-version %{sdk_api} \
  --target-sdk-version %{sdk_api} --java helper-gen -o helper-unsigned.apk helper-res.zip
javac -source 8 -target 8 -bootclasspath "$jar:%{build_tools}/core-lambda-stubs.jar" -Xlint:-options -encoding UTF-8 \
  -d helper-classes $(find helper/src helper-gen -name '*.java' | LC_ALL=C sort)
java -cp %{build_tools}/lib/d8.jar com.android.tools.r8.D8 --release --min-api %{sdk_api} --lib "$jar" \
  --output helper-dex $(find helper-classes -name '*.class' | LC_ALL=C sort)
touch -d @347155200 helper-dex/classes.dex
(cd helper-dex && zip -q -0 -X ../helper-unsigned.apk classes.dex)
%{build_tools}/zipalign -p -f 4 helper-unsigned.apk helper-aligned.apk
$signer sign --ks %{helper_store} --ks-type PKCS12 --ks-key-alias %{helper_alias} \
  --ks-pass env:MICROOS_HELPER_STORE_PASS --key-pass env:MICROOS_HELPER_KEY_PASS \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
  --out MicroOsHelper.apk helper-aligned.apk
$signer verify --min-sdk-version %{sdk_api} --print-certs MicroOsHelper.apk > helper-certs
grep -qx 'Signer #1 certificate SHA-256 digest: %{helper_cert}' helper-certs

for rro in telephony:Telephony display:Display; do
  d=${rro%%:*}
  %{build_tools}/aapt2 compile --dir $d/res -o $d-res.zip
  %{build_tools}/aapt2 link --manifest $d/AndroidManifest.xml -I "$jar" --min-sdk-version %{sdk_api} \
    --target-sdk-version %{sdk_api} --no-resource-deduping --no-resource-removal -o $d-unsigned.apk $d-res.zip
  %{build_tools}/zipalign -p -f 4 $d-unsigned.apk $d-aligned.apk
  $signer sign --key %{testkey}/testkey.pk8 --cert %{testkey}/testkey.x509.pem \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
    --out MicroOs${rro#*:}Overlay.apk $d-aligned.apk
  $signer verify --min-sdk-version %{sdk_api} MicroOs${rro#*:}Overlay.apk
done

%install
install -Dpm644 %{SOURCE0} %{buildroot}%{_datadir}/microos-android/overlay.manifest
install -Dm755 %{hal} %{buildroot}%{overlay}/system/bin/hw/%{hal}
install -Dpm644 %{SOURCE2} %{buildroot}%{overlay}/system/etc/init/%{hal}.rc
install -Dpm644 %{SOURCE3} %{buildroot}%{overlay}/system/etc/vintf/manifest/%{hal}.xml
install -Dm755 %{vibrator} %{buildroot}%{overlay}/system/bin/hw/%{vibrator}
install -Dpm644 %{SOURCE22} %{buildroot}%{overlay}/system/etc/init/%{vibrator}.rc
install -Dpm644 %{SOURCE23} %{buildroot}%{overlay}/system/etc/vintf/manifest/%{vibrator}.xml
install -Dm644 MicroOsHelper.apk %{buildroot}%{overlay}/system/priv-app/MicroOsHelper/MicroOsHelper.apk
for rro in Telephony Display; do
  install -Dm644 MicroOs${rro}Overlay.apk %{buildroot}%{overlay}/system/product/overlay/MicroOs$rro/MicroOs${rro}Overlay.apk
done
install -Dpm644 %{SOURCE8} %{buildroot}%{overlay}/vendor/etc/audio_policy_volumes.xml
install -Dpm644 %{SOURCE24} %{buildroot}%{overlay}/vendor/etc/vintf/manifest.xml
install -Dpm644 %{SOURCE9} %{buildroot}%{overlay}/vendor/lib64/hw/hwcomposer.waydroid.so
install -Dpm644 -t %{buildroot}%{_licensedir}/%{name} %{SOURCE12} %{SOURCE13} %{SOURCE14} %{SOURCE15} \
  %{SOURCE16} %{SOURCE17} %{SOURCE18} %{SOURCE19}
grep -x 'VENDOR_SHA256=[0-9a-f]\{64\}' %{SOURCE5} > %{buildroot}%{_datadir}/microos-android/overlay.vendor

%check
bad=0
while read -r sum mode path; do
  echo "$sum  %{buildroot}%{overlay}/$path" | sha256sum -c - || { sha256sum "%{buildroot}%{overlay}/$path"; bad=1; }
  test "$(stat -c %04a "%{buildroot}%{overlay}/$path")" = "$mode"
done < %{SOURCE0}
test "$bad" = 0
test "$(find %{buildroot}%{overlay} -type f | wc -l)" = "$(wc -l < %{SOURCE0})"

%files
%dir %{_datadir}/microos-android
%{_datadir}/microos-android/overlay.manifest
%{_datadir}/microos-android/overlay.vendor
%{overlay}/
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/COPYING.wayland
%license %{_licensedir}/%{name}/COPYING.wayland-protocols
%license %{_licensedir}/%{name}/LICENSE.hardware-waydroid
%license %{_licensedir}/%{name}/LICENSE.libffi
%license %{_licensedir}/%{name}/LICENSE.libxkbcommon
%license %{_licensedir}/%{name}/NOTICE.bionic
%license %{_licensedir}/%{name}/NOTICE.hardware-waydroid
%license %{_licensedir}/%{name}/NOTICE.libxkbcommon-parser
