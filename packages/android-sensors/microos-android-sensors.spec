%global debug_package %{nil}

Name:           microos-android-sensors
Version:        1
Release:        1%{?dist}.microos
Summary:        Sensors HAL for the Waydroid guest from the ADSP sensor hub
License:        GPL-2.0-or-later
URL:            https://github.com/seilent/MicroOS
Source0:        %{name}.tar.gz
Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  kernel-headers
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(libgbinder)
BuildRequires:  pkgconfig(libglibutil)
Requires:       waydroid

%description
waydroid-sensord, an android.hardware.sensors@1.0 ISensors service on the
Waydroid hwbinder node. The Waydroid container manager finds it on PATH,
starts it before the container and kills it at the stop, and the guest then
runs without the stub sensors HAL. It lists an accelerometer and a light
sensor fed from the ADSP sensor hub's accel and ambient_light streams over
QRTR, and answers system_server (uid 1000) only. SIGUSR1 feeds the guest a
test accelerometer turned a quarter turn further each time, SIGUSR2 goes back
to the sensor hub.

%prep
%autosetup -n %{name}

%build
%make_build CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"

%install
install -Dpm755 waydroid-sensord %{buildroot}%{_bindir}/waydroid-sensord

%files
%license LICENSE
%{_bindir}/waydroid-sensord
