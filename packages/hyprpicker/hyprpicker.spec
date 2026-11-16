%{!?hyprpicker_version:%{error:hyprpicker_version is not defined}}
%{!?hyprpicker_commit:%{error:hyprpicker_commit is not defined}}
%global debug_package %{nil}

Name:           hyprpicker
Version:        %{hyprpicker_version}
Release:        1%{?dist}.microos
Summary:        Color picker for Hyprland
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/hyprpicker
Source0:        %{url}/archive/%{hyprpicker_commit}.tar.gz#/hyprpicker-%{hyprpicker_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  hyprwayland-scanner-devel
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(libjpeg)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(xkbcommon)

%description
hyprpicker picks a colour off a wlroots or Hyprland screen and prints it in
hex, RGB, HSL, HSV or CMYK.

%prep
%autosetup -n hyprpicker-%{hyprpicker_commit}
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
v=$(%{_vpath_builddir}/hyprpicker --version)
printf '%s\n' "$v"
grep -qF "%{version}" <<<"$v"

%install
%cmake_install
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/hyprpicker/LICENSE
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/hyprpicker/LICENSE
%{_bindir}/hyprpicker
%{_mandir}/man1/hyprpicker.1*

%changelog
