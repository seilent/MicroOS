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

Patch:          0001-hexagonfs-add-create-write-truncate-unlink-and-renam.patch
Patch:          0002-apps_std-serve-fopen-fwrite-fsync-fremove-ftrunc-and.patch
Patch:          0003-listener-answer-unsupported-requests-and-fetch-input.patch
Patch:          0004-rpcd_builder-map-the-registry-s-parent-directory-whe.patch
Patch:          0005-hexagonrpcd-fix-descriptor-lifetimes-and-the-write-p.patch
Patch:          0006-hexagonrpcd-iobuffer-decode-zero-length-input-buffer.patch
Patch:          0007-hexagonfs-refuse-.-above-an-assigned-search-director.patch
Patch:          0008-hexagonrpcd-apps_std-keep-the-root-and-search-direct.patch
Patch:          0009-hexagonrpcd-listener-match-buffer-counts-to-the-meth.patch
Patch:          0010-hexagonfs-mapped-report-the-write-bit-only-when-the-.patch
Patch:          0011-hexagonrpcd-sync-written-files-and-create-them-witho.patch
Patch:          0012-hexagonrpcd-apps_std-fflush-writes-no-output-buffer.patch

Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  meson >= 1.1
BuildRequires:  ninja-build

%description
libhexagonrpc calls remote methods on a Qualcomm Hexagon DSP over FastRPC.
hexagonrpcd serves the files a DSP asks for from a local root.

%prep
%autosetup -p1 -n %{name}-%{commit}
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
