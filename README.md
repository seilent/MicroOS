# MicroOS

A bootc image for the AYANEO Pocket MICRO 2, built on Fedora (`registry.fedoraproject.org/fedora-bootc:44`).

Sessions: Steam game mode, ES-DE, MicroDAP and a niri desktop. Pocket MICRO 2 only.

CI builds the `testing` channel, `ghcr.io/seilent/microos:testing`, from `main`, and `ghcr.io/seilent/microos:dev-<sha>`
from other branches, each with an SD card image as a workflow artifact.

## microSD Format

After the Format confirm in Settings > Storage, release A, then hold it for 1 s within 15 s.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Components taken from other projects keep their own license and are listed
in [CREDITS.md](CREDITS.md).

MicroOS is not provided or supported by the Fedora Project. Official Fedora is available at
[fedoraproject.org](https://fedoraproject.org/). Steam is a trademark of Valve. MicroOS is not affiliated
with Valve or AYANEO.
