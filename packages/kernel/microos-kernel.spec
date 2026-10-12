%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           microos-kernel
Version:        %{kversion}
Release:        1%{?dist}.microos
Summary:        Linux kernel for the AYANEO Pocket MICRO 2
License:        GPL-2.0-only WITH Linux-syscall-note
URL:            https://github.com/seilent/MicroOS
Vendor:         MicroOS
ExclusiveArch:  aarch64
AutoReqProv:    no
Requires(post): kmod
Provides:       kernel = %{version}-%{release}
Provides:       kernel-core = %{version}-%{release}
Provides:       kernel-modules = %{version}-%{release}
Provides:       kernel-modules-core = %{version}-%{release}
Provides:       kernel-uname-r = %{kver}
Provides:       kernel-core-uname-r = %{kver}
Provides:       kernel-modules-uname-r = %{kver}
Provides:       kernel-modules-core-uname-r = %{kver}

%description
Linux %{kver}: raw arm64 Image as vmlinuz, modules and the Pocket MICRO 2
device tree, from one build.

%install
cp -a %{stage}/. %{buildroot}/

%post
/usr/sbin/depmod -a %{kver}

%files
%license /usr/share/licenses/microos-kernel/LICENSE.kernel
/usr/lib/modules/%{kver}
