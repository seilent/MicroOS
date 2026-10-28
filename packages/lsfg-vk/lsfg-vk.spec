%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}
%global debug_package %{nil}

Name:           lsfg-vk
Version:        2.0.0~%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        Lossless Scaling frame generation as a Vulkan layer
License:        GPL-3.0-or-later AND MIT
URL:            https://github.com/seilent/lsfg-vk-arm64
Source0:        %{url}/archive/%{commit}/lsfg-vk-arm64-%{commit}.tar.gz
Source1:        https://raw.githubusercontent.com/FrankBarretta/lsfg-vk-android/3e89e5439a98f55d5acb003d20039426ab24e69c/LICENSE.md#/LICENSE-MIT.md
Source2:        https://raw.githubusercontent.com/marzer/tomlplusplus/30172438cee64926dc41fdd9c11fb3ba5b2ba9de/LICENSE#/LICENSE-tomlplusplus
Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  libstdc++-static
BuildRequires:  vulkan-headers >= 1.4.328
BuildRequires:  python3
BuildRequires:  glibc-locale-source

Requires:       vulkan-loader%{?_isa}

%description
The lsfg-vk Vulkan layer from seilent/lsfg-vk-arm64. It reads Lossless.dll from
a Lossless Scaling install and loads only in processes that set LSFGVK_ENV=1.

%package tests
Summary:        Synthetic Lossless.dll files for the lsfg-vk loader check
BuildArch:      noarch

%description tests
good.dll carries a SPIR-V stub at every shader id the layer checks, not-spirv.dll
replaces one of them with a non SPIR-V blob. Both come from the lsfg-vk test
generator and hold nothing from Lossless Scaling.

%prep
%autosetup -n lsfg-vk-arm64-%{commit}
cp -p %{SOURCE1} %{SOURCE2} .

%build
export LDFLAGS="%{build_ldflags} -static-libstdc++ -static-libgcc"
%cmake \
  -DLSFGVK_BUILD_VK_LAYER=ON \
  -DLSFGVK_BUILD_CLI=OFF \
  -DLSFGVK_BUILD_UI=OFF \
  -DLSFGVK_BUILD_TESTS=ON \
  -DLSFGVK_LAYER_LIBRARY_PATH=%{_libdir}/liblsfg-vk-layer.so \
  -DLSFGVK_LAYER_ENABLE_ENVIRONMENT=LSFGVK_ENV
%cmake_build

%check
%ctest

%install
%cmake_install
mv %{buildroot}%{_datadir}/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json \
  %{buildroot}%{_datadir}/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.%{_arch}.json
install -d %{buildroot}%{_datadir}/lsfg-vk/tests
install -pm644 %{__cmake_builddir}/tests/fixtures/good.dll %{__cmake_builddir}/tests/fixtures/not-spirv.dll \
  %{buildroot}%{_datadir}/lsfg-vk/tests/

%files
%license LICENSE.md LICENSE-MIT.md LICENSE-tomlplusplus
%{_libdir}/liblsfg-vk-layer.so
%{_datadir}/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.%{_arch}.json

%files tests
%license LICENSE.md
%dir %{_datadir}/lsfg-vk
%{_datadir}/lsfg-vk/tests/
