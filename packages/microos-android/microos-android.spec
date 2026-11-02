%global debug_package %{nil}

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
Requires:       attr
Requires:       curl
Requires:       unzip
Requires:       python3
Requires:       python3-gobject
Requires:       gtk3
Requires:       rsync
Requires:       procps-ng

%description
The Android session of MicroOS: Valve's Lepton runtime in a rootless
container, the reviewed build gate and its snapshots, the pad and init
override, the keyboard installer, the sideload and the Play layer.

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
test "$(stat -c %a %{buildroot}%{_datadir}/microos-android/cmd)" = 755
test -z "$(find %{buildroot}%{_libexecdir}/microos %{buildroot}%{_bindir} -type f -perm /022)"
test -f %{buildroot}%{_datadir}/microos-android/restrictions-stub.jar

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
%{_userunitdir}/microos-android.service
%{_userunitdir}/microos-android-gapps-setup.service
%{_userunitdir}/microos-android-pad.service
%{_userunitdir}/microos-android-status.service
%{_userunitdir}/microos-lepton-prepare.service
%{_userunitdir}/gamescope-session-plus@android.service.d/20-microos-android-pad.conf
%{_prefix}/lib/microos/sessions.d/android.conf
%{_datadir}/wayland-sessions/microos-android.desktop
%{_datadir}/gamescope-session-plus/sessions.d/android
%{_datadir}/microos-android/
%dir %{_datadir}/microos-lepton
%dir %{_datadir}/microos-lepton/reviewed
%{_datadir}/microos-lepton/reviewed/25772114
%dir %{_datadir}/microos-lepton/steam-empty
