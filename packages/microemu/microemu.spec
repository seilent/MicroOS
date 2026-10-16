%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}
%global debug_package %{nil}

Name:           microemu
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        MicroEMU session: ES-DE and RetroArch on MicroOS
License:        GPL-2.0-or-later AND CC-BY-NC-SA-2.0 AND GPL-3.0-only AND OFL-1.1 AND LicenseRef-guest-GPL-unversioned AND LicenseRef-slang-shaders-no-license
URL:            https://github.com/seilent/MicroEMU
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        %{name}-assets-%{commit}.tar.gz
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  just
BuildRequires:  python3
BuildRequires:  python3-gobject
BuildRequires:  python3-cairo
BuildRequires:  gtk3
BuildRequires:  pango
BuildRequires:  gobject-introspection
BuildRequires:  libxml2
BuildRequires:  unzip
BuildRequires:  zip
Requires:       es-de
Requires:       retroarch
Requires:       libretro-beetle-ngp
Requires:       libretro-beetle-pce-fast
Requires:       libretro-beetle-vb
Requires:       libretro-beetle-wswan
Requires:       libretro-bsnes-mercury
Requires:       libretro-gambatte
Requires:       libretro-gw
Requires:       libretro-handy
Requires:       libretro-mgba
Requires:       libretro-nestopia
Requires:       libretro-pcsx-rearmed
Requires:       libretro-prosystem
Requires:       libretro-stella2014
Requires:       gamescope-session
Requires:       microset
Requires:       python3
Requires:       python3-gobject
Requires:       python3-cairo
Requires:       gtk3
Requires:       pango
Requires:       gobject-introspection
Requires:       xprop
Requires:       pulseaudio-utils
Requires:       wireplumber

%description
The MicroEMU session for MicroOS: ES-DE with the Art Book Next theme, the
RetroArch wrapper and its per core configs, shaders and remaps, the volume
OSD, the session, hotkey tables and the MicroSET schema.

%prep
%autosetup -n MicroEMU-%{commit}
mkdir -p assets
tar -xzf %{SOURCE1} -C assets

%build

%install
MICROEMU_CACHE="$PWD/assets/cache" MICROEMU_VERSION=%{commit} build/install.sh %{buildroot}

%check
MICROEMU_OSD_TEST_THEME=%{buildroot}%{_datadir}/microemu/es-de/themes/art-book-next-es-de \
MICROEMU_OSD_TEST_SPEAKER=%{buildroot}%{_datadir}/microemu/osd/speaker.svg \
just test

%files
%license LICENSE
%{_libexecdir}/microemu/
%dir %{_prefix}/lib/microos
%dir %{_prefix}/lib/microos/sessions.d
%{_prefix}/lib/microos/sessions.d/microemu.conf
%dir %{_prefix}/lib/microos/hotkeys.d
%{_prefix}/lib/microos/hotkeys.d/microemu.conf
%dir %{_prefix}/lib/microos/hotkeys.d/steam.conf.d
%{_prefix}/lib/microos/hotkeys.d/steam.conf.d/50-microemu.conf
%dir %{_prefix}/lib/microos/hotkeys.d/microdap.conf.d
%{_prefix}/lib/microos/hotkeys.d/microdap.conf.d/50-microemu.conf
%{_userunitdir}/microemu-*.service
%{_userunitdir}/gamescope-session-plus@microemu.service.d/
%{_datadir}/gamescope-session-plus/sessions.d/microemu
%{_datadir}/wayland-sessions/microemu.desktop
%dir %{_datadir}/microset
%dir %{_datadir}/microset/schema.d
%{_datadir}/microset/schema.d/50-microemu.json
%{_datadir}/microemu/
%{_datadir}/licenses/%{name}/art-book-next.txt
%{_datadir}/licenses/%{name}/art-book-next-speaker.txt
%{_datadir}/licenses/%{name}/slang-shaders/
%{_datadir}/licenses/%{name}/retro-crisis/
