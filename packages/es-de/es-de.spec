%{!?commit:%{error:commit is not defined}}
%global debug_package %{nil}

Name:           es-de
Version:        3.5.0
Release:        1%{?dist}.microos
Summary:        ES-DE frontend for browsing and launching games

License:        MIT AND BSL-1.0 AND CECILL-C AND Apache-2.0 AND Bitstream-Vera AND OFL-1.1 AND Ubuntu-font-1.0 AND GPL-3.0-or-later AND CC0-1.0 AND CC-BY-SA-3.0 AND CC-BY-NC-SA-4.0 AND LicenseRef-Naver-Nanum AND LicenseRef-Fontfabric-FFF-EULA-2.0
URL:            https://gitlab.com/es-de/emulationstation-de
Source0:        %{url}/-/archive/%{commit}/emulationstation-de-%{commit}.tar.gz
Source1:        escape-test.cpp
Source2:        rocknix-test.cpp

Patch0001:      0001-escape-every-shell-special-byte-in-unix-launch-paths.patch
Patch0002:      0002-gamelist-read-and-write-rocknix-gamelists-in-the-sys.patch
Patch0003:      0003-gamelist-keep-unknown-data-of-rewritten-entries.patch
Patch0004:      0004-media-show-rocknix-gamelist-art-where-es-de-has-none.patch

Vendor:         MicroOS
BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  gettext
BuildRequires:  alsa-lib-devel
BuildRequires:  bluez-libs-devel
BuildRequires:  freeimage-devel
BuildRequires:  libglvnd-devel
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(harfbuzz)
BuildRequires:  pkgconfig(icu-uc)
BuildRequires:  pkgconfig(libavcodec)
BuildRequires:  pkgconfig(libavfilter)
BuildRequires:  pkgconfig(libavformat)
BuildRequires:  pkgconfig(libavutil)
BuildRequires:  pkgconfig(libcurl)
BuildRequires:  pkgconfig(libgit2)
BuildRequires:  pkgconfig(libswresample)
BuildRequires:  pkgconfig(libswscale)
BuildRequires:  pkgconfig(poppler-cpp)
BuildRequires:  pkgconfig(pugixml)
BuildRequires:  pkgconfig(sdl2)

%description
ES-DE (EmulationStation Desktop Edition) built from the upstream release tag
against Fedora's libraries, without the application updater.

%prep
%autosetup -p1 -n emulationstation-de-%{commit}

%build
%cmake -DCMAKE_BUILD_TYPE=Release -DAPPLICATION_UPDATER=OFF -DBUNDLED_CERTS=OFF %{?ccache_launcher}
%cmake_build

%install
%cmake_install

%check
g++ -std=c++17 -O1 -ffunction-sections -fdata-sections -I es-core/src -I external/glm -I external/rapidjson/include \
  -I external/utfcpp/source $(pkg-config --cflags sdl2) %{SOURCE1} es-core/src/utils/FileSystemUtil.cpp \
  -Wl,--gc-sections -o escape-test
mkdir escape-dir
./escape-test "$PWD/escape-dir"
g++ -std=c++17 -O1 -ffunction-sections -fdata-sections -I es-app/src -I es-core/src -I external/glm \
  -I external/rapidjson/include -I external/utfcpp/source $(pkg-config --cflags sdl2 pugixml) %{SOURCE2} \
  es-app/src/RocknixGamelist.cpp es-core/src/utils/FileSystemUtil.cpp es-core/src/utils/TimeUtil.cpp \
  es-core/src/Log.cpp $(pkg-config --libs pugixml) -Wl,--gc-sections -o rocknix-test
mkdir rocknix-dir
./rocknix-test "$PWD/rocknix-dir"

%files
%license LICENSE
%{_bindir}/es-de
%{_bindir}/es-pdf-convert
%{_datadir}/es-de/
%{_datadir}/applications/org.es_de.frontend.desktop
%{_datadir}/icons/hicolor/scalable/apps/org.es_de.frontend.svg
%{_datadir}/pixmaps/org.es_de.frontend.svg
%{_datadir}/metainfo/org.es_de.frontend.appdata.xml
%{_mandir}/man6/es-de.6*
