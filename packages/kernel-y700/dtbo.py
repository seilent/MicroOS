#!/usr/bin/env python3
import struct
import sys

out, *dtbs = sys.argv[1:]
if not dtbs:
    sys.exit("usage: dtbo.py <out.img> <overlay.dtbo>...")
page = 4096
blobs = [open(p, "rb").read() for p in dtbs]
offset = 32 + 32 * len(blobs)
entries = b""
for b in blobs:
    entries += struct.pack(">8I", len(b), offset, 0, 0, 0, 0, 0, 0)
    offset += len(b)
header = struct.pack(">8I", 0xD7B7AB1E, offset, 32, 32, len(blobs), 32, page, 0)
img = header + entries + b"".join(blobs)
img += b"\0" * (-len(img) % page)
open(out, "wb").write(img)
