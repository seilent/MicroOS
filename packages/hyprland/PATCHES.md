# Hyprland stack patches

The RPM builds Hyprland v0.57.0 from its release asset with the rest of the stack from pinned commit archives
(`SOURCE.env`). glaze is header only and ships as `glaze-devel`. hyprcursor is an own build because Fedora's links
`libhyprutils.so.6` while this stack ships SOVERSION 13.

hyprwayland-scanner v0.4.6 is a build only component: it stays in the build stage and its files are deleted from
`%{buildroot}`, so no RPM carries it. Fedora 44 ships 0.4.2, which emits an empty vtable for the core wayland.xml that
GCC 16 rejects.

No patches: every component builds from its pinned tree as it stands.
