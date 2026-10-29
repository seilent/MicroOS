# inputplumber patches

The RPM builds the upstream commit in `SOURCE.env` with `patches/` on top, crates vendored with `cargo vendor --locked`
from the unpatched tree (the patches add no crate and leave `Cargo.lock` as is). `%check` runs the `ssc` unit tests,
`dbus::polkit_test` (upstream's check that every `check_polkit` id is in the `.policy`, and `0002`'s), the `0003`
tests and the `0004` translator tests. A test filter that matches nothing still passes, so `%check` first lists each
filter's tests and fails when one lists fewer than the count in the spec.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| 0001 feat(source): add Qualcomm SSC IMU source | mine, my Armada 0005 rebased onto 0.82.0. Not derived from ShadowBlip/InputPlumber PR #590 (Gianni Spadoni, libssc over FastRPC): no shared code beyond InputPlumber's own source device template. The SSC wire format (QRTR service 400, QMI SSC control and report messages, the protobuf message ids and fields) is the one libssc (Dylan Van Assche) documents; the code is written fresh in Rust | The accelerometer and gyro sit behind the SLPI Sensor Core, not IIO | `drivers::ssc` tests on messages captured from the PM2: lookup and `NEW_SERVER`, SUID, enable and disable requests byte for byte, response result, SUID and config events, the 1022 event ignored, status 0 samples dropped, accel and gyro samples rotated by the PM2 mount matrix into `Vector3`, motion filter, driver suspend and resume state, backoff, the stream plan and the PM2 `config.imu` block |
| 0002 fix(dbus): check polkit on the FilteredEvents setter | mine, written new | The `FilteredEvents` setter on `CompositeDevice` has no `check_polkit`, so any caller on the system bus can filter the pad's events. New action `org.shadowblip.Input.CompositeDevice.SetFilteredEvents`, `allow_any` no, `allow_inactive` no, `allow_active` `auth_admin` | upstream's `check_polkit_policies` finds the new id in the `.policy`; `check_polkit_in_interface_setters` fails when an `async fn set_` in an `#[interface]` block under `src/dbus/interface/` has no `check_polkit` (it fails on the unpatched setter); `tests/pkg-inputplumber.sh` checks the defaults |
| 0003 fix(manager): adopt virtual event devices only from bluetooth uhid | mine, written new | A virtual evdev node is adopted only when it is on the Bluetooth bus and under `/devices/virtual/misc/uhid/` (BLE pads through bluez). Upstream also adopts any uinput node on bus 0005 and four Sunshine names plus `MSI WMI hotkeys`, which any process with `/dev/uinput` can fake. `/dev/uhid` is root only. Classic Bluetooth pads sit under the hci device, are not virtual and are adopted as before; the hidraw path is unchanged | `input::manager::tests` on `adopts_virtual_event` (path, udev `ID_BUS`, `id/bustype`): uinput dropped with `ID_BUS` bluetooth, with bustype 0005 only and on USB; uhid adopted with `ID_BUS` bluetooth and with bustype 0005 only; uhid dropped with no bus and on USB. The classic Bluetooth path (`is_virtual()` false) has no unit test; it is covered only on the test day with a real pad |
| 0004 fix(translator): radial joystick dead zone from the source axis flat | mine, written new | The right stick never rests (`ABS_Z` 0 to 754, `ABS_RZ` 0 to 2978, about 320 changes per second per axis) and upstream forwards every change to every target. A stick pair (a `multi_source` mapping with one ABS `joystick_x` and one ABS `joystick_y` source, distinct codes, no `axis_direction`, an implemented target, ABS info with a `flat` above 0 and `flat` plus twice the `fuzz` under half the travel from center) starts inside the zone, reads 0 while its radius stays within `flat` (the larger of the two axes, 4095 of 32767 on the PM2), leaves only above `flat` plus twice the `fuzz` (the larger of the two) and then passes the source values unchanged. Both axes go out as one `Vector2` at `SYN_REPORT`, and an unchanged value is dropped. Every other mapping runs upstream's code | `input::event::evdev::translator::tests`: the measured rest values emit nothing; a pair starts inside; the edges one count off `flat` and off `flat` plus twice `fuzz`; the larger `flat` and the larger `fuzz` of the two axes; a pair with `flat` plus twice `fuzz` just under half the travel from center; `fuzz` 0; the y source listed first; values outside the zone equal upstream's; one event per report; a value pending across reads; separate state per stick and per mapping; the value read at open; a chord on a pair code takes that code's events as upstream does; upstream's output for `flat` 0, a single axis, REL axes, one code twice, `axis_direction`, a chord, a second mapping on a pair code, an unimplemented target, no ABS info, an empty range, a `flat` and a `flat` plus twice `fuzz` of half the travel from center, triggers, buttons and IMU; `tests/pkg-inputplumber.sh` fails when the SRPM lacks `0004` |

The RPM leaves out `modules-load.d/inputplumber-hrtimer.conf` (the kernel has no IIO software trigger) and
`dbus-1/system-services/org.shadowblip.InputPlumber.service` (an example file upstream does not install).

`50-microos-inputplumber.rules` replaces upstream's `org.shadowblip.InputPlumber.rules` (YES to every
`org.shadowblip.Input*` and `org.shadowblip.Output*` action for groups `inputplumber` and `wheel`). For `micro` it
grants `SetTargetDevices`, `SetInterceptMode` and `ForceFeedback.Rumble` and denies every other `allow_any` no action;
other users get the `.policy` defaults. `tests/pkg-inputplumber.sh` fails when an `allow_any` no action is in neither
list, and evaluates the rule in `node` over every action id.

`0003` adopts a uhid node on the Bluetooth bus without checking its address against a connected bluez device (the
hidraw path does); it relies on `/dev/uhid` staying root only, which `tests/image.sh` checks (no udev rule names
`uhid`).

Known upstream bug, not patched: `CompositeDevice.SendEvent` calls `blocking_write_send_event` from an async handler
(`src/dbus/interface/composite_device.rs:283`, `src/input/composite_device/client.rs:469`), which panics InputPlumber
with `Cannot block the current thread from within a runtime`; the call times out after 25 s. Upstream issue #260
("SendEvent dbus call doesn't return", open). Only root can call it on MicroOS and no root caller does.
