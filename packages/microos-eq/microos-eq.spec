%global debug_package %{nil}

Name:           microos-eq
Version:        1
Release:        1%{?dist}.microos
Summary:        MicroOS EQ LADSPA plugin
License:        GPL-2.0-or-later AND BSD-3-Clause
URL:            https://github.com/seilent/MicroOS
Source0:        %{name}.tar.gz
Vendor:         MicroOS
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  ladspa-devel

%description
LADSPA plugin with the MicroOS EQ chain: label eq, a preamp and ten bands
designed at the graph rate, a new set swapped in with a warm start crossfade.

%prep
%autosetup -n %{name}

%build
%make_build CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"

%install
install -Dpm755 microos-eq.so %{buildroot}%{_libdir}/ladspa/microos-eq.so

%files
%license LICENSE LICENSE.BSD-3-Clause
%dir %{_libdir}/ladspa
%{_libdir}/ladspa/microos-eq.so
