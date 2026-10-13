%{!?commit:%{error:commit is not defined}}
%{!?reshade_commit:%{error:reshade_commit is not defined}}
%{!?vkroots_commit:%{error:vkroots_commit is not defined}}
%global debug_package %{nil}
%global libliftoff_minver 0.5.0

Name:           gamescope
Version:        3.16.31
Release:        1%{?dist}.microos
Summary:        Micro-compositor for video games on Wayland
License:        LicenseRef-Callaway-BSD
URL:            https://github.com/OpenGamingCollective/gamescope
ExcludeArch:    ppc64le

Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        stb.pc
Source2:        https://github.com/misyltoad/reshade/archive/%{reshade_commit}/reshade-%{reshade_commit}.tar.gz
Source3:        https://github.com/misyltoad/vkroots/archive/%{vkroots_commit}/vkroots-%{vkroots_commit}.tar.gz

Patch:          Allow-to-use-system-wlroots.patch
Patch:          Use-system-stb-glm.patch
Patch:          0003-pace-the-non-vrr-fps-limit-on-time.patch

Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  git-core
BuildRequires:  glm-devel
BuildRequires:  google-benchmark-devel
BuildRequires:  libXcursor-devel
BuildRequires:  libXmu-devel
BuildRequires:  meson >= 0.54.0
BuildRequires:  ninja-build
BuildRequires:  pkgconfig(catch2)
BuildRequires:  pkgconfig(hwdata)
BuildRequires:  pkgconfig(libavif)
BuildRequires:  pkgconfig(libcap)
BuildRequires:  pkgconfig(libdecor-0)
BuildRequires:  pkgconfig(libdisplay-info)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(libeis-1.0)
BuildRequires:  (pkgconfig(libliftoff) >= %{libliftoff_minver} with pkgconfig(libliftoff) < 0.6)
BuildRequires:  pkgconfig(libpipewire-0.3)
BuildRequires:  pkgconfig(libudev)
BuildRequires:  pkgconfig(luajit)
BuildRequires:  pkgconfig(openvr) >= 2.12
BuildRequires:  pkgconfig(sdl2)
BuildRequires:  pkgconfig(vulkan)
BuildRequires:  pkgconfig(wayland-protocols) >= 1.17
BuildRequires:  pkgconfig(wayland-scanner)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(x11)
BuildRequires:  pkgconfig(xcomposite)
BuildRequires:  pkgconfig(xdamage)
BuildRequires:  pkgconfig(xext)
BuildRequires:  pkgconfig(xfixes)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(xrender)
BuildRequires:  pkgconfig(xres)
BuildRequires:  pkgconfig(xtst)
BuildRequires:  pkgconfig(xxf86vm)
BuildRequires:  spirv-headers-devel
BuildRequires:  stb_image-devel >= 2.30^20251025gitf1c79c0-2
BuildRequires:  stb_image-static
BuildRequires:  stb_image_resize-devel
BuildRequires:  stb_image_resize-static
BuildRequires:  stb_image_write-devel
BuildRequires:  stb_image_write-static
BuildRequires:  /usr/bin/glslangValidator

Provides:       bundled(vkroots) = 0^20240429git5106d8a

Requires:       libliftoff%{?_isa} >= %{libliftoff_minver}
Requires:       xorg-x11-server-Xwayland
Recommends:     mesa-dri-drivers
Recommends:     mesa-vulkan-drivers

%description
gamescope from the Open Gaming Collective, the micro-compositor for running
video games on Wayland.

%prep
%autosetup -p1 -N -n %{name}-%{commit}
mkdir -p pkgconfig
cp %{SOURCE1} pkgconfig/stb.pc

sed -i 's^../thirdparty/SPIRV-Headers/include/spirv/^/usr/include/spirv/^' src/meson.build

tar -xzf %{SOURCE2} --strip-components=1 -C src/reshade
tar -xzf %{SOURCE3} --strip-components=1 -C subprojects/vkroots

%autopatch -p1

%build
export PKG_CONFIG_PATH=pkgconfig
%meson \
    -Davif_screenshots=enabled \
    -Dbenchmark=enabled \
    -Ddrm_backend=enabled \
    -Denable_gamescope=true \
    -Denable_gamescope_wsi_layer=true \
    -Denable_openvr_support=true \
    -Dforce_fallback_for=[] \
    -Dinput_emulation=enabled \
    -Dpipewire=enabled \
    -Drt_cap=enabled \
    -Dsdl2_backend=enabled
%meson_build

%install
%meson_install --skip-subprojects

%check
%meson_test utils/frame_limit

%files
%license LICENSE
%doc README.md
%caps(CAP_SYS_NICE=pe) %{_bindir}/gamescope
%{_bindir}/gamescopectl
%{_bindir}/gamescopereaper
%{_bindir}/gamescopestream
%{_bindir}/gamescope-type
%{_datadir}/gamescope
%{_libdir}/libVkLayer_FROG_gamescope_wsi_*.so
%{_datadir}/vulkan/implicit_layer.d/VkLayer_FROG_gamescope_wsi.*.json
