%{!?hyprtoolkit_version:%{error:hyprtoolkit_version is not defined}}
%{!?hyprtoolkit_commit:%{error:hyprtoolkit_commit is not defined}}
%{!?hyprwscanner_version:%{error:hyprwscanner_version is not defined}}
%{!?hyprwscanner_commit:%{error:hyprwscanner_commit is not defined}}
%global debug_package %{nil}

Name:           hyprtoolkit
Version:        %{hyprtoolkit_version}
Release:        1%{?dist}.microos
Summary:        Wayland GUI toolkit of the Hyprland stack
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/hyprtoolkit
Source0:        %{url}/archive/%{hyprtoolkit_commit}.tar.gz#/hyprtoolkit-%{hyprtoolkit_commit}.tar.gz
Source1:        https://github.com/hyprwm/hyprwayland-scanner/archive/%{hyprwscanner_commit}.tar.gz#/hyprwayland-scanner-%{hyprwscanner_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  pkgconfig(absl_flat_hash_map)
BuildRequires:  pkgconfig(aquamarine)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(hyprgraphics)
BuildRequires:  pkgconfig(hyprlang)
BuildRequires:  pkgconfig(hyprutils)
BuildRequires:  pkgconfig(iniparser)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(opengl)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(pugixml)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(xkbcommon)

%description
hyprtoolkit is the Wayland GUI toolkit hyprland-guiutils draws its dialogs with.

%package devel
Summary:        Development files for hyprtoolkit
Requires:       hyprtoolkit%{?_isa} = %{version}-%{release}

%description devel
Headers and pkg-config file for hyprtoolkit.

%prep
%autosetup -n hyprtoolkit-%{hyprtoolkit_commit}
grep -qx "%{version}" VERSION
mkdir hyprwayland-scanner
tar -xzf %{SOURCE1} --strip-components=1 --no-same-owner -C hyprwayland-scanner
grep -qx "%{hyprwscanner_version}" hyprwayland-scanner/VERSION

%build
march=
%ifarch aarch64
march=${MICROOS_MARCH:-}
%endif
export CFLAGS="%{optflags} $march -ffile-prefix-map=%{_builddir}=/build"
export CXXFLAGS="$CFLAGS"
scanner=$PWD/scanner-stage
cmake -S hyprwayland-scanner -B scanner-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$scanner"
cmake --build scanner-build --parallel %{_smp_build_ncpus}
cmake --install scanner-build
export PATH="$scanner/bin:$PATH"
%cmake -DCMAKE_PREFIX_PATH="$scanner"
%cmake_build

%install
%cmake_install
install -D -pm644 LICENSE %{buildroot}%{_licensedir}/hyprtoolkit/LICENSE
if grep -rIl -- '%{_builddir}' %{buildroot}; then
  echo "install: a file still names the build directory" >&2
  exit 1
fi

%files
%license %{_licensedir}/hyprtoolkit/LICENSE
%{_libdir}/libhyprtoolkit.so.*

%files devel
%license LICENSE
%{_includedir}/hyprtoolkit
%{_libdir}/libhyprtoolkit.so
%{_libdir}/pkgconfig/hyprtoolkit.pc

%changelog
