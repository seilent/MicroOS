%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}

Name:           gamescope-session
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        Gamescope session launcher and common session files
License:        MIT
URL:            https://github.com/OpenGamingCollective/gamescope-session
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       gamescope

%description
gamescope-session-plus from the Open Gaming Collective: the session launcher,
its systemd user units and the device quirks it reads.

%prep
%autosetup -n %{name}-%{commit}

%build

%install
mkdir -p %{buildroot}%{_prefix}
cp -a usr/. %{buildroot}%{_prefix}/
install -d %{buildroot}%{_datadir}/gamescope-session-plus/sessions.d
chmod -R go-w %{buildroot}

%files
%license LICENSE
%{_bindir}/export-gpu
%{_bindir}/gamescope-session-plus
%{_userunitdir}/gamescope-session-plus@.service
%{_userunitdir}/gamescope-session.target
%{_datadir}/gamescope-session-plus/
%dir %{_datadir}/gamescope/scripts/50-custom
%{_datadir}/gamescope/scripts/50-custom/50-disable-explicit-sync.lua
