# mangohud patches

The RPM is Fedora's `mangohud.spec` (f44 `83471e05`) with the source swapped to MangoHud `v0.8.4` (`992103e4`).
Spec changes: Version 0.8.4, Release `.microos`, Vendor MicroOS, no debuginfo, Source0 by commit from `SOURCE.env`,
the `v0.8.4` wraps (Vulkan-Headers and Vulkan-Utility-Libraries 1.4.346, imgui 1.91.6, implot 0.16 and its wrapdb
patch) as Sources with the in tree `subprojects/packagefiles` overlays copied over them in `%prep`,
`BuildRequires: unzip`, bundled Provides for the four wraps, `-Dmangoplot=disabled` and no `mangoplot` subpackage,
`-Dwith_fex=false`, no `README.Fedora.md`, no `rm libimgui.a` (`v0.8.4` installs no static imgui), no `%forgemeta`
and no `%changelog`.

| Patch | Origin | Author |
|---|---|---|
| `0001-gpu_fdinfo-fix-msm_dpu-sensor-detection.patch` | MangoHud PR 2073 `0be0cacafb86` | Victoria Brekenfeld |
| `0002-gpu_fdinfo-fixup-driver-mismatch-for-msm_dpu.patch` | MangoHud PR 2073 `0b2badb56f87` | Victoria Brekenfeld |
| `0003-gpu_fdinfo-read-msm_dpu-core-clock-from-devfreq.patch` | backport of MangoHud `eb72a0048f43` | flightlessmango, Antonino Maniscalco |
| `0004-file_utils-handle-exception-from-directory_iterator.patch` | MangoHud `e2d0db030ef0` | flightlessmango, Gabe Rowe |
| `0005-gpu_fdinfo-handle-denied-proc-fd-iteration.patch` | backport of MangoHud `16d783b5d29a` | flightlessmango |
| `0006-battery-find-batteries-by-their-sysfs-type.patch` | backport of MangoHud `e5d31119b521` (PR 2166) | fromdisposition |
| `0007-mangoapp-throttle-overlay-to-one-render-per-game-frame.patch` | MangoHud `2c1dc5283c04` | Matthew Schwartz |
| `0008-gpu_fdinfo-read-msm_dpu-resident-memory.patch` | backport of MangoHud `f7d778a5e702` | 17314642 |
| `0009-gpu_fdinfo-show-msm_dpu-game-memory-as-vram.patch` | mine | seilent |
| `0010-params-drop-the-frame-timing-graph-from-preset-2.patch` | mine | seilent |
| `0011-params-hide-msm_dpu-gpu-rows-without-a-source.patch` | backport of MangoHud `7c95b67656d6`, `e57fa15`, `abc561d` | flightlessmango, Matthew Schwartz |
| `0012-params-hide-more-msm_dpu-rows-without-a-source.patch` | mine | seilent |
| `0013-mangoapp-skip-the-window-resize-until-the-size-is-known.patch` | mine | seilent |
| `0014-notify-proper-cleanup.patch` | MangoHud `0c16392297ff` | flightlessmango |
| `0015-gpu_fdinfo-wake-the-paused-thread-on-stop.patch` | mine | seilent |

`0001`, `0002`, `0004`, `0007` and `0014` are the upstream commits as is; `0001` and `0002` keep PR 2073's order.
PR 2073 was closed unmerged; the other commits are on master after `v0.8.4`.

The backports are mine and keep the upstream author:

- `0003`: `eb72a00` reads the first `/sys/class/devfreq/*.gpu/cur_freq` in `mangohud-next`. Here `GPU_fdinfo` opens it
  for `msm_dpu` and `get_gpu_clock` divides the Hz value by 1e6. No `ends_with`, `v0.8.4` builds as C++17.
- `0005`: the try/catch of `16d783b` around the `/proc/<pid>/fdinfo` walk in `GPU_fdinfo::find_fd`, catching ghc's
  `fs::filesystem_error`.
- `0006`: the `type` and `scope` check of `e5d3111`, plus `#include "file_utils.h"` for `read_line`. `v0.8.4` has no
  `/run/deckardcharger` lookup and no `battery_count_max`, so those parts are left out; the count is bounded by the
  two entries of `battPath` instead.
- `0011`: the Steam Frame block of `7c95b67` (GPU voltage, power limit, efficiency, power), with the `gpu_fan` row of
  `e57fa15` and the preset 4 `ram_temp` row of `abc561d`. It matches the `msm_dpu` driver instead of the `sm8650-dpu`
  modalias; master's power-monitor check of `f88ef00` is left out, the PM2 has no `/run/power-monitor`.
- `0008`: `f7d778a` reads `drm-resident-memory` for msm_dpu in `mangohud-next`. Here `GPU_fdinfo` sets it as the
  msm_dpu memory key.

Mine:

- `0009`: msm has no device wide GPU memory counter readable without root (master reads the `gpu_mem_total`
  tracepoint), so VRAM shows the game's `drm-resident-memory`.
- `0010`: preset 2 is the horizontal bar, wider than the PM2 screen with the frame timing graph in it.
- `0012`: msm_dpu has no CPU power, GPU memory clock, junction or memory temperature either, so presets hide those
  rows too and show the battery draw.
- `0013`: mangoapp started hidden has no output size until a frame message arrives, so the horizontal preset skips
  the window resize while the size is 0, and the size is stored before the render thread is woken.
- `0015`: the GPU thread paused while mangoapp is hidden never woke at exit, so the join hung. The destructor, pause
  and resume set their flag under the lock before the notify, the thread holds the lock only for its waits, and the
  wait between samples is a timed wait that a stop ends at once.
