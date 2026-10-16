%{!?pipewire_evr:%{error:pipewire_evr is not defined}}
%{!?koji_key:%{error:koji_key is not defined}}
%global debug_package %{nil}
%global spaversion 0.2
%global pipewire_version %{lua:print((rpm.expand("%{pipewire_evr}"):match("^([^-]+)-")))}
%global pipewire_release %{lua:print((rpm.expand("%{pipewire_evr}"):match("^[^-]+-(.+)$")))}

Name:           pipewire-codec-aptx
Version:        %{pipewire_version}
Release:        %{pipewire_release}.microos
Summary:        PipeWire Bluetooth aptX and aptX HD codec
License:        MIT
URL:            https://pipewire.org/
Source0:        https://kojipkgs.fedoraproject.org/packages/pipewire/%{pipewire_version}/%{pipewire_release}/data/signed/%{koji_key}/src/pipewire-%{pipewire_evr}.src.rpm
Vendor:         MicroOS
BuildRequires:  cpio
BuildRequires:  gcc
BuildRequires:  meson >= 0.59.0
BuildRequires:  pkgconfig(bluez)
BuildRequires:  pkgconfig(dbus-1)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(libfreeaptx)
BuildRequires:  pkgconfig(sbc)
Requires:       pipewire-libs%{?_isa} = %{pipewire_evr}

%description
The aptX and aptX HD codec module of the PipeWire bluez5 plugin, built from
Fedora's pipewire source package at the version the image installs.

%prep
%setup -q -T -c -n pipewire-%{pipewire_version}
rpm2cpio %{SOURCE0} | cpio -idm --quiet
if ls *.patch >/dev/null 2>&1; then
  echo "pipewire-%{pipewire_evr}.src.rpm carries patches, apply them here" >&2
  exit 1
fi
tar -xzf pipewire-%{pipewire_version}.tar.gz --strip-components=1 --no-same-permissions

%build
%meson --auto-features=disabled -D examples=disabled -D bluez5=enabled -D bluez5-codec-aptx=enabled \
  -D session-managers=[]
%meson_build spa-codec-bluez5-aptx

%install
install -Dpm755 %{_vpath_builddir}/spa/plugins/bluez5/libspa-codec-bluez5-aptx.so \
  %{buildroot}%{_libdir}/spa-%{spaversion}/bluez5/libspa-codec-bluez5-aptx.so

%files
%license COPYING LICENSE
%{_libdir}/spa-%{spaversion}/bluez5/libspa-codec-bluez5-aptx.so
