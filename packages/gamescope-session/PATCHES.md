# gamescope-session patches

`gamescope-session` applies `patches/` on top of the upstream commit in `SOURCE.env`. `gamescope-session-steam` builds
as is.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| 0001 device-quirks: add AYANEO Pocket MICRO 2 | mine, written for MicroOS | panel on `DSI-1`, `FAKE_OUTPUT_MM=177x118` for the UI scale, `GAMESCOPE_STARTUP_TIMEOUT=15`; matched on the DT model `AYANEO Pocket MICRO 2` | `tests/session.sh` |
| 0002 gamescope-session-plus: `GAMESCOPE_STARTUP_TIMEOUT` | mine; Armada's 0002 (Radical) raised the fixed 5 s wait to 15 s | a cold SD boot needs about 5 s before gamescope answers on its socket, so the 5 s wait killed the first session; the default stays 5 | `tests/session.sh` (ready after 7 s) |

`gamescope-session-steam` leaves out `jupiter-biosupdate`, `steamos-update`, `steamos-select-branch`,
`steamos-session-select`, `steamos-polkit-helpers/` and `org.chimeraos.update.policy`. MicroOS ships its own.
