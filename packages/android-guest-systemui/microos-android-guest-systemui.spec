%{!?systemui_stock:%{error:systemui_stock is not defined}}
%{!?build_tools:%{error:build_tools is not defined}}
%{!?platform_key:%{error:platform_key is not defined}}
%{!?smali:%{error:smali is not defined}}
%{!?sdk_api:%{error:sdk_api is not defined}}
%{!?platform_cert:%{error:platform_cert is not defined}}
%{!?framework_res:%{error:framework_res is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global sets %{_datadir}/microos-android/overlay.d
%global apk system/system_ext/priv-app/SystemUI/SystemUI.apk
%global baksmali java -Xmx4g -cp '%{smali}/*' com.android.tools.smali.baksmali.Main
%global smali_a java -Xmx4g -cp '%{smali}/*' com.android.tools.smali.smali.Main
%global signer java --enable-native-access=ALL-UNNAMED -jar %{build_tools}/lib/apksigner.jar

Name:           microos-android-guest-systemui
Version:        1
Release:        1%{?dist}.microos
Summary:        The Waydroid guest's SystemUI with the 3 button navigation bar on the right in landscape
License:        Apache-2.0
URL:            https://github.com/seilent/MicroOS
Source0:        SOURCE.env
Source1:        build.sh
Source2:        fetch.sh
Source3:        0001-navbar-right-in-landscape.patch
Source4:        navbar-check.py
Source5:        NOTICE
Source6:        systemui.manifest
Source7:        NOTICE.SystemUI
Vendor:         MicroOS
BuildArch:      noarch
AutoReqProv:    no

%description
The SystemUI of the Waydroid LineageOS 20 system image with its classes.dex
changed by 0001-navbar-right-in-landscape.patch: in 3 button navigation, on a
display that is not square, the navigation bar sits on the right edge at
rotations 0 and 180 (landscape on the Y700) with the recents key at the top and
back at the bottom, and the WM Shell display layout puts its inset on the
right. Gestural and 2 button navigation keep the stock bottom bar. The APK is
signed with the AOSP test platform key, the key of the image's platform
signature. It sits in the overlay set %{sets}/systemui/, listed in
systemui.manifest as its sha256, mode and overlay path. systemui.base names the
sha256 of the image's own APK and systemui.system the system image zip it was
made for. microos-android-overlay places the set into the Waydroid overlay
before the container starts, only on an image whose SystemUI is that APK.

%prep
%setup -q -c -T

%build
export TZ=UTC
unzip -q %{systemui_stock} classes.dex -d stock
%{baksmali} d -a %{sdk_api} -o smali-stock stock/classes.dex
cp -a smali-stock smali-patched
patch -p1 -s --fuzz=0 -d smali-patched < %{SOURCE3}
mkdir patched
%{smali_a} a -a %{sdk_api} -o patched/classes.dex smali-patched
touch -d '2009-01-01 00:00:00' patched/classes.dex
cp %{systemui_stock} SystemUI-unsigned.apk
chmod u+w SystemUI-unsigned.apk
zip -q -d SystemUI-unsigned.apk META-INF/CERT.SF META-INF/CERT.RSA META-INF/MANIFEST.MF
(cd patched && zip -q -0 -X ../SystemUI-unsigned.apk classes.dex)
%{build_tools}/zipalign -p -f 4 SystemUI-unsigned.apk SystemUI-aligned.apk
%{signer} sign --key %{platform_key}/platform.pk8 --cert %{platform_key}/platform.x509.pem \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
  --out SystemUI.apk SystemUI-aligned.apk
%{signer} verify --min-sdk-version %{sdk_api} --print-certs %{systemui_stock} > stock-certs
grep -qx 'Signer #1 certificate SHA-256 digest: %{platform_cert}' stock-certs
%{signer} verify --min-sdk-version %{sdk_api} --print-certs SystemUI.apk > certs
grep -qx 'Signer #1 certificate SHA-256 digest: %{platform_cert}' certs

%install
. %{SOURCE0}
install -Dm644 SystemUI.apk %{buildroot}%{sets}/systemui/%{apk}
install -Dpm644 %{SOURCE6} %{buildroot}%{sets}/systemui.manifest
printf '%s %s\n' "$SYSTEMUI_SHA256" "$SYSTEMUI_PATH" > %{buildroot}%{sets}/systemui.base
grep -x 'SYSTEM_SHA256=[0-9a-f]\{64\}' %{SOURCE0} > %{buildroot}%{sets}/systemui.system
install -Dpm644 -t %{buildroot}%{_licensedir}/%{name} %{SOURCE5} %{SOURCE7}

%check
export TZ=UTC
%{build_tools}/aapt2 dump resources %{framework_res} > framework-res.txt
awk '$1 == "resource" { print $2, $3 }' framework-res.txt > framework-res.names
res='0x01110191 bool/config_navBarCanMove
0x010e00b1 integer/config_navBarInteractionMode
0x010501cf dimen/navigation_bar_frame_height
0x010501d3 dimen/navigation_bar_height
0x010501d4 dimen/navigation_bar_height_car_mode
0x010501d5 dimen/navigation_bar_height_landscape
0x010501d6 dimen/navigation_bar_height_landscape_car_mode
0x010501d8 dimen/navigation_bar_width
0x010501d9 dimen/navigation_bar_width_car_mode'
used=$({ grep -o '0x01[0-9A-Fa-f]\{6\}' %{SOURCE4}
  sed -n 's/^+ *const v[0-9]*, 0x\(1[0-9a-f]\{6\}\)$/0x0\1/p' %{SOURCE3}; } | tr A-F a-f | LC_ALL=C sort -u)
test "$used" = "$(cut -d' ' -f1 <<< "$res" | LC_ALL=C sort)"
while read -r id name; do
  got=$(awk -v id="$id" '$1 == id { print $2 }' framework-res.names)
  test "$got" = "$name" || { echo "framework-res.apk: $id is ${got:-absent}, not $name"; exit 1; }
done <<< "$res"
norm() {
  find "$1" -name '*.smali' -exec sed -i -E \
    's/^(\.field [^=]*static [^=]*) = (false|null|0x0|0x0L|0x0t|0x0s|0\.0f|0\.0)$/\1/' {} +
}
counts() {
  for o in 56 64 72 80 88 96; do od -An -t u4 -j "$o" -N 4 "$1"; done | tr -d ' ' | paste -sd' '
}
mkdir roundtrip built
%{smali_a} a -a %{sdk_api} -o roundtrip/classes.dex smali-stock
%{baksmali} d -a %{sdk_api} -o smali-roundtrip roundtrip/classes.dex
unzip -q SystemUI.apk classes.dex -d built
%{baksmali} d -a %{sdk_api} -o smali-built built/classes.dex
norm smali-stock
norm smali-roundtrip
norm smali-built
diff -r smali-stock smali-roundtrip
changed=$(diff -rq smali-stock smali-built | LC_ALL=C sort || true)
want=$(for f in com/android/systemui/navigationbar/NavigationBar.smali \
  com/android/systemui/navigationbar/NavigationBarView.smali com/android/wm/shell/common/DisplayLayout.smali; do
  echo "Files smali-stock/$f and smali-built/$f differ"
done | LC_ALL=C sort)
test "$changed" = "$want"
python3 %{SOURCE4} smali-stock smali-built
read -r strings others <<< "$(counts stock/classes.dex)"
read -r built_strings built_others <<< "$(counts built/classes.dex)"
test "$built_others" = "$others"
test "$built_strings" = $((strings - 1))
test "$(grep -caF '~~R8{' stock/classes.dex)" = 1
test "$(grep -caF '~~R8{' built/classes.dex)" = 0
cmp -s patched/classes.dex built/classes.dex
mkdir stock-zip built-zip
unzip -q %{systemui_stock} -d stock-zip
unzip -q SystemUI.apk -d built-zip
rm stock-zip/META-INF/CERT.SF stock-zip/META-INF/CERT.RSA stock-zip/META-INF/MANIFEST.MF stock-zip/classes.dex
rm built-zip/classes.dex
diff -r stock-zip built-zip
unzip -Z1 %{systemui_stock} | grep -vxF -e META-INF/CERT.SF -e META-INF/CERT.RSA -e META-INF/MANIFEST.MF > stock-entries
unzip -Z1 SystemUI.apk > built-entries
diff stock-entries built-entries
%{build_tools}/zipalign -c -p 4 SystemUI.apk
read -r sum mode path < %{SOURCE6}
test "$path" = %{apk}
test "$(stat -c %04a %{buildroot}%{sets}/systemui/%{apk})" = "$mode"
test "$(find %{buildroot}%{sets} -type f | wc -l)" = 4
echo "$sum  %{buildroot}%{sets}/systemui/%{apk}" | sha256sum -c - || { sha256sum SystemUI.apk; exit 1; }

%files
%dir %{_datadir}/microos-android
%dir %{sets}
%{sets}/systemui.manifest
%{sets}/systemui.base
%{sets}/systemui.system
%{sets}/systemui/
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/NOTICE
%license %{_licensedir}/%{name}/NOTICE.SystemUI
