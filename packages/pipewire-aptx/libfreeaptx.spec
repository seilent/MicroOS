%{!?commit:%{error:commit is not defined}}
%global debug_package %{nil}

Name:           libfreeaptx
Version:        0.2.2
Release:        1%{?dist}.microos
Summary:        Open source aptX and aptX HD codec library
License:        LGPL-2.1-or-later
URL:            https://github.com/regularhunter/libfreeaptx
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  make

%description
libfreeaptx encodes and decodes aptX and aptX HD, the Bluetooth A2DP codecs.
It is derived from the FFmpeg aptX codec.

%package devel
Summary:        Header and pkg-config file for libfreeaptx
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
The header and the pkg-config file to build against libfreeaptx.

%prep
%autosetup -n %{name}-%{commit}

%build
%make_build CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"

%install
%make_install PREFIX=%{_prefix} LIBDIR=%{_lib} INCDIR=include BINDIR=bin
rm -rf %{buildroot}%{_bindir}

%files
%license COPYING
%doc README
%{_libdir}/libfreeaptx.so.0
%{_libdir}/libfreeaptx.so.%{version}

%files devel
%{_includedir}/freeaptx.h
%{_libdir}/libfreeaptx.so
%{_libdir}/pkgconfig/libfreeaptx.pc
