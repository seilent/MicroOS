%global debug_package %{nil}

Summary: Graphical Boot Animation and Logger
Name: plymouth
Version: 24.004.60
Release: 24%{?dist}.microos
License: GPL-2.0-or-later
URL: http://www.freedesktop.org/wiki/Software/Plymouth

Source0: %{name}-%{version}.tar.bz2
Source1: spinner-update.tar.gz
Source2: charge.plymouth

Patch: 0001-Revert-src-Hide-console-text-when-splash-is-requeste.patch
Patch: 0001-ply-boot-splash-Set-unbuffered-input-when-creating-a.patch
Patch: 0001-ply-device-manager-Revert-Fall-back-to-text-plugin-i.patch
Patch: plymouth-24.004.60-immediately-probe-simpledrm.patch
Patch: 0001-renderers-Do-not-assume-all-keyboards-have-LEDs.patch
Patch: 0001-ply-keymap-icon-Make-Dvorak-check-case-insensitive.patch
Patch: 0001-ply-keymap-icon-Fix-falling-back-to-label-plugin-whe.patch
Patch: 0001-label-freetype-fix-fallback-not-working-when-fc-matc.patch
Patch: plymouth-24.004.60-device-scale-fixes.patch
Patch: plymouth-24.004.60-use_simpledrm-config.patch
Patch: 0001-drm-Check-for-NULL-terminal-in-watch_input_device.patch
Patch: 0001-drm-Fix-crash-when-terminal-fd-is-still-1-after-reco.patch
Patch: 0001-Add-UseSimpledrmNoLuks-config-file-keyword.patch
Patch: 0001-Fix-keymap-and-capslock-icon-on-displays-on-second-G.patch
Patch: 0001-two-step-Remove-at-the-end-of-passphrase-prompt-belo.patch
Patch: 0002-two-step-Add-some-padding-between-text-entry-field-a.patch
Patch: 0001-utils-Don-t-lose-log-level-when-silencing-kmsg.patch
Patch: 0002-details-Suppress-kernel-s-own-kmsg-console-output.patch
Patch: 0003-kmsg-reader-Seek-to-the-end-of-the-ringbuffer.patch
Patch: 0001-renderers-Only-call-ply_terminal_set_unbuffered_inpu.patch
Patch: 0001-Display-the-first-specified-XKBLAYOUT-as-the-active-.patch
Patch: 0001-ply-device-manager-Fix-race-in-fb_device_has_drm_dev.patch
Patch: 0001-ply-keyboard-Fix-hang-on-read-of-incomplete-terminal.patch
Patch: 0001-close-the-fb-on-retain-to-keep-the-image-on-the-screen.patch
Patch: 0002-script-draw-sprites-on-display-message.patch
Patch: 0003-drm-skip-retain-on-a-head-without-a-scanout-buffer.patch

Vendor: MicroOS

BuildRequires: meson
BuildRequires: system-logos
BuildRequires: gcc libtool git
BuildRequires: pkgconfig(libdrm)
BuildRequires: pkgconfig(libevdev)
BuildRequires: pkgconfig(libudev)
BuildRequires: pkgconfig(xkeyboard-config)
BuildRequires: kernel-headers
BuildRequires: libpng-devel
BuildRequires: libxslt, docbook-style-xsl
BuildRequires: pkgconfig(gtk+-3.0)
BuildRequires: pango-devel >= 1.21.0
BuildRequires: cairo-devel
BuildRequires: gettext-devel
BuildRequires: systemd
BuildRequires: systemd-rpm-macros

Requires: %{name}-core-libs = %{version}-%{release}
Requires: %{name}-scripts = %{version}-%{release}
Requires: xkeyboard-config
Suggests: logrotate

%description
Plymouth provides an attractive graphical boot animation in
place of the text messages that normally get shown.  Text
messages are instead redirected to a log file for viewing
after boot.

%package system-theme
Summary: Plymouth default theme
Requires: plymouth(system-theme) = %{version}-%{release}

%description system-theme
This meta-package tracks the current distribution default theme.

%package core-libs
Summary: Plymouth core libraries

%description core-libs
This package contains the core libraries used by Plymouth.

%package graphics-libs
Summary: Plymouth graphics libraries
Requires: %{name}-core-libs = %{version}-%{release}
Requires: system-logos

%description graphics-libs
This package contains the libraries used by graphical Plymouth splashes.

%package devel
Summary: Libraries and headers for writing Plymouth splash plugins
Requires: %{name} = %{version}-%{release}
Requires: pkgconfig

%description devel
This package contains the libraries and headers needed to develop
3rd party splash plugins for Plymouth.

%package scripts
Summary: Plymouth related scripts
Requires: findutils, coreutils, gzip, cpio, dracut
Requires: xkeyboard-config
Requires: %{name} = %{version}-%{release}

%description scripts
This package contains scripts that help integrate Plymouth with
the system.

%package plugin-label
Summary: Plymouth label plugin
Requires: %{name} = %{version}-%{release}
Requires: %{name}-graphics-libs = %{version}-%{release}

