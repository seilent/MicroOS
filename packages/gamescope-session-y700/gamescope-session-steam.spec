%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}

Name:           gamescope-session-steam
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        Steam session for gamescope-session-plus
License:        MIT
URL:            https://github.com/OpenGamingCollective/gamescope-session-steam
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Vendor:         MicroOS
BuildArch:      noarch
Requires:       gamescope-session

%description
Steam Big Picture session for gamescope-session-plus from the Open Gaming
Collective.

%prep
%autosetup -n %{name}-%{commit}

%build

%install
mkdir -p %{buildroot}%{_prefix}
cp -a usr/. %{buildroot}%{_prefix}/
chmod -R go-w %{buildroot}

%files
%license LICENSE
%{_bindir}/steam-http-loader
%{_datadir}/applications/gamescope-mimeapps.list
%{_datadir}/applications/steam_http_loader.desktop
%{_datadir}/gamescope-session-plus/sessions.d/steam
%{_datadir}/wayland-sessions/gamescope-session-steam.desktop
%exclude %{_bindir}/jupiter-biosupdate
%exclude %{_bindir}/steamos-polkit-helpers
%exclude %{_bindir}/steamos-select-branch
%exclude %{_bindir}/steamos-session-select
%exclude %{_bindir}/steamos-update
%exclude %{_datadir}/polkit-1/actions/org.chimeraos.update.policy
