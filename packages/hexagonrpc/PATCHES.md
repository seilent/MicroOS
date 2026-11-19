# hexagonrpc patches

The RPM builds from the upstream commit in `SOURCE.env` with the patches below: the five commits of hexagonrpc PR 27
(unmerged, head `40e5041281`) as they are, then seven of mine.

| Patch | Origin | Author |
|---|---|---|
| `0001-hexagonfs-add-create-write-truncate-unlink-and-renam.patch` | PR 27 `518fdf0992` | Fady Ackad |
| `0002-apps_std-serve-fopen-fwrite-fsync-fremove-ftrunc-and.patch` | PR 27 `7543f33817` | Fady Ackad |
| `0003-listener-answer-unsupported-requests-and-fetch-input.patch` | PR 27 `f0dfd5095d` | Fady Ackad |
| `0004-rpcd_builder-map-the-registry-s-parent-directory-whe.patch` | PR 27 `7f2fc1d5af` | Fady Ackad |
| `0005-hexagonrpcd-fix-descriptor-lifetimes-and-the-write-p.patch` | PR 27 `40e5041281` | Fady Ackad |
| `0006-hexagonrpcd-iobuffer-decode-zero-length-input-buffer.patch` | mine | seilent |
| `0007-hexagonfs-refuse-.-above-an-assigned-search-director.patch` | mine | seilent |
| `0008-hexagonrpcd-apps_std-keep-the-root-and-search-direct.patch` | mine | seilent |
| `0009-hexagonrpcd-listener-match-buffer-counts-to-the-meth.patch` | mine | seilent |
| `0010-hexagonfs-mapped-report-the-write-bit-only-when-the-.patch` | mine | seilent |
| `0011-hexagonrpcd-sync-written-files-and-create-them-witho.patch` | mine | seilent |
| `0012-hexagonrpcd-apps_std-fflush-writes-no-output-buffer.patch` | mine | seilent |

The Y700 ADSP sensor PD writes its registry while it starts: it probes `registry/DIR` for writing, rewrites
`parsed_file_list.csv`, writes `fstempfile` beside the registry dir and renames it in, and sends writes over 256 bytes.
Upstream hexagonrpcd refuses writes and the PD publishes no sensors (hexagonrpc issue 19). The patches give mapped
directories create, write, truncate, unlink and rename, serve the matching `apps_std` methods, fetch input buffers over
256 bytes, and back `/persist/sensors/registry` with `<root>/sensors/persist/` when that directory exists. Writes reach
only what the daemon's user may write: on the Y700 that is the registry copy in `/run/microos/adsp`, on the PM2 nothing.

Mine make malformed requests fail instead of ending or crashing the daemon (a dead daemon leaves the sensor PD unusable
until a reboot) and keep read only trees as before:

- `0006`: a zero length input buffer decodes as empty, and every name check refuses an empty name.
- `0007`: `..` above an assigned search directory fails with EACCES, and a final `.` or `..` is refused for create,
  unlink and rename.
- `0008`: `fclose` and `closedir` refuse the root and the two search directory descriptors.
- `0009`: a request whose input or output buffer count differs from the method definition is declined.
- `0010`: `stat` reports a file writable only when the daemon can write it (`faccessat`), so a read only tree stats
  0444 and 0555 as upstream does.
- `0011`: `fsync` syncs, creates do not follow symlinks and use mode 0666 under the service umask.
- `0012`: `fflush` writes no output buffer.

The RPM leaves out the upstream systemd units (MicroOS starts hexagonrpcd from its own `microos-hexagonrpcd.service`)
and the `libhexagonrpc.so` link (no headers are installed upstream, so there is nothing to build against).
