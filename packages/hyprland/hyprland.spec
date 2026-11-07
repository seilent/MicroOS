%{!?hyprutils_version:%{error:hyprutils_version is not defined}}
%global debug_package %{nil}
%global stage %{_builddir}/stage
%global pcprefix %{_prefix}

Name:           hyprland
Version:        %{hyprland_version}
Release:        1%{?dist}.microos
Summary:        A dynamic tiling Wayland compositor
License:        BSD-3-Clause AND BSD-2-Clause
URL:            https://github.com/hyprwm/Hyprland
Source0:        %{url}/releases/download/v%{hyprland_version}/source-v%{hyprland_version}.tar.gz#/source-v%{hyprland_version}.tar.gz
Source1:        %{stack}/hyprutils/archive/%{hyprutils_commit}.tar.gz#/hyprutils-%{hyprutils_commit}.tar.gz
Source2:        %{stack}/hyprlang/archive/%{hyprlang_commit}.tar.gz#/hyprlang-%{hyprlang_commit}.tar.gz
Source3:        %{stack}/hyprgraphics/archive/%{hyprgraphics_commit}.tar.gz#/hyprgraphics-%{hyprgraphics_commit}.tar.gz
Source4:        %{stack}/hyprwire/archive/%{hyprwire_commit}.tar.gz#/hyprwire-%{hyprwire_commit}.tar.gz
Source5:        %{stack}/hyprland-protocols/archive/%{hyprprotocols_commit}.tar.gz#/hyprland-protocols-%{hyprprotocols_commit}.tar.gz
Source6:        %{stack}/aquamarine/archive/%{aquamarine_commit}.tar.gz#/aquamarine-%{aquamarine_commit}.tar.gz
Source7:        %{stack}/hyprcursor/archive/%{hyprcursor_commit}.tar.gz#/hyprcursor-%{hyprcursor_commit}.tar.gz
Source8:        https://github.com/stephenberry/glaze/archive/%{glaze_commit}.tar.gz#/glaze-%{glaze_commit}.tar.gz
Source9:        %{stack}/hyprwayland-scanner/archive/%{hyprwscanner_commit}.tar.gz#/hyprwayland-scanner-%{hyprwscanner_commit}.tar.gz
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  gtest-devel
BuildRequires:  pkgconfig
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(glslang)

BuildRequires:  pkgconfig(libdisplay-info)
BuildRequires:  pkgconfig(hwdata)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(libinput) >= 1.29
BuildRequires:  pkgconfig(libjpeg)
BuildRequires:  pkgconfig(libmagic)
BuildRequires:  pkgconfig(libjxl)
BuildRequires:  pkgconfig(libheif)
BuildRequires:  pkgconfig(librsvg-2.0)
BuildRequires:  pkgconfig(libseat)
BuildRequires:  pkgconfig(libudev)
BuildRequires:  pkgconfig(libwebp)
BuildRequires:  pkgconfig(lua) >= 5.4
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(libzip)
BuildRequires:  libeis-devel
BuildRequires:  libasan
BuildRequires:  pkgconfig(readline)
BuildRequires:  pkgconfig(re2)
BuildRequires:  pkgconfig(muparser)
BuildRequires:  pkgconfig(libcanberra)
BuildRequires:  pkgconfig(pugixml)
BuildRequires:  pkgconfig(sdbus-c++)
BuildRequires:  pkgconfig(tomlplusplus)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols) >= 1.49
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(xcb-errors)
BuildRequires:  pkgconfig(xcb-icccm)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(uuid)
BuildRequires:  pkgconfig(xwayland)
BuildRequires:  python3
Requires:       hyprutils%{?_isa} = %{version}-%{release}
Requires:       hyprlang%{?_isa} = %{version}-%{release}
Requires:       hyprgraphics%{?_isa} = %{version}-%{release}
Requires:       hyprwire%{?_isa} = %{version}-%{release}
Requires:       aquamarine%{?_isa} = %{version}-%{release}
Requires:       hyprcursor%{?_isa} = %{version}-%{release}

%description
Hyprland is a dynamic tiling Wayland compositor.

%package -n hyprutils
Summary:        Utility libraries for the Hyprland stack
License:        BSD-3-Clause
Requires:       pixman%{?_isa}

%description -n hyprutils
Shared utility libraries for the Hyprland stack.

%package -n hyprutils-devel
Summary:        Development files for hyprutils
License:        BSD-3-Clause
Requires:       hyprutils%{?_isa} = %{version}-%{release}
Requires:       pkgconfig(pixman-1)

%description -n hyprutils-devel
Headers and pkg-config files for hyprutils.

%package -n hyprlang
Summary:        Configuration language for the Hyprland stack
License:        LGPL-3.0-only

