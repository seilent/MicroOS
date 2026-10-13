# inputplumber patches

None. The RPM builds from the upstream commit in `SOURCE.env` as is, crates vendored with `cargo vendor --locked`.

The RPM leaves out `modules-load.d/inputplumber-hrtimer.conf` (the kernel has no IIO software trigger) and
`dbus-1/system-services/org.shadowblip.InputPlumber.service` (an example file upstream does not install).
