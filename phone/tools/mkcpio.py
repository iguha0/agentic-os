#!/usr/bin/env python3
"""mkcpio.py — build a gzip'd newc initramfs from a directory, root-owned,
with device nodes, without needing root or the cpio binary.

  mkcpio.py <srcdir> <out.cpio.gz> [--node path:mode:major:minor ...]

Copyright (C) Indrajit Guha — AGPL-3.0
"""
import argparse
import gzip
import os
import stat


def entry(name, mode, data=b"", rdev=(0, 0), ino=[0]):
    ino[0] += 1
    nb = name.encode() + b"\0"
    hdr = "070701" + "".join("%08X" % v for v in (
        ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0))
    out = hdr.encode() + nb
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data + b"\0" * ((4 - len(data) % 4) % 4)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("src")
    p.add_argument("out")
    p.add_argument("--node", action="append", default=[])
    a = p.parse_args()

    blob = b""
    for root, dirs, files in os.walk(a.src):
        dirs.sort()
        rel = os.path.relpath(root, a.src)
        if rel != ".":
            blob += entry(rel, stat.S_IFDIR | 0o755)
        for f in sorted(files):
            path = os.path.join(root, f)
            name = os.path.normpath(os.path.join(rel, f))
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                blob += entry(name, stat.S_IFLNK | 0o777, os.readlink(path).encode())
            else:
                perm = 0o755 if st.st_mode & 0o111 else 0o644
                blob += entry(name, stat.S_IFREG | perm, open(path, "rb").read())
        for d in dirs:  # symlinked dirs are listed in dirs but not walked
            path = os.path.join(root, d)
            if os.path.islink(path):
                blob += entry(os.path.normpath(os.path.join(rel, d)),
                              stat.S_IFLNK | 0o777, os.readlink(path).encode())
    for n in a.node:
        path, mode, major, minor = n.split(":")
        blob += entry(path.lstrip("/"), stat.S_IFCHR | int(mode, 8), rdev=(int(major), int(minor)))
    blob += entry("TRAILER!!!", 0)
    with gzip.open(a.out, "wb", compresslevel=9) as f:
        f.write(blob)


if __name__ == "__main__":
    main()
