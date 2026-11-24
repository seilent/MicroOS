%global debug_package %{nil}

Name:           microos-android
Version:        1
Release:        1%{?dist}.microos
Summary:        The Android session of MicroOS
License:        GPL-2.0-or-later
URL:            https://github.com/seilent/MicroOS
Source0:        microos-android-data.tar.gz
Vendor:         MicroOS
BuildArch:      noarch
Requires:       microos-android-guestos
Requires:       waydroid
Requires:       lxc
Requires:       android-tools
Requires:       util-linux-core
Requires:       curl
Requires:       python3
Requires:       python3-gobject
Requires:       python3-gbinder
Requires:       gtk3
Requires:       xprop
Requires:       polkit

%description
The Android session of MicroOS: Waydroid in a gamescope session, its
client and stop, the guest exec path over adb, the status service, the
battery, brightness, frame generation and overlay writers, and the
Google Play install into the Waydroid overlay.

%prep
%setup -q -c -T

%install
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot} --strip-components=1

%check
for f in %{buildroot}%{_libexecdir}/microos/* %{buildroot}%{_bindir}/microos-android; do
  test "$(stat -c %a "$f")" = 755
done
test -z "$(find %{buildroot} -type f -perm /022)"

%files
%{_libexecdir}/microos/microos-android-*
%{_libexecdir}/microos/microos-fetch
%{_libexecdir}/microos/microos-gamescope-plain
%{_bindir}/microos-android
%{_userunitdir}/microos-android.service
%{_userunitdir}/microos-android-battery.service
%{_userunitdir}/microos-android-brightness.service
%{_userunitdir}/microos-android-gapps.service
%{_userunitdir}/microos-android-lsfg.service
%{_userunitdir}/microos-android-perf.service
%{_userunitdir}/microos-android-status.service
%{_unitdir}/microos-android-gapps@.service
%{_unitdir}/microos-android-gsf.service
%{_unitdir}/microos-android-layer.service
%{_unitdir}/microos-android-reset.service
%{_datadir}/polkit-1/rules.d/50-microos-android.rules
%{_datadir}/wayland-sessions/microos-android.desktop
%{_datadir}/gamescope-session-plus/sessions.d/android
%{_datadir}/microos-android/
