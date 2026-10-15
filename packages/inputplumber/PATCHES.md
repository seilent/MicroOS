# inputplumber patches

The RPM builds the upstream commit in `SOURCE.env` with `patches/` on top, crates vendored with `cargo vendor --locked`
from the unpatched tree (the patch adds no crate and leaves `Cargo.lock` as is). `%check` runs the `ssc` unit tests.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| 0001 feat(source): add Qualcomm SSC IMU source | mine, my Armada 0005 rebased onto 0.82.0. Not derived from ShadowBlip/InputPlumber PR #590 (Gianni Spadoni, libssc over FastRPC): no shared code beyond InputPlumber's own source device template. The SSC wire format (QRTR service 400, QMI SSC control and report messages, the protobuf message ids and fields) is the one libssc (Dylan Van Assche) documents; the code is written fresh in Rust | The accelerometer and gyro sit behind the SLPI Sensor Core, not IIO | `drivers::ssc` tests on messages captured from the PM2: lookup and `NEW_SERVER`, SUID, enable and disable requests byte for byte, response result, SUID and config events, the 1022 event ignored, status 0 samples dropped, accel and gyro samples rotated by the PM2 mount matrix into `Vector3`, motion filter, driver suspend and resume state, backoff, the stream plan and the PM2 `config.imu` block |

The RPM leaves out `modules-load.d/inputplumber-hrtimer.conf` (the kernel has no IIO software trigger) and
`dbus-1/system-services/org.shadowblip.InputPlumber.service` (an example file upstream does not install).
