%{!?wvkbd_version:%{error:wvkbd_version is not defined}}
%{!?wvkbd_commit:%{error:wvkbd_commit is not defined}}
%{!?wvkbd_layout:%{error:wvkbd_layout is not defined}}
%global debug_package %{nil}

Name:           wvkbd
Version:        %{wvkbd_version}
Release:        1%{?dist}.microos
Summary:        On screen keyboard for wlroots compositors
License:        GPL-3.0-only AND MIT AND HPND-sell-variant
URL:            https://github.com/jjsullivan5196/wvkbd
Source0:        %{url}/archive/%{wvkbd_commit}.tar.gz#/wvkbd-%{wvkbd_commit}.tar.gz
Source1:        %{url}/raw/%{wvkbd_commit}/LICENSE#/LICENSE
Source2:        %{url}/raw/%{wvkbd_commit}/COPYING#/COPYING
Source3:        %{url}/raw/%{wvkbd_commit}/COPYING_WESTON#/COPYING_WESTON
Patch0001:      0001-config-mk-keep-the-build-flags-from-the-environment.patch
Patch0002:      0002-make-objects-wait-for-the-generated-config-header.patch
Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-scanner)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  scdoc

%description
The wvkbd on screen keyboard, built with the mobintl layout as
%{_bindir}/wvkbd-%{wvkbd_layout}.

%prep
%autosetup -n wvkbd-%{wvkbd_commit} -p1

%build
%make_build LAYOUT=%{wvkbd_layout} PREFIX=%{_prefix} MANPREFIX=%{_mandir}

%check
test "$(./wvkbd-%{wvkbd_layout} -v)" = "wvkbd-%{wvkbd_version}"

%install
%make_install LAYOUT=%{wvkbd_layout} PREFIX=%{_prefix} MANPREFIX=%{_mandir}
install -d %{buildroot}%{_licensedir}/wvkbd
sed -n '/<copyright>/,/<\/copyright>/p' proto/wlr-layer-shell-unstable-v1.xml \
  > %{buildroot}%{_licensedir}/wvkbd/LICENSE.wlr-layer-shell

%files
%license LICENSE COPYING COPYING_WESTON LICENSE.wlr-layer-shell
%{_bindir}/wvkbd-%{wvkbd_layout}
%{_mandir}/man1/wvkbd.1*

%changelog
