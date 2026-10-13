%{!?commit:%{error:commit is not defined}}
%global debug_package %{nil}

Name:           steamos-manager
Version:        26.4.1^git20260916.8e2883d
Release:        1%{?dist}.microos
Summary:        SteamOS Manager system and session daemons
License:        MIT
URL:            https://gitlab.steamos.cloud/holo/steamos-manager
Source0:        %{url}/-/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        %{name}-%{commit}-vendor.tar.zst
Source2:        com.steampowered.SteamOSManager1.conf
Patch0001:      0001-wifi-keep-networkmanager-up-when-a-backend-is-missing.patch
Patch0002:      0002-manager-user-take-cpuscaling1-from-a-remote.patch
Patch0003:      0003-remote-relay-signals-from-the-first-registration.patch
Patch0004:      0004-remote-keep-the-remoteinterface1-lock-off-object-server-changes.patch
Vendor:         MicroOS
BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  clang-devel
BuildRequires:  systemd-devel
BuildRequires:  glib2-devel
BuildRequires:  speech-dispatcher-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  dbus-daemon
BuildRequires:  gsettings-desktop-schemas

%description
SteamOS Manager from Valve: the system daemon and the session daemon Steam
talks to for device settings, and steamosctl.

%prep
%autosetup -n %{name}-%{commit} -p1 -a 1

%build
%ifarch aarch64
export RUSTFLAGS="${RUSTFLAGS:-} -Ctarget-feature=+fp16,+dotprod,+rcpc"
%endif
cargo build --release --offline --frozen

%check
%ifarch aarch64
export RUSTFLAGS="${RUSTFLAGS:-} -Ctarget-feature=+fp16,+dotprod,+rcpc"
%endif
cargo test --offline --frozen -p steamos-manager --lib -- wifi:: systemd:: manager::user::

%install
install -D -m 755 target/release/steamos-manager %{buildroot}%{_prefix}/lib/steamos-manager
install -D -m 755 target/release/steamosctl %{buildroot}%{_bindir}/steamosctl
install -D -m 644 -t %{buildroot}%{_datadir}/steamos-manager/devices data/devices/*.toml
install -D -m 644 data/platform.toml %{buildroot}%{_datadir}/steamos-manager/platform.toml
install -d %{buildroot}%{_datadir}/steamos-manager/remotes.d %{buildroot}%{_sysconfdir}/steamos-manager/remotes.d
install -D -m 644 -t %{buildroot}%{_datadir}/dbus-1/interfaces data/interfaces/com.steampowered.SteamOSManager1.xml
install -D -m 644 -t %{buildroot}%{_datadir}/dbus-1/system-services data/system/com.steampowered.SteamOSManager1.service
install -D -m 644 -t %{buildroot}%{_datadir}/dbus-1/system.d %{SOURCE2}
install -D -m 644 -t %{buildroot}%{_datadir}/dbus-1/services data/user/com.steampowered.SteamOSManager1.service
install -D -m 644 -t %{buildroot}%{_unitdir} data/system/steamos-manager.service
install -D -m 644 -t %{buildroot}%{_userunitdir} data/user/steamos-manager.service data/user/steamos-manager-session-cleanup.service

%post
%systemd_post steamos-manager.service
%systemd_user_post steamos-manager.service steamos-manager-session-cleanup.service

%preun
%systemd_preun steamos-manager.service
%systemd_user_preun steamos-manager.service steamos-manager-session-cleanup.service

%postun
%systemd_postun steamos-manager.service
%systemd_user_postun steamos-manager.service steamos-manager-session-cleanup.service

%files
%license LICENSE
%{_prefix}/lib/steamos-manager
%{_bindir}/steamosctl
%dir %{_datadir}/steamos-manager
%{_datadir}/steamos-manager/devices/
%{_datadir}/steamos-manager/platform.toml
%dir %{_datadir}/steamos-manager/remotes.d
%dir %{_sysconfdir}/steamos-manager
%dir %{_sysconfdir}/steamos-manager/remotes.d
%{_datadir}/dbus-1/interfaces/com.steampowered.SteamOSManager1.xml
%{_datadir}/dbus-1/system-services/com.steampowered.SteamOSManager1.service
%{_datadir}/dbus-1/system.d/com.steampowered.SteamOSManager1.conf
%{_datadir}/dbus-1/services/com.steampowered.SteamOSManager1.service
%{_unitdir}/steamos-manager.service
%{_userunitdir}/steamos-manager.service
%{_userunitdir}/steamos-manager-session-cleanup.service
