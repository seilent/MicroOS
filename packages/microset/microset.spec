%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}
%global debug_package %{nil}

Name:           microset
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        MicroOS settings daemon, client library and CLI
License:        GPL-2.0-or-later
URL:            https://github.com/seilent/MicroSET
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        https://github.com/microsoft/Selawik/releases/download/1.01/Selawik_Release.zip
Source2:        https://raw.githubusercontent.com/microsoft/Selawik/89362e8/LICENSE.txt
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  pkgconfig(xcb)
BuildRequires:  alsa-lib-devel
BuildRequires:  dbus-daemon
BuildRequires:  /usr/bin/setpriv
BuildRequires:  systemd-rpm-macros
BuildRequires:  unzip
BuildRequires:  xorg-x11-server-Xvfb
BuildRequires:  xorg-x11-xauth

%description
microsetd holds every MicroOS, MicroDAP and MicroEMU setting behind
net.seilent.MicroSet on the system bus. libmicroset is its Qt client and
microset the command line client.

%package devel
Summary:        Headers and CMake package for libmicroset
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       qt6-qtbase-devel

%description devel
Headers and the CMake package to build against libmicroset.

%package recovery
Summary:        MicroOS recovery screen
Requires:       qt6-qtdeclarative
Requires:       %{name}-fonts = %{version}-%{release}

%description recovery
The Qt Quick screen of the MicroOS recovery session. It shows the failing
session with its journal and switches, rolls back or powers off.

%package settings
Summary:        MicroSET settings overlay
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       %{name}-fonts = %{version}-%{release}
Requires:       qt6-qtbase-gui%{?_isa}
Requires:       qt6-qtdeclarative%{?_isa}
Requires:       xprop

%description settings
The MicroSET settings page as a gamescope overlay in the Steam, MicroDAP and
MicroEMU sessions, toggled with RC.

%package fonts
Summary:        Selawik font for the MicroSET and MicroDAP screens
License:        OFL-1.1
BuildArch:      noarch

%description fonts
Selawik 1.01, the font of the MicroSET and MicroDAP screens.

%prep
%autosetup -n MicroSET-%{commit}
cp -p %{SOURCE2} Selawik.txt
unzip -o -q -j %{SOURCE1} selawkl.ttf selawksl.ttf selawk.ttf selawksb.ttf selawkb.ttf -d fonts

%build
%cmake -DMICROSET_TEST_FONT_DIR="$PWD/fonts"
%cmake_build

%check
%ctest

%install
%cmake_install
install -d %{buildroot}%{_datadir}/fonts/microset
install -pm644 fonts/*.ttf %{buildroot}%{_datadir}/fonts/microset/

%post
%systemd_post microsetd.service

%preun
%systemd_preun microsetd.service

%postun
%systemd_postun_with_restart microsetd.service

%files
%license LICENSE
%{_libexecdir}/microsetd
%{_bindir}/microset
%{_libdir}/libmicroset.so.0
%{_libdir}/libmicroset.so.0.*
%dir %{_datadir}/microset
%dir %{_datadir}/microset/schema.d
%{_datadir}/microset/schema.d/10-microset.json
%{_unitdir}/microsetd.service
%{_datadir}/dbus-1/system.d/net.seilent.MicroSet.conf
%{_datadir}/dbus-1/interfaces/net.seilent.MicroSet1.xml
%{_sysusersdir}/microset.conf

%files devel
%{_includedir}/microset/
%{_libdir}/libmicroset.so
%{_libdir}/cmake/MicroSet/

%files recovery
%license LICENSE
%{_bindir}/microset-recovery

%files settings
%license LICENSE
%{_bindir}/microset-settings
%dir %{_libexecdir}/microset
%{_libexecdir}/microset/microset-wait-x
%{_userunitdir}/microset-overlay@.service
%dir %{_userunitdir}/gamescope-session-plus@steam.service.d
%dir %{_userunitdir}/gamescope-session-plus@microdap.service.d
%dir %{_userunitdir}/gamescope-session-plus@microemu.service.d
%{_userunitdir}/gamescope-session-plus@steam.service.d/30-microset-overlay.conf
%{_userunitdir}/gamescope-session-plus@microdap.service.d/30-microset-overlay.conf
%{_userunitdir}/gamescope-session-plus@microemu.service.d/30-microset-overlay.conf
%dir %{_prefix}/lib/microos/hotkeys.d
%dir %{_prefix}/lib/microos/hotkeys.d/steam.conf.d
%dir %{_prefix}/lib/microos/hotkeys.d/microdap.conf.d
%dir %{_prefix}/lib/microos/hotkeys.d/microemu.conf.d
%{_prefix}/lib/microos/hotkeys.d/steam.conf.d/60-microset.conf
%{_prefix}/lib/microos/hotkeys.d/microdap.conf.d/60-microset.conf
%{_prefix}/lib/microos/hotkeys.d/microemu.conf.d/60-microset.conf

%files fonts
%license Selawik.txt
%{_datadir}/fonts/microset/