%description -n hyprlang
The configuration language library for the Hyprland stack.

%package -n hyprlang-devel
Summary:        Development files for hyprlang
License:        LGPL-3.0-only
Requires:       hyprlang%{?_isa} = %{version}-%{release}
Requires:       hyprutils-devel%{?_isa} = %{version}-%{release}

%description -n hyprlang-devel
Headers and pkg-config files for hyprlang.

%package -n hyprgraphics
Summary:        Graphics libraries for the Hyprland stack
License:        BSD-3-Clause
Requires:       libheif%{?_isa}
Requires:       libjxl%{?_isa}

%description -n hyprgraphics
Shared graphics libraries for the Hyprland stack.

%package -n hyprgraphics-devel
Summary:        Development files for hyprgraphics
License:        BSD-3-Clause
Requires:       hyprgraphics%{?_isa} = %{version}-%{release}
Requires:       hyprutils-devel%{?_isa} = %{version}-%{release}

%description -n hyprgraphics-devel
Headers and pkg-config files for hyprgraphics.

%package -n hyprwire
Summary:        Wire protocol library for the Hyprland stack
License:        BSD-3-Clause

%description -n hyprwire
The wire protocol library and its scanner for the Hyprland stack.

%package -n hyprwire-devel
Summary:        Development files for hyprwire
License:        BSD-3-Clause
Requires:       hyprwire%{?_isa} = %{version}-%{release}
Requires:       hyprutils-devel%{?_isa} = %{version}-%{release}

%description -n hyprwire-devel
Headers, the scanner and pkg-config files for hyprwire.

%package -n hyprland-protocols-devel
Summary:        Wayland protocol descriptions for Hyprland
License:        BSD-3-Clause

%description -n hyprland-protocols-devel
The Hyprland Wayland protocol XML descriptions and their pkg-config file.

%package -n aquamarine
Summary:        Backend library for the Hyprland stack
License:        BSD-3-Clause

%description -n aquamarine
The aquamarine backend library used by Hyprland.

%package -n aquamarine-devel
Summary:        Development files for aquamarine
License:        BSD-3-Clause
Requires:       aquamarine%{?_isa} = %{version}-%{release}
Requires:       hyprutils-devel%{?_isa} = %{version}-%{release}
Requires:       pkgconfig(hwdata)
Requires:       pkgconfig(libdisplay-info)
Requires:       pkgconfig(libseat)

%description -n aquamarine-devel
Headers and pkg-config files for aquamarine.

%package -n hyprcursor
Summary:        Cursor theme library for the Hyprland stack
License:        BSD-3-Clause

%description -n hyprcursor
The hyprcursor library and its theme tool.

%package -n hyprcursor-devel
Summary:        Development files for hyprcursor
License:        BSD-3-Clause
Requires:       hyprcursor%{?_isa} = %{version}-%{release}
Requires:       hyprlang-devel%{?_isa} = %{version}-%{release}

%description -n hyprcursor-devel
Headers and pkg-config files for hyprcursor.

%package -n glaze-devel
Summary:        Header only JSON library used by Hyprland
License:        MIT
BuildArch:      noarch

%description -n glaze-devel
The glaze header only library and its CMake package files.

%package -n hyprland-devel
Summary:        Development files and headers for Hyprland plugins
License:        BSD-3-Clause
Requires:       hyprland%{?_isa} = %{version}-%{release}
Requires:       aquamarine-devel%{?_isa} = %{version}-%{release}
Requires:       hyprcursor-devel%{?_isa} = %{version}-%{release}
Requires:       hyprgraphics-devel%{?_isa} = %{version}-%{release}
Requires:       hyprlang-devel%{?_isa} = %{version}-%{release}
Requires:       hyprutils-devel%{?_isa} = %{version}-%{release}
Requires:       hyprwire-devel%{?_isa} = %{version}-%{release}
Requires:       hyprland-protocols-devel
Requires:       pkgconfig(libdrm)
Requires:       pkgconfig(libinput)
Requires:       pkgconfig(wayland-server)
Requires:       pkgconfig(xkbcommon)

%description -n hyprland-devel
The Hyprland headers and pkg-config file a plugin builds against.

