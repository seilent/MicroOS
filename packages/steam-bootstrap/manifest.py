#!/usr/bin/env python3
import os
import re
import stat
import sys

NAME = re.compile(r"[A-Za-z0-9_.-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")


def die(msg):
    sys.exit(f"manifest.py: {msg}")


def packages(path, version):
    text = open(path, encoding="utf-8").read()
    found = re.search(r'"version"\s+"(\d+)"', text)
    if not found or found.group(1) != version:
        die(f"{path}: version {found.group(1) if found else 'missing'}, expected {version}")
    rows = []
    for name, body in re.findall(r'"(\w+)"\s*\{([^{}]*)\}', text):
        kv = dict(re.findall(r'"(\w+)"\s+"([^"\n]*)"', body))
        if "file" not in kv:
            continue
        row = [name, kv["file"], kv.get("size", ""), kv.get("sha2", ""), kv.get("zipvz", ""), kv.get("sha2vz", "")]
        if not NAME.fullmatch(row[1]) or not row[2].isdigit() or not SHA256.fullmatch(row[3]):
            die(f"{name}: bad file entry")
        if row[4] and (not NAME.fullmatch(row[4]) or not SHA256.fullmatch(row[5])):
            die(f"{name}: bad zipvz entry")
        rows.append(row)
    if not rows:
        die(f"{path}: no packages")
    for row in rows:
        print("\t".join(row))


def installed(path, root):
    entries = 0
    bad = []
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        m = re.fullmatch(r"(.+),(-?\d+);\d+;\d+", line)
        if not m:
            continue
        entries += 1
        rel, size = m.group(1), int(m.group(2))
        if rel.startswith("/") or ".." in rel.split("/"):
            bad.append(f"unsafe path {rel}")
            continue
        p = os.path.join(root, rel)
        try:
            st = os.lstat(p)
        except OSError:
            bad.append(f"missing {rel}")
            continue
        if size == -1 and not stat.S_ISDIR(st.st_mode):
            bad.append(f"not a directory {rel}")
        elif size == -2 and not stat.S_ISLNK(st.st_mode):
            bad.append(f"not a symlink {rel}")
        elif size >= 0 and (not stat.S_ISREG(st.st_mode) or st.st_size != size):
            bad.append(f"size {rel}: {st.st_size}, expected {size}")
    if not entries:
        die(f"{path}: no entries")
    for b in bad[:20]:
        print(b, file=sys.stderr)
    if bad:
        die(f"{path}: {len(bad)} of {entries} entries differ")
    print(f"{path}: {entries} entries match")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "packages":
        packages(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "installed":
        installed(sys.argv[2], sys.argv[3])
    else:
        die("usage: manifest.py packages <vdf> <version> | installed <manifest> <steamdir>")
