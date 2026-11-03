%{!?abl_version:%{error:abl_version is not defined}}
%{!?abl_commit:%{error:abl_commit is not defined}}
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           rocknix-abl
Version:        %{abl_version}
Release:        1%{?dist}.microos
Summary:        ROCKNIX ABL for the Pocket MICRO 2 (SM8250)
License:        LicenseRef-rocknix-abl-no-license
URL:            https://github.com/ROCKNIX/abl
Source0:        rocknix-abl-v%{abl_version}.tar.gz
Source1:        rocknix-abl-%{abl_commit}.tar.gz
Source2:        manifest
Source3:        releases.tsv
Source4:        README
Source5:        backup_abl.sh
Source6:        flash_abl.sh
Source7:        restore_backup_abl.sh
Vendor:         MicroOS
BuildArch:      noarch
AutoReqProv:    no

%description
The ROCKNIX ABL %{abl_version} for the SM8250 in the Pocket MICRO 2, with the
releases MicroOS identifies and the scripts that back up and write either
partition from Android.

%prep
%setup -q -c -T
tar -xzf %{SOURCE1} --strip-components=1 --no-same-owner
tar -xzf %{SOURCE0} --strip-components=1 --wildcards --no-same-owner '*/abl_signed-SM8250.elf*'

%build

%check
test "$(sha256sum abl_signed-SM8250.elf | cut -d' ' -f1)" \
  = "$(sed -n 's/^MICROOS_ABL_SHA256=//p' %{SOURCE2})"

%install
abi=%{buildroot}%{_prefix}/lib/microos/abl
install -Dm644 abl_signed-SM8250.elf "$abi/abl_signed-SM8250.elf"
install -Dm644 abl_signed-SM8250.elf.sha256 "$abi/abl_signed-SM8250.elf.sha256"
install -Dm644 %{SOURCE2} "$abi/manifest"
install -Dm644 %{SOURCE3} "$abi/releases.tsv"
install -Dm644 %{SOURCE4} "$abi/esp/README"
install -Dm755 %{SOURCE5} "$abi/esp/backup_abl.sh"
install -Dm755 %{SOURCE6} "$abi/esp/flash_abl.sh"
install -Dm755 %{SOURCE7} "$abi/esp/restore_backup_abl.sh"

%files
%doc README.md
%dir %{_prefix}/lib/microos/abl
%{_prefix}/lib/microos/abl/abl_signed-SM8250.elf
%{_prefix}/lib/microos/abl/abl_signed-SM8250.elf.sha256
%{_prefix}/lib/microos/abl/manifest
%{_prefix}/lib/microos/abl/releases.tsv
%dir %{_prefix}/lib/microos/abl/esp
%{_prefix}/lib/microos/abl/esp/README
%{_prefix}/lib/microos/abl/esp/backup_abl.sh
%{_prefix}/lib/microos/abl/esp/flash_abl.sh
%{_prefix}/lib/microos/abl/esp/restore_backup_abl.sh
