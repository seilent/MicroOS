# MicroOS

A bootc image for the AYANEO Pocket MICRO 2, built on Fedora (`registry.fedoraproject.org/fedora-bootc:44`).

Sessions: Steam game mode, ES-DE, MicroDAP and a Hyprland desktop. Pocket MICRO 2 only.

CI builds the `testing` channel, `ghcr.io/seilent/microos:testing`, from `main`, and `ghcr.io/seilent/microos:dev-<sha>`
from other branches, each with an SD card image as a workflow artifact.

## microSD Format

After the Format confirm in Settings > Storage, release A, then hold it for 1 s within 15 s.
A MicroOS card formats the same way, except the one the PM2 is running from.

## Bootloader

A first install from stock Android needs the ROCKNIX ABL before MicroOS boots. `rocknix_abl/README` on the card has
the steps.

On a running PM2, `sudo microos-abl status` shows the shipped ABL and both slots. When an image ships a newer one,
`sudo microos-abl update <sha256>` with the hash from `status` backs up both slots and writes them. The backup goes
to `rocknix_abl/SM8250/microos-backup/` on the ESP of the install that runs it, internal or microSD. A boot that has
not confirmed refuses.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Components taken from other projects keep their own license and are listed
in [CREDITS.md](CREDITS.md).

MicroOS is not provided or supported by the Fedora Project. Official Fedora is available at
[fedoraproject.org](https://fedoraproject.org/). Steam is a trademark of Valve. MicroOS is not affiliated
with Valve or AYANEO.
