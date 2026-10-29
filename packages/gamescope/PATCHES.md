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
| `0006-catch-up-to-the-next-vblank-in-one-step.patch` | OGC `72ad630c018e` (first in `3b3cced787e3`), the step only, adapted to ogc2 | Matthew Schwartz |
| `0007-add-a-virtual-output.patch` | mine | seilent |
| `0008-add-gamescopevirtual.patch` | mine | seilent |

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

`0006` moves the vblank target to the next refresh in one step instead of one refresh per loop pass. Nothing marks a
vblank while no frame is presented, so after an idle screen the loop walks every refresh since the last frame, on the
panel too. ogc2 has the loop again after the merge `76a1563a83f8`.

`0007` adds a virtual output: a display gamescope composites into its own PipeWire node, `gamescope-virtual-output`
(NV12 in shared memory first, BT.601 full range, then BGRx). The node sets `node.name`: PipeWire otherwise names a
stream's node after the binary, `gamescope` like the main node, and WirePlumber matches `target.object` only on
`node.name` or `object.path`. It is picked like a DP monitor once its stream runs, by `--prefer-output` (`VIRTUAL-1`),
never while Steam forces the internal display, and the panel goes off while it is current. A client holds it with
the private `gamescope_virtual_output` protocol for as long as its object lives;
`gamescopectl virtual_output 1280x800@60:172x108` sets it by hand and `virtual_output off` takes it back from anyone.
A touch that starts on the PM2 touchscreen while the virtual output is current is dropped, its lift included. The
virtual output is an external display, so with `touch_external_display_trackpad` on and the touch mode on passthrough,
every touch, the tablet's included, works as a trackpad while it is current. The `gamescope` node no longer offers
NV12 over DMA-BUF, which never allocated and crashed gamescope, and skips a frame while its last buffer still waits
for the PipeWire thread instead of losing that buffer for good. While the virtual node has no free buffer, the
PipeWire thread retries the dequeue once a refresh and repaints as soon as one is free: PipeWire 1.6.10 tells a
driving stream nothing when the consumer returns a buffer, it only drops the buffer's busy count
(`pw_stream_dequeue_buffer`, `src/pipewire/stream.c` 2569-2577), so an idle screen would keep a stale frame. `%check`
runs `tests/test_virtual_output.cpp` and the stale anchor case 0007 adds to `tests/test_utils_vblank_schedule.cpp`.

`0008` adds `gamescopevirtual WxH@Hz:WxH` (size, refresh rate, size in mm). It connects to the Wayland display in
`GAMESCOPE_WAYLAND_DISPLAY`, `gamescope-0` when that is unset, holds a virtual output while its stdin is open, prints
`node <id> gamescope-virtual-output` once the stream exists, and exits 0 on stdin EOF, 1 when the Wayland connection
goes, 2 on a usage error or a missing global and 3 on `failed`, with `failed: <reason>` on stderr.

Fedora's `0001-cstdint.patch` is not carried: reshade `696b14cd` already includes `<cstdint>` in
`source/effect_token.hpp` (reshade `5c8b8f09`).
