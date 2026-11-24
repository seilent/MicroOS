%global debug_package %{nil}
%global __requires_exclude ^/system/bin/sh$

Name:           microos-android
Version:        1
Release:        1%{?dist}.microos
Summary:        The Android session of MicroOS
License:        GPL-2.0-or-later
URL:            https://github.com/seilent/MicroOS
Source0:        microos-android-data.tar.gz
Source1:        microos-android-stub.tar.gz
Source2:        microos-android-assets.tar.gz
Source3:        stub.sh
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  java-25-openjdk-devel
BuildRequires:  curl
Requires:       microos-android-guestos
Requires:       podman
Requires:       passt
Requires:       catatonit
Requires:       android-tools
Requires:       which
Requires:       attr
Requires:       btrfs-progs
Requires:       curl
Requires:       unzip
Requires:       python3
Requires:       python3-gobject
Requires:       python3-gbinder
Requires:       gtk3
Requires:       rsync
Requires:       procps-ng
Requires:       inotify-tools
Requires:       xprop

%description
The Android session of MicroOS: Valve's Lepton runtime in a rootless
container, the reviewed build gate and its snapshots, the gamepad binds,
the init override, the keyboard installer, the sideload and the Play layer.

%prep
%setup -q -c -T

%install
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot} --strip-components=1
tar -xzf %{SOURCE2} -C %{buildroot}
install -d %{buildroot}%{_datadir}/microos-lepton/steam-empty

%check
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-liblepton.sh)" = 644
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-lepton-lib.sh)" = 644
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-lepton)" = 755
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-android-session-watch)" = 755
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-android-lsfg)" = 755
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-android-perf)" = 755
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-android-battery)" = 755
test "$(stat -c %a %{buildroot}%{_libexecdir}/microos/microos-android-brightness)" = 755
test "$(stat -c %a %{buildroot}%{_datadir}/microos-android/cmd)" = 755
test "$(stat -c %a %{buildroot}%{_bindir}/steamvr)" = 755
test "$(readlink %{buildroot}%{_prefix}/lib/android-sdk/platform-tools/adb)" = ../../../bin/adb
test -z "$(find %{buildroot}%{_libexecdir}/microos %{buildroot}%{_bindir} -type f -perm /022)"
test -f %{buildroot}%{_datadir}/microos-android/restrictions-stub.jar
test -f %{buildroot}%{_datadir}/microos-android/restrictions-stub.rc

%files
%{_libexecdir}/microos/microos-android-*
%{_libexecdir}/microos/microos-fetch
%{_libexecdir}/microos/microos-gamescope-plain
%{_libexecdir}/microos/microos-lepton
%{_libexecdir}/microos/microos-lepton-lib.sh
%{_libexecdir}/microos/microos-lepton-prepare
%{_libexecdir}/microos/microos-lepton-steam
%{_libexecdir}/microos/microos-liblepton.sh
%{_bindir}/microos-android
%{_bindir}/steamvr
%{_prefix}/lib/android-sdk/
%{_userunitdir}/microos-android.service
%{_userunitdir}/microos-android-battery.service
%{_userunitdir}/microos-android-brightness.service
%{_userunitdir}/microos-android-gapps.service
%{_userunitdir}/microos-android-gapps-setup.service
%{_userunitdir}/microos-android-status.service
%{_userunitdir}/microos-lepton-prepare.service
%{_datadir}/wayland-sessions/microos-android.desktop
%{_datadir}/gamescope-session-plus/sessions.d/android
%{_datadir}/microos-android/
%dir %{_datadir}/microos-lepton
%dir %{_datadir}/microos-lepton/reviewed
%{_datadir}/microos-lepton/reviewed/25772114
%dir %{_datadir}/microos-lepton/steam-empty
