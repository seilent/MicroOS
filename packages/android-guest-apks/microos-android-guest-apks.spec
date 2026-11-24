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

Name:           microos-android-guest-apks
Version:        1
Release:        1%{?dist}.microos
Summary:        The Waydroid guest's lights HAL, MicroOS helper, telephony overlay and volume curves, as overlay files
License:        GPL-2.0-or-later AND Apache-2.0
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
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no

%description
An AIDL ILights V1 service for the Waydroid guest that writes the backlight
level the guest sets to /data/microos/backlight, its init service and its VINTF
manifest fragment, built with the Android NDK for API %{android_api}. The
MicroOS helper, a privileged app built with the API %{sdk_api} SDK and signed
with its own key: Internet and Bluetooth quick settings tiles with their pages,
and the guest's volume, airplane mode and power menu, linked to
microos-android-bridge on the host over binder. A static overlay of the
framework with voice calls and SMS off, signed with the AOSP test key. The
vendor's audio_policy_volumes.xml with flat music stream curves. They sit at
their Waydroid overlay paths under %{overlay}, overlay.manifest next to it lists
each with its sha256 and mode, and overlay.vendor names the sha256 of the vendor
image zip they were made for. microos-android-overlay copies them into the
Waydroid overlay before the container starts.

%prep
%setup -q -c -T
tar -xzf %{SOURCE6}
tar -xzf %{SOURCE7}

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

%{build_tools}/aapt2 compile --dir telephony/res -o telephony-res.zip
%{build_tools}/aapt2 link --manifest telephony/AndroidManifest.xml -I "$jar" --min-sdk-version %{sdk_api} \
  --target-sdk-version %{sdk_api} --no-resource-deduping --no-resource-removal -o telephony-unsigned.apk \
  telephony-res.zip
%{build_tools}/zipalign -p -f 4 telephony-unsigned.apk telephony-aligned.apk
$signer sign --key %{testkey}/testkey.pk8 --cert %{testkey}/testkey.x509.pem \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
  --out MicroOsTelephonyOverlay.apk telephony-aligned.apk
$signer verify --min-sdk-version %{sdk_api} MicroOsTelephonyOverlay.apk

%install
install -Dpm644 %{SOURCE0} %{buildroot}%{_datadir}/microos-android/overlay.manifest
install -Dm755 %{hal} %{buildroot}%{overlay}/system/bin/hw/%{hal}
install -Dpm644 %{SOURCE2} %{buildroot}%{overlay}/system/etc/init/%{hal}.rc
install -Dpm644 %{SOURCE3} %{buildroot}%{overlay}/system/etc/vintf/manifest/%{hal}.xml
install -Dm644 MicroOsHelper.apk %{buildroot}%{overlay}/system/priv-app/MicroOsHelper/MicroOsHelper.apk
install -Dm644 MicroOsTelephonyOverlay.apk \
  %{buildroot}%{overlay}/system/product/overlay/MicroOsTelephony/MicroOsTelephonyOverlay.apk
install -Dpm644 %{SOURCE8} %{buildroot}%{overlay}/vendor/etc/audio_policy_volumes.xml
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
