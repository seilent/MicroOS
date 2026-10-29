# gamescope-session patches

`gamescope-session` applies `patches/` on top of the upstream commit in `SOURCE.env`. `gamescope-session-steam` builds
as is.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| 0001 device-quirks: add AYANEO Pocket MICRO 2 | mine, written for MicroOS | panel on `DSI-1`, `FAKE_OUTPUT_MM=177x118` for the UI scale, `GAMESCOPE_STARTUP_TIMEOUT=15`; matched on the DT model `AYANEO Pocket MICRO 2` | `tests/session.sh` |
| 0002 gamescope-session-plus: `GAMESCOPE_STARTUP_TIMEOUT` | mine; Armada's 0002 (Radical) raised the fixed 5 s wait to 15 s | a cold SD boot needs about 5 s before gamescope answers on its socket, so the 5 s wait killed the first session; the default stays 5 | `tests/session.sh` (ready after 7 s) |
| 0003 gamescope-session-plus: publish the Wayland display | mine, written for MicroOS | units outside the session (the USB display part) need the session's own gamescope socket, which the launcher exports only to the processes it starts; a session switch can run two gamescopes at once | `tests/session.sh` (the file while the client runs, gone after it exits, a stale one removed when gamescope never answers, a blocked write that still starts the client) |

0003 writes `GAMESCOPE_WAYLAND_DISPLAY=<name>` to `$XDG_RUNTIME_DIR/gamescope-session-plus/<session>.env` once gamescope
answers on the startup socket: the dir 0755 and the file 0644, both owned by the user, the file written with `mktemp` in
that dir and renamed over the old one (`mv -fT`). The file is removed before gamescope starts and after the client
exits. A stop by signal (`systemctl --user stop` sends SIGTERM to the launcher, which has no trap) or a crash skips the
last removal; the MicroOS drop-in `gamescope-session-plus@.service.d/30-microos-wayland-display.conf` removes the file
at the unit's start and stop. A failed write (the dir blocked, the file name taken by a directory) leaves no temp file
and the session starts as before.

`gamescope-session-steam` leaves out `jupiter-biosupdate`, `steamos-update`, `steamos-select-branch`,
`steamos-session-select`, `steamos-polkit-helpers/` and `org.chimeraos.update.policy`. MicroOS ships its own.
