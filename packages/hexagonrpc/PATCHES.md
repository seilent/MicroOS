# hexagonrpc patches

None. The RPM builds from the upstream commit in `SOURCE.env` as is.

The RPM leaves out the upstream systemd units (MicroOS starts hexagonrpcd from its own `microos-hexagonrpcd.service`)
and the `libhexagonrpc.so` link (no headers are installed upstream, so there is nothing to build against).
