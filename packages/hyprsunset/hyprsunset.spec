%{!?hyprsunset_version:%{error:hyprsunset_version is not defined}}
%{!?hyprsunset_commit:%{error:hyprsunset_commit is not defined}}
%global debug_package %{nil}

Name:           hyprsunset
Version:        %{hyprsunset_version}
Release:        1%{?dist}.microos
Summary:        Blue light filter for Hyprland
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/hyprsunset
Source0:        %{url}/archive/%{hyprsunset_commit}.tar.gz#/hyprsunset-%{hyprsunset_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  hyprwayland-scanner-devel
BuildRequires:  systemd-devel
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)

%description
hyprsunset sets a colour temperature on Hyprland outputs for a night light,
driven over the hyprland-ctm-control protocol.

%prep
%autosetup -n hyprsunset-%{hyprsunset_commit}
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
v=$(%{_vpath_builddir}/hyprsunset --version)
printf '%s\n' "$v"
grep -qF "%{version}" <<<"$v"

%install
%cmake_install
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/hyprsunset/LICENSE
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/hyprsunset/LICENSE
%{_bindir}/hyprsunset
%{_userunitdir}/hyprsunset.service

%changelog
