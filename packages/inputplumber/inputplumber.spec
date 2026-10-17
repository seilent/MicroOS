%{!?commit:%{error:commit is not defined}}
%global debug_package %{nil}

Name:           inputplumber
Version:        0.82.0
Release:        1%{?dist}.microos
Summary:        Input routing and control daemon
License:        GPL-3.0-or-later
URL:            https://github.com/ShadowBlip/InputPlumber
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        %{name}-%{version}-vendor.tar.zst
Source2:        50-microos-inputplumber.rules
Patch0:         0001-feat-source-add-qualcomm-ssc-imu-source.patch
Patch1:         0002-fix-dbus-check-polkit-on-the-filteredevents-setter.patch
Patch2:         0003-fix-manager-adopt-virtual-event-devices-only-from-bluetooth-uhid.patch
Vendor:         MicroOS
BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  clang-devel
BuildRequires:  systemd-devel
BuildRequires:  kernel-headers
BuildRequires:  systemd-rpm-macros
Requires:       polkit

%description
InputPlumber from ShadowBlip: combines input devices into composite devices
and emulates gamepads, keyboards and mice over uinput and uhid.

%prep
%autosetup -n InputPlumber-%{commit} -p1 -a 1

%build
%ifarch aarch64
export RUSTFLAGS="${RUSTFLAGS:-} -Ctarget-feature=+fp16,+dotprod,+rcpc"
%endif
cargo build --release --offline --frozen

%check
%ifarch aarch64
export RUSTFLAGS="${RUSTFLAGS:-} -Ctarget-feature=+fp16,+dotprod,+rcpc"
%endif
cargo test --release --offline --frozen --lib -- ssc dbus::polkit_test input::manager::tests

%install
install -D -m 755 target/release/inputplumber %{buildroot}%{_bindir}/inputplumber
mkdir -p %{buildroot}%{_prefix}
cp -a rootfs/usr/. %{buildroot}%{_prefix}/
install -D -m 644 %{SOURCE2} %{buildroot}%{_datadir}/polkit-1/rules.d/50-microos-inputplumber.rules
chmod -R go-w %{buildroot}

%post
%systemd_post inputplumber.service inputplumber-suspend.service

%preun
%systemd_preun inputplumber.service inputplumber-suspend.service

%postun
%systemd_postun inputplumber.service inputplumber-suspend.service

%files
%license LICENSE
%{_bindir}/inputplumber
%{_datadir}/dbus-1/system.d/org.shadowblip.InputPlumber.conf
%{_unitdir}/inputplumber.service
%{_unitdir}/inputplumber-suspend.service
%{_udevhwdbdir}/59-inputplumber.hwdb
%{_udevhwdbdir}/60-inputplumber-autostart.hwdb
%{_udevrulesdir}/55-8bitdo-u2-controller.rules
%{_udevrulesdir}/60-inputplumber-uaccess.rules
%{_udevrulesdir}/90-inputplumber-autostart.rules
%{_udevrulesdir}/99-inputplumber-device-setup.rules
%{_datadir}/inputplumber/
%{_datadir}/polkit-1/actions/org.shadowblip.InputPlumber.policy
%{_datadir}/polkit-1/rules.d/50-microos-inputplumber.rules
%exclude %{_datadir}/polkit-1/rules.d/org.shadowblip.InputPlumber.rules
%exclude %{_modulesloaddir}/inputplumber-hrtimer.conf
%exclude %{_datadir}/dbus-1/system-services/org.shadowblip.InputPlumber.service