%description plugin-label
This package contains the label control plugin for Plymouth.
It provides the ability to render text on graphical boot splashes.

%package plugin-script
Summary: Plymouth "script" plugin
Requires: %{name} = %{version}-%{release}
Requires: %{name}-graphics-libs = %{version}-%{release}

%description plugin-script
This package contains the "script" boot splash plugin for
Plymouth. It features an extensible boot splash language that
allows writing new plugins as scripts, simplifying the process
of designing custom boot splash themes.

%package plugin-fade-throbber
Summary: Plymouth "Fade-Throbber" plugin
Requires: %{name} = %{version}-%{release}
Requires: %{name}-graphics-libs = %{version}-%{release}

%description plugin-fade-throbber
This package contains the "Fade-In" boot splash plugin for
Plymouth. It features a centered image that fades in and out
while other images pulsate around during system boot up.

%package plugin-space-flares
Summary: Plymouth "space-flares" plugin
Requires: %{name} = %{version}-%{release}
Requires: %{name}-graphics-libs = %{version}-%{release}
Requires: plymouth-plugin-label = %{version}-%{release}

%description plugin-space-flares
This package contains the "space-flares" boot splash plugin for
Plymouth. It features a corner image with animated flares.

%package plugin-two-step
Summary: Plymouth "two-step" plugin
Requires: %{name} = %{version}-%{release}
Requires: %{name}-graphics-libs = %{version}-%{release}
Requires: plymouth-plugin-label = %{version}-%{release}
Obsoletes: %{name}-plugin-throbgress < %{version}-%{release}

%description plugin-two-step
This package contains the "two-step" boot splash plugin for
Plymouth. It features a two phased boot process that starts with
a progressing animation synced to boot time and finishes with a
short, fast one-shot animation.

%if ! 0%{?rhel}
%package theme-charge
Summary: Plymouth "Charge" plugin
Requires: %{name}-plugin-two-step = %{version}-%{release}
Requires: fedora-logos-classic
Requires(post): plymouth-scripts

%description theme-charge
This package contains the "charge" boot splash theme for
Plymouth. It features the shadowy hull of a Fedora logo charge up and
and finally burst into full form.
%endif

%package theme-fade-in
Summary: Plymouth "Fade-In" theme
Requires: %{name}-plugin-fade-throbber = %{version}-%{release}
Requires(post): plymouth-scripts

%description theme-fade-in
This package contains the "Fade-In" boot splash theme for
Plymouth. It features a centered logo that fades in and out
while stars twinkle around the logo during system boot up.

%package theme-script
Summary: Plymouth "Script" plugin
Requires: %{name}-plugin-script = %{version}-%{release}
Requires(post): plymouth-scripts

%description theme-script
This package contains the "script" boot splash theme for
Plymouth. It it is a simple example theme the uses the "script"
plugin.

%package theme-solar
Summary: Plymouth "Solar" theme
Requires: %{name}-plugin-space-flares = %{version}-%{release}
Requires(post): plymouth-scripts

%description theme-solar
This package contains the "Solar" boot splash theme for
Plymouth. It features a blue flamed sun with animated solar flares.

%package theme-spinfinity
Summary: Plymouth "Spinfinity" theme
Requires: %{name}-plugin-two-step = %{version}-%{release}
Requires(post): plymouth-scripts

%description theme-spinfinity
This package contains the "Spinfinity" boot splash theme for
Plymouth. It features a centered logo and animated spinner that
spins in the shape of an infinity sign.

%package theme-spinner
Summary: Plymouth "Spinner" theme
Requires: %{name}-plugin-two-step = %{version}-%{release}
%if 0%{?rhel} > 9
Requires: redhat-mono-vf-fonts
Requires: redhat-text-vf-fonts
%else
Requires: font(cantarell) font(cantarelllight)
%endif
Requires(post): plymouth-scripts
Provides: plymouth(system-theme) = %{version}-%{release}

%description theme-spinner
This package contains the "spinner" boot splash theme for
Plymouth. It features a small spinner on a dark background.

%prep
%autosetup -p1 -a 1
sed -i -e 's/spinner/bgrt/g' src/plymouthd.defaults
echo UseSimpledrmNoLuks=1 >> src/plymouthd.defaults

%if 0%{?rhel} > 9
find -type f -exec sed -i -e 's/Cantarell/Red Hat Text/g' {} \;
%endif

%build
%meson -Dtracing=true  \
       -Dlogo=%{_datadir}/pixmaps/system-logo-white.png \
       -Dbackground-start-color-stop=0x0073B3           \
       -Dbackground-end-color-stop=0x00457E             \
       -Dbackground-color=0x3391cd
%meson_build

%install
%meson_install

%find_lang %{name}
find $RPM_BUILD_ROOT -name '*.la' -delete

mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/lib/plymouth

%if ! 0%{?rhel}
mkdir -p $RPM_BUILD_ROOT%{_datadir}/plymouth/themes/charge
cp %{SOURCE2} $RPM_BUILD_ROOT%{_datadir}/plymouth/themes/charge
cp $RPM_BUILD_ROOT%{_datadir}/plymouth/themes/glow/{box,bullet,entry,lock}.png $RPM_BUILD_ROOT%{_datadir}/plymouth/themes/charge
%endif

