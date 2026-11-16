%{!?xdph_version:%{error:xdph_version is not defined}}
%{!?xdph_commit:%{error:xdph_commit is not defined}}
%global debug_package %{nil}

Name:           xdg-desktop-portal-hyprland
Version:        %{xdph_version}
Release:        1%{?dist}.microos
Summary:        XDG desktop portal backend for Hyprland
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/xdg-desktop-portal-hyprland
Source0:        %{url}/archive/%{xdph_commit}.tar.gz#/xdg-desktop-portal-hyprland-%{xdph_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  hyprwayland-scanner-devel
BuildRequires:  qt6-qtbase-devel
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(libpipewire-0.3)
BuildRequires:  pkgconfig(libspa-0.2)
BuildRequires:  pkgconfig(sdbus-c++)
BuildRequires:  pkgconfig(uuid)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)
Requires:       qt6-qtwayland%{?_isa}

%description
The xdg-desktop-portal backend for Hyprland, serving the ScreenCast, Screenshot
and Global Shortcuts portals, with hyprland-share-picker for source selection.

%prep
%autosetup -n xdg-desktop-portal-hyprland-%{xdph_commit}
grep -qx "%{version}" VERSION

%build
march=
%ifarch aarch64
march=${MICROOS_MARCH:-}
%endif
export CFLAGS="%{optflags} $march -ffile-prefix-map=%{_builddir}=/build"
export CXXFLAGS="$CFLAGS"
%cmake
%cmake_build

%check
v=$(%{_vpath_builddir}/xdg-desktop-portal-hyprland --version)
printf '%s\n' "$v"
grep -qF "%{version}" <<<"$v"

%install
%cmake_install
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/xdg-desktop-portal-hyprland/LICENSE
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/xdg-desktop-portal-hyprland/LICENSE
%{_libexecdir}/xdg-desktop-portal-hyprland
%{_bindir}/hyprland-share-picker
%{_datadir}/xdg-desktop-portal/portals/hyprland.portal
%{_datadir}/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service
%{_userunitdir}/xdg-desktop-portal-hyprland.service

%changelog
