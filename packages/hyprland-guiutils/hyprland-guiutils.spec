%{!?guiutils_version:%{error:guiutils_version is not defined}}
%{!?guiutils_commit:%{error:guiutils_commit is not defined}}
%global debug_package %{nil}

Name:           hyprland-guiutils
Version:        %{guiutils_version}
Release:        1%{?dist}.microos
Summary:        Dialogs and helper apps for Hyprland
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/hyprland-guiutils
Source0:        %{url}/archive/%{guiutils_commit}.tar.gz#/hyprland-guiutils-%{guiutils_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  pkgconfig(hyprlang)
BuildRequires:  pkgconfig(hyprtoolkit)
BuildRequires:  pkgconfig(hyprutils)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(xkbcommon)

%description
hyprland-dialog, hyprland-welcome, hyprland-update-screen,
hyprland-donate-screen and hyprland-run, the apps Hyprland opens for its
dialogs.

%prep
%autosetup -n hyprland-guiutils-%{guiutils_commit}
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
for u in dialog run update-screen welcome; do
  v=$(%{_vpath_builddir}/utils/$u/hyprland-$u --help)
  printf '%s\n' "$v"
  grep -qF "hyprland-$u, part of hyprland-guiutils v%{version}" <<<"$v"
done

%install
%cmake_install
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/hyprland-guiutils/LICENSE
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/hyprland-guiutils/LICENSE
%{_bindir}/hyprland-dialog
%{_bindir}/hyprland-donate-screen
%{_bindir}/hyprland-run
%{_bindir}/hyprland-update-screen
%{_bindir}/hyprland-welcome

%changelog