rm -rf $RPM_BUILD_ROOT%{_datadir}/plymouth/themes/glow

%ldconfig_scriptlets core-libs

%ldconfig_scriptlets graphics-libs

%if ! 0%{?rhel}
%postun theme-charge
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 0 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "charge" ]; then
        %{_sbindir}/plymouth-set-default-theme --reset
    fi
fi
%endif

%postun theme-fade-in
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 0 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "fade-in" ]; then
        %{_sbindir}/plymouth-set-default-theme --reset
    fi
fi

%postun theme-solar
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 0 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "solar" ]; then
        %{_sbindir}/plymouth-set-default-theme --reset
    fi
fi

%postun theme-spinfinity
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 0 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "spinfinity" ]; then
        %{_sbindir}/plymouth-set-default-theme --reset
    fi
fi

%post theme-spinner
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 2 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "charge" ]; then
        %{_sbindir}/plymouth-set-default-theme bgrt
    fi
fi

%postun theme-spinner
export PLYMOUTH_PLUGIN_PATH=%{_libdir}/plymouth/
if [ $1 -eq 0 ]; then
    if [ "$(%{_sbindir}/plymouth-set-default-theme)" == "bgrt" -o \
         "$(%{_sbindir}/plymouth-set-default-theme)" == "spinner" ]; then
        %{_sbindir}/plymouth-set-default-theme --reset
    fi
fi

%files -f %{name}.lang
%license COPYING
%doc AUTHORS README.md
%dir %{_datadir}/plymouth
%dir %{_datadir}/plymouth/themes
%dir %{_datadir}/plymouth/themes/details
%dir %{_datadir}/plymouth/themes/text
%dir %{_datadir}/plymouth/themes/tribar
%dir %{_libexecdir}/plymouth
%dir %{_localstatedir}/lib/plymouth
%dir %{_libdir}/plymouth/renderers
%dir %{_sysconfdir}/plymouth
%config(noreplace) %{_sysconfdir}/plymouth/plymouthd.conf
%config(noreplace) %{_sysconfdir}/logrotate.d/bootlog
%{_sbindir}/plymouthd
%{_libexecdir}/plymouth/plymouthd-fd-escrow
%{_bindir}/plymouth
%{_libdir}/plymouth/details.so
%{_libdir}/plymouth/text.so
%{_libdir}/plymouth/tribar.so
%{_datadir}/plymouth/themes/details/details.plymouth
%{_datadir}/plymouth/themes/text/text.plymouth
%{_datadir}/plymouth/themes/tribar/tribar.plymouth
%{_datadir}/plymouth/plymouthd.defaults
%{_localstatedir}/spool/plymouth
%{_mandir}/man?/*
%ghost %attr(0644,root,root) %{_localstatedir}/lib/plymouth/boot-duration
%{_unitdir}/

%files devel
%{_libdir}/libply.so
%{_libdir}/libply-splash-core.so
%{_libdir}/libply-boot-client.so
%{_libdir}/libply-splash-graphics.so
%{_libdir}/pkgconfig/ply-splash-core.pc
%{_libdir}/pkgconfig/ply-splash-graphics.pc
%{_libdir}/pkgconfig/ply-boot-client.pc
%{_libdir}/plymouth/renderers/x11*
%{_includedir}/plymouth-1

%files core-libs
%{_libdir}/libply.so.*
%{_libdir}/libply-splash-core.so.*
%{_libdir}/libply-boot-client.so.*
%dir %{_libdir}/plymouth

%files graphics-libs
%{_libdir}/libply-splash-graphics.so.*
%{_libdir}/plymouth/renderers/drm*
%{_libdir}/plymouth/renderers/frame-buffer*

%files scripts
%{_sbindir}/plymouth-set-default-theme
%{_libexecdir}/plymouth/plymouth-update-initrd
%{_libexecdir}/plymouth/plymouth-generate-initrd
%{_libexecdir}/plymouth/plymouth-populate-initrd

%files plugin-label
%{_libdir}/plymouth/label-freetype.so
%{_libdir}/plymouth/label-pango.so

%files plugin-script
%{_libdir}/plymouth/script.so

%files plugin-fade-throbber
%{_libdir}/plymouth/fade-throbber.so

%files plugin-space-flares
%{_libdir}/plymouth/space-flares.so

%files plugin-two-step
%{_libdir}/plymouth/two-step.so

%if ! 0%{?rhel}
%files theme-charge
%{_datadir}/plymouth/themes/charge
%endif

%files theme-fade-in
%{_datadir}/plymouth/themes/fade-in

%files theme-script
%{_datadir}/plymouth/themes/script

%files theme-solar
%{_datadir}/plymouth/themes/solar

%files theme-spinfinity
%{_datadir}/plymouth/themes/spinfinity

%files theme-spinner
%{_datadir}/plymouth/themes/bgrt
%{_datadir}/plymouth/themes/spinner

%files system-theme
