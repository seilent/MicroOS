%{!?hyprgrass_version:%{error:hyprgrass_version is not defined}}
%{!?hyprgrass_commit:%{error:hyprgrass_commit is not defined}}
%{!?hyprgrass_pins_ref:%{error:hyprgrass_pins_ref is not defined}}
%{!?wftouch_commit:%{error:wftouch_commit is not defined}}
%{!?hyprland_evr:%{error:hyprland_evr is not defined}}
%global debug_package %{nil}

Name:           hyprgrass
Version:        %{hyprgrass_version}
Release:        1%{?dist}.microos
Summary:        Touch gesture plugin for Hyprland
License:        BSD-3-Clause AND Apache-2.0 AND MIT
URL:            https://github.com/horriblename/hyprgrass
Source0:        %{url}/archive/%{hyprgrass_commit}.tar.gz#/hyprgrass-%{hyprgrass_commit}.tar.gz
Source1:        https://github.com/WayfireWM/wf-touch/archive/%{wftouch_commit}.tar.gz#/wf-touch-%{wftouch_commit}.tar.gz
Source2:        https://raw.githubusercontent.com/horriblename/hyprgrass/%{hyprgrass_pins_ref}/hyprpm.toml#/hyprpm.toml
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  doctest-devel
BuildRequires:  glm-devel
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(libinput)
BuildRequires:  pkgconfig(lua)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(xkbcommon)
Requires:       hyprland = %{hyprland_evr}

%description
Hyprgrass is a Hyprland plugin that turns touchscreen swipes and long presses
into Hyprland gestures through wf-touch.

%prep
%autosetup -n hyprgrass-%{hyprgrass_commit}
grep -qx "v%{hyprgrass_version}" VERSION
mkdir -p subprojects/wf-touch
tar -xzf %{SOURCE1} --strip-components=1 --no-same-owner -C subprojects/wf-touch
cp %{SOURCE2} hyprpm.toml

%build
march=
%ifarch aarch64
march=${MICROOS_MARCH:-}
%endif
export CFLAGS="%{optflags} $march -ffile-prefix-map=%{_builddir}=/build"
export CXXFLAGS="$CFLAGS"
%meson -Dhyprgrass=true -Dtests=enabled
%meson_build

%check
if ! out=$(meson test -C %{_vpath_builddir} --no-rebuild --print-errorlogs 2>&1); then
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out"
grep -Eq '^Ok: +[1-9][0-9]* *$' <<<"$out"

%install
DESTDIR=%{buildroot} meson install -C %{_vpath_builddir} --no-rebuild --skip-subprojects
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/hyprgrass/LICENSE
install -D -pm644 LICENSE.aosp %{buildroot}%{_licensedir}/hyprgrass/LICENSE.aosp
install -D -pm644 subprojects/wf-touch/LICENSE %{buildroot}%{_licensedir}/hyprgrass/LICENSE.wf-touch
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/hyprgrass/LICENSE
%license %{_licensedir}/hyprgrass/LICENSE.aosp
%license %{_licensedir}/hyprgrass/LICENSE.wf-touch
%{_libdir}/libhyprgrass.so

%changelog
