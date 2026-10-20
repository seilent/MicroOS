%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}
%global debug_package %{nil}

Name:           microdap
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        MicroDAP music player session
License:        GPL-3.0-or-later
URL:            https://github.com/seilent/MicroDAP
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  pkgconfig(gstreamer-1.0)
BuildRequires:  pkgconfig(gstreamer-controller-1.0)
BuildRequires:  pkgconfig(taglib)
BuildRequires:  pkgconfig(xcb)
BuildRequires:  pkgconfig(libpulse)
BuildRequires:  pkgconfig(libpulse-mainloop-glib)
BuildRequires:  pkgconfig(alsa)
BuildRequires:  microset-devel
BuildRequires:  microset-fonts
BuildRequires:  gstreamer1-plugins-base
BuildRequires:  gstreamer1-plugins-good
BuildRequires:  gstreamer1-plugin-libav
BuildRequires:  dbus-daemon
BuildRequires:  dbus-tools
BuildRequires:  fontconfig
BuildRequires:  python3-dbus
BuildRequires:  python3-gobject
BuildRequires:  systemd-rpm-macros
Requires:       microset%{?_isa}
Requires:       microset-fonts
Requires:       qt6-qtbase%{?_isa}
Requires:       qt6-qtbase-gui%{?_isa}
Requires:       qt6-qtdeclarative%{?_isa} = %{_qt6_version}
Requires:       gstreamer1%{?_isa}
Requires:       gstreamer1-plugins-base%{?_isa}
Requires:       gstreamer1-plugins-good%{?_isa}
Requires:       gstreamer1-plugin-libav%{?_isa}
Requires:       taglib%{?_isa}
Requires:       pulseaudio-libs%{?_isa}
Requires:       pulseaudio-libs-glib2%{?_isa}
Requires:       alsa-lib%{?_isa}
Requires:       libxcb%{?_isa}
Requires:       python3-dbus
Requires:       python3-gobject
Requires:       NetworkManager
Requires:       gamescope-session

%description
MicroDAP, the music player session of MicroOS, with its overlay in the Steam
session, its hotkey tables, session entry and MicroSET schema.

%prep
%autosetup -n MicroDAP-%{commit}

%build
%cmake -DMICRODAP_TEST_FONT_DIR=%{_datadir}/fonts/microset
%cmake_build

%check
%ctest -E '^scale(-queue)?$'
%ctest --parallel 1 -R '^scale(-queue)?$'

%install
%cmake_install

%post
%systemd_post microdap-radio.service microdap-usb-audio.service
%systemd_user_post microdap-overlay.service microdap-bt.service

%preun
%systemd_preun microdap-radio.service microdap-usb-audio.service
%systemd_user_preun microdap-overlay.service microdap-bt.service

%files
%license LICENSE CREDITS
%{_bindir}/microdap-player
%dir %{_libexecdir}/microdap
%{_libexecdir}/microdap/microdap-bt
%{_libexecdir}/microdap/microdap-fiio
%{_libexecdir}/microdap/microdap-keep
%{_libexecdir}/microdap/microdap-radio
%{_libexecdir}/microdap/microdap-stopped
%{_libexecdir}/microdap/microdap-usb-audio
%{_libexecdir}/microdap/microdap-wait-x
%{_datadir}/dbus-1/interfaces/net.seilent.MicroDap.Player.xml
%{_datadir}/dbus-1/interfaces/org.mpris.MediaPlayer2.xml
%{_datadir}/dbus-1/interfaces/org.mpris.MediaPlayer2.Player.xml
%{_datadir}/microset/schema.d/50-microdap.json
%{_datadir}/wayland-sessions/microdap.desktop
%{_datadir}/gamescope-session-plus/sessions.d/microdap
%{_prefix}/lib/microos/sessions.d/microdap.conf
%{_prefix}/lib/microos/hotkeys.d/microdap.conf
%dir %{_prefix}/lib/microos/hotkeys.d/steam.conf.d
%{_prefix}/lib/microos/hotkeys.d/steam.conf.d/50-microdap.conf
%dir %{_prefix}/lib/microos/hotkeys.d/microemu.conf.d
%{_prefix}/lib/microos/hotkeys.d/microemu.conf.d/50-microdap.conf
%dir %{_userunitdir}/gamescope-session-plus@microdap.service.d
%{_userunitdir}/gamescope-session-plus@microdap.service.d/05-microdap-fiio.conf
%{_userunitdir}/gamescope-session-plus@microdap.service.d/50-microdap.conf
%{_userunitdir}/gamescope-session-plus@steam.service.d/40-microdap-fiio.conf
%{_userunitdir}/microdap-overlay.service
%{_userunitdir}/microdap-bt.service
%{_userunitdir}/microdap-fiio-reset.service
%{_userpresetdir}/70-microdap.preset
%{_unitdir}/microdap-radio.service
%{_unitdir}/microdap-usb-audio.service
%{_presetdir}/70-microdap.preset
%{_udevrulesdir}/70-microdap-usb-audio.rules
