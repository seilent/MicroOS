# gamescope patches

The RPM is Fedora's `gamescope.spec` (f44 `a846be4c`) with the source swapped to OGC `3.16.31-ogc2` (`76a1563a`).
Spec changes: Source0 and URL point at OGC, Version 3.16.31, Release `.microos`, no debuginfo, reshade and vkroots
commits come from `SOURCE.env` (same commits as the OGC tag's submodules and Fedora's spec).

| Patch | Origin | Author |
|---|---|---|
| `Allow-to-use-system-wlroots.patch` | Fedora `rpms/gamescope` `e1f0954` | František Zatloukal |
| `Use-system-stb-glm.patch` | Fedora `rpms/gamescope` `b5a75d5` | František Zatloukal |
| `0003-pace-the-non-vrr-fps-limit-on-time.patch` | mine | seilent |
| `0004-latch-done-commits-in-commit-order.patch` | mine | seilent |
| `0005-release-the-kms-device-under-the-wlserver-lock.patch` | mine | seilent |
| `0009-publish-the-applied-fps-limit-on-the-root-windows.patch` | mine | seilent |

The first two are Fedora packaging patches, not sent upstream. `stb.pc` is from Fedora `rpms/gamescope` `e2cc884` (Neal Gompa).

`0003` paces the FPS limit without VRR on time instead of every Nth vblank: a frame goes out at the vblank nearest
its target, 1/limit after the last one. Limits that do not divide the refresh are capped too (1,2 or 2,3 vblank
alternation). VRR is unchanged. `%check` runs `tests/test_utils_frame_limit.cpp`.

`0004` latches done commits in commit order. Two FIFO commits whose fences signal together can reach the done list
newest first; the newest latched and took the older one out of the queue unshown. A frame generation layer presenting
two images per game frame lost about 40% of them.

`0005` releases the KMS device under the wlserver lock. At exit `finish_drm` closes the device through libseat on the
logind D-Bus connection while the wlserver thread dispatches the same connection. Both threads read it at once:
gamescope crashed in `sd_bus` on a session switch, and the close can wait out the 25 s D-Bus timeout (Valve
gamescope issue 2287).

`0009` publishes the FPS limit the frame limiter applies as `GAMESCOPE_FPS_LIMIT_FEEDBACK` (CARDINAL, 0 for no limit) on
every Xwayland root, written when it changes and on each root as its server starts. Steam's quick access frame limit
arrives over `gamescope_control` and never shows in `GAMESCOPE_FPS_LIMIT`.

Fedora's `0001-cstdint.patch` is not carried: reshade `696b14cd` already includes `<cstdint>` in
`source/effect_token.hpp` (reshade `5c8b8f09`).
