# gamescope patches

The RPM is Fedora's `gamescope.spec` (f44 `a846be4c`) with the source swapped to OGC `3.16.31-ogc2` (`76a1563a`).
Spec changes: Source0 and URL point at OGC, Version 3.16.31, Release `.microos`, no debuginfo, reshade and vkroots
commits come from `SOURCE.env` (same commits as the OGC tag's submodules and Fedora's spec).

| Patch | Origin | Author |
|---|---|---|
| `Allow-to-use-system-wlroots.patch` | Fedora `rpms/gamescope` `e1f0954` | František Zatloukal |
| `Use-system-stb-glm.patch` | Fedora `rpms/gamescope` `b5a75d5` | František Zatloukal |

Both are Fedora packaging patches, not sent upstream. `stb.pc` is from Fedora `rpms/gamescope` `e2cc884` (Neal Gompa).

Fedora's `0001-cstdint.patch` is not carried: reshade `696b14cd` already includes `<cstdint>` in
`source/effect_token.hpp` (reshade `5c8b8f09`).
