# plymouth patches

The RPM is Fedora's `plymouth.spec` (f44 `1541161`, 24.004.60-24) with its 23 patch files (42 commits) and three more.
Spec changes: Release `24%{?dist}.microos` instead of `%autorelease`, no `%changelog` section and no spec comments,
Source0 and Source1 from the Fedora lookaside by sha512 (`SOURCE.env`), Source2 `charge.plymouth` from the same commit,
no debuginfo, Vendor MicroOS.

Fedora patches in spec order. The upstream column is the commit on plymouth `main`
(gitlab.freedesktop.org/plymouth/plymouth) and its merge request. Where the file's `From` line carries a branch commit
that is not on `main`, it is given first, then the commit that landed.

| Patch | Upstream | Author |
|---|---|---|
| `0001-Revert-src-Hide-console-text-when-splash-is-requeste.patch` | Fedora only, `e6f09b0570` reverts `48881ba2ef` | Adam Williamson |
| `0001-ply-boot-splash-Set-unbuffered-input-when-creating-a.patch` | `10ac8d2dc9` (MR 303) | n3rdopolis |
| `0001-ply-device-manager-Revert-Fall-back-to-text-plugin-i.patch` | `4a8c0a4231`, landed as `c06ee92baf` (MR 319) | Hans de Goede |
| `plymouth-24.004.60-immediately-probe-simpledrm.patch` | `64379c1100`, `1c3ff0338c`, `19d49a42fc`, `188a4393b1`, `9096b304f6`, `eb5abda0c2`, `8c0d596503`, `2f8b64ea4c`, `12fdedb4ef` (MR 323) | Hans de Goede |
| `0001-renderers-Do-not-assume-all-keyboards-have-LEDs.patch` | `709f21e801` (MR 304) | n3rdopolis |
| `0001-ply-keymap-icon-Make-Dvorak-check-case-insensitive.patch` | `f443234585` (MR 341) | Hans de Goede |
| `0001-ply-keymap-icon-Fix-falling-back-to-label-plugin-whe.patch` | `f17285bbaa`, landed as `98419849ef` (MR 358) | Hans de Goede |
| `0001-label-freetype-fix-fallback-not-working-when-fc-matc.patch` | `792fe7474a` (MR 302), `90ae4ab42e` (MR 337) | Ferdinand Bachmann |
| `plymouth-24.004.60-device-scale-fixes.patch` | `acf97c7367` (MR 307), `3b8e918479` (MR 308) | Daniel van Vugt |
| | `53fcd2ec13`, `d83c3c486c`, `77f5082016`, landed as `0a4fd6b1d2`, `2123f7b9c6`, `1421a9f65f` (MR 343) | Hans de Goede |
| `plymouth-24.004.60-use_simpledrm-config.patch` | `5784c0e2c6`, `0aa6607e21`, `fd744373d4`, `022108fa05`, `2215e66c41`, `83926cec4c`, `21e6f602e1`, landed as `bf80db4ec3`, `443e580162`, `6620904dff`, `e7fc6cb5c4`, `c1e0070d47`, `f23b07e5b5`, `61e471762e` (MR 342) | Hans de Goede |
| `0001-drm-Check-for-NULL-terminal-in-watch_input_device.patch` | `d20b1be527` (MR 344) | Daniel van Vugt |
| `0001-drm-Fix-crash-when-terminal-fd-is-still-1-after-reco.patch` | `21ea1e9742`, landed as `4f53b52f54` (MR 354) | Hans de Goede |
| `0001-Add-UseSimpledrmNoLuks-config-file-keyword.patch` | `ad4813c972`, landed as `d7b43158c9` (MR 355) | Hans de Goede |
| `0001-Fix-keymap-and-capslock-icon-on-displays-on-second-G.patch` | `c31399689b`, landed as `29e5112d30` (MR 356) | Hans de Goede |
| `0001-two-step-Remove-at-the-end-of-passphrase-prompt-belo.patch` | `289c8187e3`, landed as `b828874199` (MR 357) | Hans de Goede |
| `0002-two-step-Add-some-padding-between-text-entry-field-a.patch` | `05ab2139d2`, landed as `9f72b7c34d` (MR 357) | Hans de Goede |
| `0001-utils-Don-t-lose-log-level-when-silencing-kmsg.patch` | `2446472f9a` (MR 347) | Adrian Vovk |
| `0002-details-Suppress-kernel-s-own-kmsg-console-output.patch` | `6d7b3c3342` (MR 347) | Adrian Vovk |
| `0003-kmsg-reader-Seek-to-the-end-of-the-ringbuffer.patch` | `a53065d0ce` (MR 347) | Adrian Vovk |
| `0001-renderers-Only-call-ply_terminal_set_unbuffered_inpu.patch` | `5c10072a97` (MR 298) | nerdopolis |
| `0001-Display-the-first-specified-XKBLAYOUT-as-the-active-.patch` | `b609687e8d` (MR 369) | n3rdopolis |
| `0001-ply-device-manager-Fix-race-in-fb_device_has_drm_dev.patch` | Fedora only, `36f45f9d11`, not on `main` `03fe0c1f97`, no MR | Hans de Goede |
| `0001-ply-keyboard-Fix-hang-on-read-of-incomplete-terminal.patch` | `45655f12fa` (pushed to `main`, no MR) | D Scott Phillips |

| Patch | Origin | Author |
|---|---|---|
| `0001-close-the-fb-on-retain-to-keep-the-image-on-the-screen.patch` | SteamOS plymouth `22.02.122-7.7` `0010-Close-the-FB-if-possible-to-keep-the-image-on-the-sc.patch`, rebased by me | Robert Beckett (Collabora) |
| `0002-script-draw-sprites-on-display-message.patch` | mine | seilent |
| `0003-drm-skip-retain-on-a-head-without-a-scanout-buffer.patch` | mine | seilent |

`0001` adds a renderer `retain` hook. On `quit --retain-splash` the drm plugin closes each head's scanout FB with
`drmModeCloseFB`, so the frame stays on the plane after plymouthd exits. It is not upstream. MR 173 (Simon Ser) and
MR 313 (Jocelyn Falempe) use CloseFB too, in different code. I rebased it onto 24.004.60 with Fedora's patches; the
code is unchanged, only the context moved in `ply-renderer-plugin.h`, `ply-renderer.h`, `main.c` and the drm
interface table.

`0002` refreshes the script plugin's sprites in the display message handler, so a sprite change from
`Plymouth.SetDisplayMessageFunction` is on the screen before `plymouth display-message` returns.

`0003` skips the retain on a head with no scanout buffer (a head never flushed, such as a DP head plugged in
late). `0001` asserts there and plymouthd aborted in the middle of the quit.

SteamOS `0011-retain-splash-when-quitting.patch` is not carried. It only changes `plymouth-quit.service` to
`quit --retain-splash`. My plymouth-quit drop-in replaces that ExecStart, and `microos-splash-quit` runs
`quit --retain-splash`.