%prep
%setup -q -c -T -n hyprland-stack
mkdir -p hyprutils hyprlang hyprgraphics hyprwire hyprland-protocols aquamarine hyprcursor glaze hyprland hyprwayland-scanner
tar -xzf %{SOURCE1} --strip-components=1 --no-same-owner -C hyprutils
tar -xzf %{SOURCE2} --strip-components=1 --no-same-owner -C hyprlang
tar -xzf %{SOURCE3} --strip-components=1 --no-same-owner -C hyprgraphics
tar -xzf %{SOURCE4} --strip-components=1 --no-same-owner -C hyprwire
tar -xzf %{SOURCE5} --strip-components=1 --no-same-owner -C hyprland-protocols
tar -xzf %{SOURCE6} --strip-components=1 --no-same-owner -C aquamarine
tar -xzf %{SOURCE7} --strip-components=1 --no-same-owner -C hyprcursor
tar -xzf %{SOURCE8} --strip-components=1 --no-same-owner -C glaze
tar -xzf %{SOURCE9} --strip-components=1 --no-same-owner -C hyprwayland-scanner
tar -xzf %{SOURCE0} --strip-components=1 --no-same-owner -C hyprland

%build
stack=%{_builddir}/hyprland-stack
stage=%{stage}
march=
%ifarch aarch64
march=${MICROOS_MARCH:-}
%endif

