%{!?client_version:%{error:client_version is not defined}}
%{!?runtime_version:%{error:runtime_version is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%global _binary_payload w0.ufdio

Name:           microos-steam-seed
Version:        %{client_version}
Release:        1%{?dist}.microos
Summary:        Steam client and arm64 runtime seed for the MicroOS home
License:        LicenseRef-Steam-Subscriber-Agreement
URL:            https://store.steampowered.com/about/
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no
Source0:        steam-seed.tar.zst
Source1:        steam_subscriber_agreement.txt

%description
Steam client %{client_version} (steamdeck_stable, linuxarm64) and Steam Runtime
%{runtime_version} (steamrt3c arm64), installed and packed as a home tree.
MicroOS extracts it into the home of the first login.

%install
install -Dm644 %{SOURCE0} %{buildroot}%{_datadir}/microos-seed/steam-seed.tar.zst
echo "%{client_version} %{runtime_version}" > %{buildroot}%{_datadir}/microos-seed/steam-seed.version
chmod 644 %{buildroot}%{_datadir}/microos-seed/steam-seed.version
install -Dm644 %{SOURCE1} %{buildroot}%{_datadir}/licenses/%{name}/steam_subscriber_agreement.txt

%files
%license %{_datadir}/licenses/%{name}/steam_subscriber_agreement.txt
%dir %{_datadir}/microos-seed
%{_datadir}/microos-seed/steam-seed.tar.zst
%{_datadir}/microos-seed/steam-seed.version
