# MicroOS

Bootc images for the AYANEO Pocket MICRO 2 and the Lenovo Legion Y700 (2025, TB321FU), built on Fedora
(`registry.fedoraproject.org/fedora-bootc:44`). Files both devices ship are at the root, the rest are in
`devices/<device>/`.

## Pocket MICRO 2

Sessions: Steam game mode, ES-DE, MicroDAP and a Hyprland desktop.

CI builds the `testing` channel, `ghcr.io/seilent/microos:testing`, from `main`, and `ghcr.io/seilent/microos:dev-<sha>`
from other branches, each with an SD card image as a workflow artifact.

### microSD Format

After the Format confirm in Settings > Storage, release A, then hold it for 1 s within 15 s.
A MicroOS card formats the same way, except the one the PM2 is running from.

### Bootloader Update

At shutdown, a ROCKNIX ABL newer than the one on the device shows a prompt. Release A, then hold it for 1 s within 15 s.
Three declines stop the prompt until `microos-abl reset`. Both slots are backed up to
`rocknix_abl/SM8250/microos-backup/` on the ESP, the card's on an SD install. A first install from stock Android needs
the ABL before MicroOS boots; `rocknix_abl/README` on the card has those steps.

## Legion Y700

It boots from slot b, next to the stock Android on slot a. Sessions: Steam game mode, Android and a Hyprland
desktop (illogical-impulse). MicroSet > System > Boot into picks the one it boots. Switch to Desktop in Steam's
power menu and Steam OS in the desktop's session menu switch between them. The desktop config is in `~/.config/hypr`,
`~/.config/quickshell/ii` and `~/.config/matugen`; an update replaces only the files you have not changed.

CI builds the `testing` channel, `ghcr.io/seilent/microos-y700:testing`, from `main`,
`ghcr.io/seilent/microos-y700:dev-<sha>` from other branches, and moves `branch-<name>` to each green `y700-*` branch
head.

### Updates

The device checks its channel daily and after each boot, pulls the update and writes it to `boot_b`. The next reboot
applies it. Updates that change the kernel, the initramfs or the boot image wait for `sudo microos-update`.

The channel is `/var/lib/microos/update-channel`: `testing` (the default), `stable` or `branch-<name>`.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Components taken from other projects keep their own license and are listed
in [CREDITS.md](CREDITS.md).

MicroOS is not provided or supported by the Fedora Project. Official Fedora is available at
[fedoraproject.org](https://fedoraproject.org/). Steam is a trademark of Valve. MicroOS is not affiliated
with Valve, AYANEO or Lenovo.