build_component() {
  local name=$1
  shift
  export PKG_CONFIG_PATH="$stage/usr/lib64/pkgconfig:$stage/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PATH="$stage/usr/bin:$PATH"
  export LD_LIBRARY_PATH="$stage/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  cmake -S "$stack/$name" -B "$stack/build-$name" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{_prefix} \
    -DCMAKE_PREFIX_PATH="$stage/usr" \
    -DCMAKE_CXX_FLAGS="$RPM_OPT_FLAGS $march -I$stage/usr/include -ffile-prefix-map=$stage/usr=/usr -ffile-prefix-map=../../stage/usr=/usr" \
    -DCMAKE_C_FLAGS="$RPM_OPT_FLAGS $march -I$stage/usr/include -ffile-prefix-map=$stage/usr=/usr -ffile-prefix-map=../../stage/usr=/usr" \
    "$@"
  local targets=()
  if [[ $name == hyprcursor ]]; then targets=(--target hyprcursor hyprcursor-util); fi
  cmake --build "$stack/build-$name" --parallel %{_smp_build_ncpus} "${targets[@]}"
  DESTDIR="$stage" cmake --install "$stack/build-$name"
  local pc
  for pc in "$stage"/usr/lib64/pkgconfig/*.pc "$stage"/usr/share/pkgconfig/*.pc; do
    [[ -f $pc ]] || continue
    sed -i -E "s|^([A-Za-z_]+)=/usr|\1=$stage/usr|" "$pc"
  done
}

build_component hyprwayland-scanner
build_component glaze -DGLZ_ENABLE_EETF=OFF -Dglaze_DEVELOPER_MODE=OFF -Dglaze_BUILD_EXAMPLES=OFF
build_component hyprutils
build_component hyprlang
build_component hyprgraphics
build_component hyprwire
build_component hyprland-protocols
build_component aquamarine
build_component hyprcursor
build_component hyprland -DNO_HYPRPM=ON -DNO_UWSM=ON -DNO_SYSTEMD=OFF -DNO_XWAYLAND=OFF

%check
stack=%{_builddir}/hyprland-stack
stage=%{stage}
export PKG_CONFIG_PATH="$stage/usr/lib64/pkgconfig:$stage/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH="$stage/usr/bin:$PATH"
export LD_LIBRARY_PATH="$stage/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$stage/usr"

cmake -S "$stack/hyprutils" -B "$stack/test-hyprutils" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_PREFIX_PATH="$stage/usr" \
  -DCMAKE_CXX_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include" \
  -DCMAKE_C_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include"
cmake --build "$stack/test-hyprutils" --parallel %{_smp_build_ncpus}
ctest --test-dir "$stack/test-hyprutils" --output-on-failure --no-tests=error

cmake -S "$stack/hyprwire" -B "$stack/test-hyprwire" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_PREFIX_PATH="$stage/usr" \
  -DCMAKE_CXX_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include" \
  -DCMAKE_C_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include"
cmake --build "$stack/test-hyprwire" --parallel %{_smp_build_ncpus}
ctest --test-dir "$stack/test-hyprwire" --output-on-failure --no-tests=error

ctest --test-dir "$stack/build-aquamarine" --output-on-failure --no-tests=error \
  -E simpleWindow

cmake -S "$stack/hyprland" -B "$stack/test-hyprland" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_PREFIX_PATH="$stage/usr" \
  -DCMAKE_CXX_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include" \
  -DCMAKE_C_FLAGS="$RPM_OPT_FLAGS -I$stage/usr/include" \
  -DWITH_TESTS=ON \
  -DNO_HYPRPM=ON -DNO_UWSM=ON -DNO_SYSTEMD=OFF -DNO_XWAYLAND=OFF
cmake --build "$stack/test-hyprland" --parallel %{_smp_build_ncpus} \
  --target hyprland_gtests
ctest --test-dir "$stack/test-hyprland" --output-on-failure --no-tests=error

%install
mkdir -p %{buildroot}
cp -a %{stage}/usr %{buildroot}/
find %{buildroot} -name '*.pc' -path '*pkgconfig*' -exec \
  sed -i "s|%{stage}/usr|/usr|g" {} +
rm -f %{buildroot}%{_datadir}/wayland-sessions/hyprland.desktop \
      %{buildroot}%{_libdir}/systemd/user/hyprland-session.target \
      %{buildroot}%{_datadir}/xdg-desktop-portal/hyprland-portals.conf
rm -f %{buildroot}%{_datadir}/hypr/hyprland.lua \
      %{buildroot}%{_datadir}/hypr/*.png \
      %{buildroot}%{_bindir}/hyprtester \
      %{buildroot}%{_datadir}/hypr/test.lua \
      %{buildroot}%{_prefix}/lib/hyprtestplugin.so
rm -rf %{buildroot}%{_datadir}/hypr/lua-require \
       %{buildroot}%{_bindir}/hyprwayland-scanner \
       %{buildroot}%{_libdir}/pkgconfig/hyprwayland-scanner.pc \
       %{buildroot}%{_libdir}/cmake/hyprwayland-scanner
install -D -pm644 hyprland/subprojects/udis86/LICENSE \
  %{buildroot}%{_licensedir}/hyprland/LICENSE.udis86
if grep -rIl -- '%{stage}' %{buildroot}; then
  echo "install: a file still names the build stage" >&2
  exit 1
fi

%files
%license hyprland/LICENSE
%license %{_licensedir}/hyprland/LICENSE.udis86
%{_bindir}/Hyprland
%{_bindir}/hyprland
%{_bindir}/hyprctl
%{_bindir}/start-hyprland
%{_datadir}/hypr
%{_mandir}/man1/Hyprland.1*
%{_mandir}/man1/hyprctl.1*

%files -n hyprutils
%license hyprutils/LICENSE
%{_libdir}/libhyprutils.so.*

%files -n hyprutils-devel
%license hyprutils/LICENSE
%{_includedir}/hyprutils
%{_libdir}/libhyprutils.so
%{_libdir}/pkgconfig/hyprutils.pc

%files -n hyprlang
%license hyprlang/LICENSE hyprlang/COPYRIGHT
%{_libdir}/libhyprlang.so.*

%files -n hyprlang-devel
%license hyprlang/LICENSE hyprlang/COPYRIGHT
%{_includedir}/hyprlang.hpp
%{_libdir}/libhyprlang.so
%{_libdir}/pkgconfig/hyprlang.pc

%files -n hyprgraphics
%license hyprgraphics/LICENSE
%{_libdir}/libhyprgraphics.so.*

%files -n hyprgraphics-devel
%license hyprgraphics/LICENSE
%{_includedir}/hyprgraphics
%{_libdir}/libhyprgraphics.so
%{_libdir}/pkgconfig/hyprgraphics.pc

%files -n hyprwire
%license hyprwire/LICENSE
%{_libdir}/libhyprwire.so.*
%{_bindir}/hyprwire-scanner

%files -n hyprwire-devel
%license hyprwire/LICENSE
%{_includedir}/hyprwire
%{_libdir}/libhyprwire.so
%{_libdir}/pkgconfig/hyprwire.pc
%{_libdir}/pkgconfig/hyprwire-scanner.pc
%{_libdir}/cmake/hyprwire-scanner

%files -n hyprland-protocols-devel
%license hyprland-protocols/LICENSE
%{_datadir}/hyprland-protocols
%{_datadir}/pkgconfig/hyprland-protocols.pc

%files -n aquamarine
%license aquamarine/LICENSE
%{_libdir}/libaquamarine.so.*

%files -n aquamarine-devel
%license aquamarine/LICENSE
%{_includedir}/aquamarine
%{_libdir}/libaquamarine.so
%{_libdir}/pkgconfig/aquamarine.pc

%files -n hyprcursor
%license hyprcursor/LICENSE
%{_libdir}/libhyprcursor.so.*
%{_bindir}/hyprcursor-util

%files -n hyprcursor-devel
%license hyprcursor/LICENSE
%{_includedir}/hyprcursor
%{_includedir}/hyprcursor.hpp
%{_libdir}/libhyprcursor.so
%{_libdir}/pkgconfig/hyprcursor.pc

%files -n glaze-devel
%license glaze/LICENSE
%{_includedir}/glaze
%{_datadir}/glaze

%files -n hyprland-devel
%license hyprland/LICENSE
%{_includedir}/hyprland
%{_datadir}/pkgconfig/hyprland.pc

%changelog
