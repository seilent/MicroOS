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
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  alsa-lib-devel
BuildRequires:  dbus-daemon
BuildRequires:  /usr/bin/setpriv
BuildRequires:  systemd-rpm-macros

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

%prep
%autosetup -n MicroSET-%{commit}

%build
%cmake
%cmake_build

%check
%ctest

%install
%cmake_install

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
