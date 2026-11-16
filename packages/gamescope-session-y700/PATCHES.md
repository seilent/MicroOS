# gamescope-session patches

`gamescope-session` applies `patches/` on top of the upstream commit in `SOURCE.env`. `gamescope-session-steam` builds
as is.

| Patch | Origin | Why on the Y700 | Test |
|---|---|---|---|
| 0001 device-quirks: add Lenovo Legion Y700 (2025) | mine, written for MicroOS | panel on `DSI-1`, portrait panel turned to landscape with `ORIENTATION=right`, `GAMESCOPE_STARTUP_TIMEOUT=30`; matched on the DT model `Lenovo Legion Y700 (2025) / TB321FU` | `tests/session.sh` |
| 0002 gamescope-session-plus: `GAMESCOPE_STARTUP_TIMEOUT` | mine, written for MicroOS | test images start gamescope on one CPU (`maxcpus=1`), where the fixed 5 s wait can kill the first session; the default stays 5 | `tests/session.sh` (ready after 7 s) |

`gamescope-session-steam` leaves out `jupiter-biosupdate`, `steamos-update`, `steamos-select-branch`,
`steamos-session-select`, `steamos-polkit-helpers/` and `org.chimeraos.update.policy`. MicroOS ships its own.
