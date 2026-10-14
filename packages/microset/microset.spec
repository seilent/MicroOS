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
License:        GPL-2.0-or-later AND OFL-1.1
Requires:       qt6-qtdeclarative

%description recovery
The Qt Quick screen of the MicroOS recovery session. It shows the failing
session with its journal and switches, rolls back or powers off.

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
%license LICENSE Selawik.txt
%{_bindir}/microset-recovery
%{_datadir}/fonts/microset/
