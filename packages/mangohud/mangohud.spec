%{!?commit:%{error:commit is not defined}}
%global debug_package %{nil}
%global appname MangoHud
%global forgeurl https://github.com/flightlessmango/MangoHud

%global imgui_ver 1.91.6
%global vulkan_ver 1.4.346
%global implot_ver 0.16
%global implot_wrap_ver 2

%bcond_with tests

Name:           mangohud
Version:        0.8.4
Release:        1%{?dist}.microos
Summary:        Vulkan and OpenGL overlay for monitoring FPS, temperatures, CPU/GPU load

License:        MIT
URL:            %{forgeurl}
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        https://github.com/ocornut/imgui/archive/v%{imgui_ver}/imgui-%{imgui_ver}.tar.gz
Source2:        https://github.com/KhronosGroup/Vulkan-Headers/archive/v%{vulkan_ver}/vulkan-headers-%{vulkan_ver}.tar.gz
Source3:        https://github.com/KhronosGroup/Vulkan-Utility-Libraries/archive/v%{vulkan_ver}/vulkan-utility-libraries-%{vulkan_ver}.tar.gz
Source4:        https://github.com/epezent/implot/archive/refs/tags/v%{implot_ver}.zip#/implot-%{implot_ver}.zip
Source5:        https://wrapdb.mesonbuild.com/v%{implot_wrap_ver}/implot_%{implot_ver}-1/get_patch#/implot_%{implot_ver}-1_patch.zip

Patch0001:      0001-gpu_fdinfo-fix-msm_dpu-sensor-detection.patch
Patch0002:      0002-gpu_fdinfo-fixup-driver-mismatch-for-msm_dpu.patch
Patch0003:      0003-gpu_fdinfo-read-msm_dpu-core-clock-from-devfreq.patch
Patch0004:      0004-file_utils-handle-exception-from-directory_iterator.patch
Patch0005:      0005-gpu_fdinfo-handle-denied-proc-fd-iteration.patch
Patch0006:      0006-battery-find-batteries-by-their-sysfs-type.patch
Patch0007:      0007-mangoapp-throttle-overlay-to-one-render-per-game-frame.patch
Patch0008:      0008-gpu_fdinfo-read-msm_dpu-resident-memory.patch
Patch0009:      0009-gpu_fdinfo-show-msm_dpu-game-memory-as-vram.patch
Patch0010:      0010-params-drop-the-frame-timing-graph-from-preset-2.patch
Patch0011:      0011-params-hide-msm_dpu-gpu-rows-without-a-source.patch
Patch0012:      0012-params-hide-more-msm_dpu-rows-without-a-source.patch
Patch0013:      0013-mangoapp-skip-the-window-resize-until-the-size-is-known.patch

Vendor:         MicroOS
BuildRequires:  vulkan-headers
BuildRequires:  appstream
BuildRequires:  dbus-devel
BuildRequires:  gcc-c++
BuildRequires:  git-core
BuildRequires:  libappstream-glib
BuildRequires:  libstdc++-static
BuildRequires:  meson >= 0.60
BuildRequires:  python3-mako
BuildRequires:  unzip
BuildRequires:  pkgconfig(dri)
BuildRequires:  pkgconfig(glfw3)
BuildRequires:  pkgconfig(glslang)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(spdlog)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(x11)
BuildRequires:  pkgconfig(xkbcommon)

%if %{with tests}
BuildRequires:  libcmocka-devel
%endif

Requires:       hicolor-icon-theme
Requires:       vulkan-loader%{?_isa}

Recommends:     (mangohud(x86-32) if glibc(x86-32))

Suggests:       goverlay

Provides:       bundled(imgui) = %{imgui_ver}
Provides:       bundled(implot) = %{implot_ver}
Provides:       bundled(vulkan-headers) = %{vulkan_ver}
Provides:       bundled(vulkan-utility-libraries) = %{vulkan_ver}

%global _description %{expand:
A Vulkan and OpenGL overlay for monitoring FPS, temperatures, CPU/GPU load and
more.}

%description %{_description}


%prep
%autosetup -n %{appname}-%{commit} -p1
%setup -qn %{appname}-%{commit} -D -T -a1
%setup -qn %{appname}-%{commit} -D -T -a2
%setup -qn %{appname}-%{commit} -D -T -a3
%setup -qn %{appname}-%{commit} -D -T -a4
%setup -qn %{appname}-%{commit} -D -T -a5

mv imgui-%{imgui_ver} subprojects/
mv Vulkan-Headers-%{vulkan_ver} subprojects/
mv Vulkan-Utility-Libraries-%{vulkan_ver} subprojects/
mv implot-%{implot_ver} subprojects/
cp -r subprojects/packagefiles/imgui-%{imgui_ver}/. subprojects/imgui-%{imgui_ver}/
cp -r subprojects/packagefiles/vulkan-headers/. subprojects/Vulkan-Headers-%{vulkan_ver}/
cp -r subprojects/packagefiles/vulkan-utility-libraries/. subprojects/Vulkan-Utility-Libraries-%{vulkan_ver}/

%if %{with tests}
sed -i "s/  cmocka = subproject('cmocka')//g" meson.build
sed -i "s/cmocka_dep = cmocka.get_variable('cmocka_dep')/cmocka_dep = dependency('cmocka')/g" meson.build
%endif


%build
%meson \
    -Dmangoapp=true \
    -Dmangohudctl=true \
    -Dmangoplot=disabled \
    -Dwith_fex=false \
    -Dinclude_doc=true \
    -Duse_system_spdlog=enabled \
    -Dwith_wayland=enabled \
    -Dwith_xnvctrl=disabled \
    %if %{with tests}
    -Dtests=enabled \
    %else
    -Dtests=disabled \
    %endif
    %{nil}
%meson_build


%install
%meson_install


%check
%if %{with tests}
%meson_test
%endif


%files
%license LICENSE
%doc README.md presets.conf.example
%{_bindir}/mangoapp
%{_bindir}/mangohud
%{_bindir}/mangohudctl
%{_datadir}/icons/hicolor/scalable/*/*.svg
%{_datadir}/vulkan/implicit_layer.d/*Mango*.json
%{_docdir}/%{name}/%{appname}.conf.example
%{_libdir}/%{name}/
%{_mandir}/man1/%{name}.1*
%{_mandir}/man1/mangoapp.1*
%{_metainfodir}/*.metainfo.xml
