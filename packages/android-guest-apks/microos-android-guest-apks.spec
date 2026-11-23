%global debug_package %{nil}
%global guestos %{_datadir}/guestos/android

Name:           microos-android-guest-apks
Version:        11.0.0_r46
Release:        2%{?dist}.microos
Summary:        Navigation bar overlays and a LineageParts catalog for Lepton's Android guests
License:        Apache-2.0 AND GPL-2.0-or-later
URL:            https://github.com/seilent/MicroOS
Source0:        microos-android-guest-apks-built.tar.gz
Source1:        microos-android-guest-apks-overlays.tar.gz
Source2:        microos-android-guest-apks-lineageparts.tar.gz
Source3:        NOTICE
Source4:        build.sh
Source5:        fetch.sh
Source6:        SOURCE.env
Source7:        microos-android-guest-apks-nohint.tar.gz
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  unzip

%description
The gestural and 3 button navigation bar mode overlays of AOSP frameworks/base
android-%{version} in %{guestos}/system/product/overlay, the gestural one with
the 0 size navigation bar of Lineage's navigation hint switch, a SystemUI
overlay there whose gesture layout has no handle, and an
org.lineageos.lineageparts package with no code that holds only a parts catalog
of the keys Lineage Settings names, in %{guestos}/system/product/app. All are
signed with the AOSP test key. Steam's Lepton binds every file under %{guestos}
into its Android guests.

%prep
%setup -q -c -T

%install
install -d %{buildroot}%{guestos}
tar -xzf %{SOURCE0} -C %{buildroot}%{guestos}
install -Dpm644 %{SOURCE3} %{buildroot}%{_licensedir}/%{name}/NOTICE

%check
product=%{buildroot}%{guestos}/system/product
for apk in overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk \
  overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk \
  overlay/NavigationBarNoHintSystemUI/NavigationBarNoHintSystemUIOverlay.apk; do
  test "$(stat -c %a "$product/$apk")" = 644
  test "$(unzip -Z1 "$product/$apk" | sort | paste -sd' ')" = 'AndroidManifest.xml resources.arsc'
done
stub=$product/app/LineagePartsStub/LineagePartsStub.apk
test "$(stat -c %a "$stub")" = 644
test "$(unzip -Z1 "$stub" | sort | paste -sd' ')" = 'AndroidManifest.xml res/xml/parts_catalog.xml resources.arsc'
test "$(find %{buildroot}%{guestos} -type f | wc -l)" = 4

%files
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/NOTICE
%dir %{_datadir}/guestos
%dir %{guestos}
%dir %{guestos}/system
%dir %{guestos}/system/product
%{guestos}/system/product/overlay/
%{guestos}/system/product/app/
