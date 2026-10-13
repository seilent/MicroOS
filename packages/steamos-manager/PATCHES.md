# steamos-manager patches

The RPM builds upstream main `8e2883d` (`v26.4.1-12-g8e2883d`, `SOURCE.env`) with `patches/` on top, crates vendored
with `cargo vendor --locked`. `%check` runs the `wifi`, `systemd` and `manager::user` unit tests.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| 0001 wifi: keep NetworkManager up when a backend is missing | mine | Steam asks for iwd and the image has no `iwd`. iwd is refused with `iwd is not installed` while `iwd.service` does not exist, setting the current backend is a no op, a missing unit is skipped on stop and disable, and NetworkManager is started again on every path | `wifi::test::test_set_wifi_backend_iwd_not_installed`, `test_set_nm_settings_restart_no_iwd`, `test_set_wifi_backend_unchanged`; the mock systemd reads `not-found` for a missing unit and fails `DisableUnitFiles` of it |
| 0002 manager/user: take CpuScaling1 from a remote | mine | `microos-powerd` owns the CPU governor. With a `[CpuScaling1]` remote section the local CpuScaling1 is not registered and Steam's governor writes go to powerd | `manager::user::test::remote_cpu_scaling1_autoadd`, `remote_cpu_scaling1_local_without_config` |
| 0003 remote: relay signals from the first registration | mine | steamos-manager caches remote properties and updates them only from their signals, and powerd is up before steamos-manager. The relay starts on every registration, transient remotes included, and replaces a running one. A relay that fails to start fails `configure` and the user daemon start | `manager::user::test::remote_battery_charge_limit1_relay_signals`: one `PropertiesChanged` per change for a remote owned before startup, and one after the remote loses and takes its name again |
| 0004 remote: keep the RemoteInterface1 lock off object server changes | mine | zbus holds the object server lock in a Properties `Get` while it waits for the interface lock. A remote loading or unloading held the RemoteInterface1 lock while it added or removed its interface, so a `Get` on RemoteInterface1 in that window hung every property of the user daemon after a `microos-powerd` restart. Load and unload take the remote out under the lock and register or unregister it without the lock | `manager::user::test::remote_shared_name_reowned`: three remotes on one bus name, 8 clients reading `RemoteInterfaces`, the name dropped and taken 20 times, `RemoteInterfaces` lists all three within 2 s each time |

The RPM installs files by name. It leaves out `sddm.service.d/reset-oneshot-boot.conf`, `orca.service` and
`steamos-manager-configure-cecd.service`, and ships its own `com.steampowered.SteamOSManager1.conf` instead of
upstream's: root owns the name and may send anything. `wheel` may send only what the user daemon calls for the
interfaces MicroOS exports: Introspectable, Peer, Properties `Get` and `GetAll`, RootManager `ReloadConfig`
(Manager2), `SetWifiBackend` (WifiBackend1), `SetWifiPowerManagementState` (WifiPowerManagement1), `UpdateBios`
(UpdateBios1) and Job1 for the mirrored job. Every other RootManager method and Properties `Set` are denied, so a game
running as `micro` cannot call them directly. Everyone else is denied. `tests/steamos-manager-policy.sh` checks it on
a private dbus-daemon.
