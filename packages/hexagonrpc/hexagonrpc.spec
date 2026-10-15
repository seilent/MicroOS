%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}
%global debug_package %{nil}

Name:           hexagonrpc
Version:        0.5.0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        FastRPC library and reverse tunnel for Qualcomm Hexagon DSPs
License:        GPL-3.0-or-later AND BSD-3-Clause
URL:            https://github.com/linux-msm/hexagonrpc
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  meson >= 1.1
BuildRequires:  ninja-build

%description
libhexagonrpc calls remote methods on a Qualcomm Hexagon DSP over FastRPC.
hexagonrpcd serves the files a DSP asks for from a local root.

%prep
%autosetup -n %{name}-%{commit}
sed -n '/Copyright (c) 2019/,/POSSIBILITY OF SUCH DAMAGE/{s/^ \* \{0,1\}//;s/^ \*$//;p}' libhexagonrpc/error.c > LICENSE.BSD-3-Clause

%build
%meson
%meson_build

%check
%meson_test

%install
%meson_install
rm -rf %{buildroot}%{_libdir}/systemd
rm %{buildroot}%{_libdir}/libhexagonrpc.so

%files
%license COPYING LICENSE.BSD-3-Clause
%doc README.md
%{_bindir}/hexagonrpcd
%{_libdir}/libhexagonrpc.so.0.5
%dir %{_libexecdir}/hexagonrpc
%{_libexecdir}/hexagonrpc/chrecd
%{_mandir}/man1/hexagonrpcd.1*
