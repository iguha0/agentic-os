#!/usr/bin/env python3
"""bootimg.py — inspect and repack Android boot images for PryzentOS.

PryzentOS keeps the phone's own kernel (the only thing that knows its screen,
touch and storage) and replaces everything else. This tool takes the stock
boot.img, keeps kernel / second stage / DTB / load addresses exactly as the
vendor shipped them, and swaps in the PryzentOS ramdisk.

Supports boot image header v0, v1, v2, v3 and v4, plus the 512-byte MediaTek
header found on older MediaTek phones. Pure Python 3, no dependencies.

  bootimg.py info   <boot.img>
  bootimg.py unpack <boot.img> <outdir>
  bootimg.py repack <stock-boot.img> --ramdisk <cpio.gz> -o <new.img>
                    [--cmdline "extra args"]
  bootimg.py create --kernel K --ramdisk R -o <new.img> [--version 0..4]
                    [--dtb D] [--cmdline C] [--mtk]       (testing / porting)

Copyright (C) Indrajit Guha — AGPL-3.0
"""
import argparse
import hashlib
import os
import struct
import sys

MAGIC = b"ANDROID!"
MTK_MAGIC = 0x58881688
MTK_HDR_SIZE = 512


def pad(n, page):
    return (page - (n % page)) % page


def pages(n, page):
    return (n + page - 1) // page


class BootImage:
    def __init__(self):
        self.version = 0
        self.page = 2048
        self.kernel = b""
        self.ramdisk = b""
        self.second = b""
        self.recovery_dtbo = b""
        self.dtb = b""
        self.signature = b""
        self.kernel_addr = self.ramdisk_addr = self.second_addr = 0
        self.tags_addr = 0
        self.dtb_addr = 0
        self.os_version = 0
        self.name = b""
        self.cmdline = b""
        self.extra_cmdline = b""
        self.recovery_dtbo_offset = 0

    # ── parsing ────────────────────────────────────────────────────────────
    @classmethod
    def parse(cls, data):
        off = data.find(MAGIC, 0, 4096)
        if off < 0:
            raise SystemExit("not an Android boot image (no ANDROID! magic)")
        data = data[off:]
        b = cls()
        b.version = struct.unpack_from("<I", data, 40)[0]
        if b.version > 4:
            # v0 images store the page size where newer ones keep the version.
            b.version = 0
        if b.version >= 3:
            (ks, rs, b.os_version, hdr_size) = struct.unpack_from("<4I", data, 8)
            b.cmdline = data[44:44 + 1536].rstrip(b"\0")
            sig_size = struct.unpack_from("<I", data, 1580)[0] if b.version == 4 else 0
            b.page = 4096
            o = b.page
            b.kernel = data[o:o + ks]; o += pages(ks, b.page) * b.page
            b.ramdisk = data[o:o + rs]; o += pages(rs, b.page) * b.page
            b.signature = data[o:o + sig_size]
            return b
        (ks, b.kernel_addr, rs, b.ramdisk_addr, ss, b.second_addr,
         b.tags_addr, b.page) = struct.unpack_from("<8I", data, 8)
        b.os_version = struct.unpack_from("<I", data, 44)[0]
        b.name = data[48:64].rstrip(b"\0")
        b.cmdline = data[64:64 + 512].rstrip(b"\0")
        b.extra_cmdline = data[608:608 + 1024].rstrip(b"\0")
        rdo_size = dtb_size = 0
        if b.version >= 1:
            rdo_size, b.recovery_dtbo_offset = struct.unpack_from("<IQ", data, 1632)
        if b.version >= 2:
            dtb_size, b.dtb_addr = struct.unpack_from("<IQ", data, 1648)
        o = b.page
        b.kernel = data[o:o + ks]; o += pages(ks, b.page) * b.page
        b.ramdisk = data[o:o + rs]; o += pages(rs, b.page) * b.page
        b.second = data[o:o + ss]; o += pages(ss, b.page) * b.page
        if rdo_size:
            b.recovery_dtbo = data[o:o + rdo_size]; o += pages(rdo_size, b.page) * b.page
        if dtb_size:
            b.dtb = data[o:o + dtb_size]
        return b

    # ── writing ────────────────────────────────────────────────────────────
    def build(self):
        if self.version >= 3:
            page = 4096
            hdr_size = 1584 if self.version == 4 else 1580
            hdr = MAGIC + struct.pack("<4I", len(self.kernel), len(self.ramdisk),
                                      self.os_version, hdr_size)
            hdr += b"\0" * 16 + struct.pack("<I", self.version)
            hdr += self.cmdline[:1535].ljust(1536, b"\0")
            if self.version == 4:
                hdr += struct.pack("<I", len(self.signature))
            out = hdr + b"\0" * pad(len(hdr), page)
            for seg in (self.kernel, self.ramdisk, self.signature):
                out += seg + b"\0" * pad(len(seg), page)
            return out

        page = self.page
        sha = hashlib.sha1()
        segs = [self.kernel, self.ramdisk, self.second]
        if self.version >= 1:
            segs.append(self.recovery_dtbo)
        if self.version >= 2:
            segs.append(self.dtb)
        for seg in segs:
            sha.update(seg)
            sha.update(struct.pack("<I", len(seg)))
        hdr = MAGIC + struct.pack("<10I", len(self.kernel), self.kernel_addr,
                                  len(self.ramdisk), self.ramdisk_addr,
                                  len(self.second), self.second_addr,
                                  self.tags_addr, page, self.version,
                                  self.os_version)
        hdr += self.name[:15].ljust(16, b"\0")
        hdr += self.cmdline[:511].ljust(512, b"\0")
        hdr += sha.digest().ljust(32, b"\0")
        hdr += self.extra_cmdline[:1023].ljust(1024, b"\0")
        if self.version >= 1:
            rdo_off = 0
            if self.recovery_dtbo:
                rdo_off = page * (1 + pages(len(self.kernel), page) +
                                  pages(len(self.ramdisk), page) +
                                  pages(len(self.second), page))
            hdr_size = 1660 if self.version >= 2 else 1648
            hdr += struct.pack("<IQI", len(self.recovery_dtbo), rdo_off, hdr_size)
        if self.version >= 2:
            hdr += struct.pack("<IQ", len(self.dtb), self.dtb_addr)
        out = hdr + b"\0" * pad(len(hdr), page)
        for seg in segs:
            out += seg + b"\0" * pad(len(seg), page)
        return out


# ── MediaTek 512-byte segment header ───────────────────────────────────────
def mtk_name(seg):
    if len(seg) >= MTK_HDR_SIZE and struct.unpack_from("<I", seg, 0)[0] == MTK_MAGIC:
        return seg[8:40].rstrip(b"\0").decode("ascii", "replace")
    return None


def mtk_wrap(payload, name):
    hdr = struct.pack("<II", MTK_MAGIC, len(payload)) + name.encode().ljust(32, b"\0")
    return hdr + b"\xff" * (MTK_HDR_SIZE - len(hdr)) + payload


# ── commands ───────────────────────────────────────────────────────────────
def cmd_info(a):
    b = BootImage.parse(open(a.image, "rb").read())
    print("header version : %d" % b.version)
    print("page size      : %d" % b.page)
    print("kernel         : %d bytes%s" % (len(b.kernel),
          "  [MediaTek header: %s]" % mtk_name(b.kernel) if mtk_name(b.kernel) else ""))
    print("ramdisk        : %d bytes%s" % (len(b.ramdisk),
          "  [MediaTek header: %s]" % mtk_name(b.ramdisk) if mtk_name(b.ramdisk) else ""))
    if b.version < 3:
        print("second         : %d bytes" % len(b.second))
        print("kernel addr    : 0x%08x" % b.kernel_addr)
        print("ramdisk addr   : 0x%08x" % b.ramdisk_addr)
        print("tags addr      : 0x%08x" % b.tags_addr)
        print("name           : %s" % b.name.decode("ascii", "replace"))
    if b.version >= 1 and b.version < 3:
        print("recovery dtbo  : %d bytes" % len(b.recovery_dtbo))
    if b.version == 2:
        print("dtb            : %d bytes @ 0x%08x" % (len(b.dtb), b.dtb_addr))
    if b.version == 4:
        print("boot signature : %d bytes" % len(b.signature))
    cmd = (b.cmdline + b.extra_cmdline).decode("ascii", "replace")
    print("cmdline        : %s" % cmd)
    if b.version >= 3:
        print("note           : v%d image — the vendor_boot partition supplies the"
              " DTB, more cmdline and vendor kernel modules; leave it as is." % b.version)
    if "skip_initramfs" in cmd:
        print("WARNING        : cmdline has skip_initramfs; the kernel may ignore our ramdisk.")


def cmd_unpack(a):
    b = BootImage.parse(open(a.image, "rb").read())
    os.makedirs(a.outdir, exist_ok=True)
    for name in ("kernel", "ramdisk", "second", "recovery_dtbo", "dtb", "signature"):
        seg = getattr(b, name)
        if seg:
            if mtk_name(seg):
                seg = seg[MTK_HDR_SIZE:]
            open(os.path.join(a.outdir, name), "wb").write(seg)
            print("%-14s %d bytes" % (name, len(seg)))
    open(os.path.join(a.outdir, "cmdline"), "wb").write(b.cmdline + b.extra_cmdline)


def cmd_repack(a):
    b = BootImage.parse(open(a.image, "rb").read())
    rd = open(a.ramdisk, "rb").read()
    name = mtk_name(b.ramdisk)
    if name:
        rd = mtk_wrap(rd, name)
    b.ramdisk = rd
    if b.version == 4:
        b.signature = b""   # GKI signature covers the stock ramdisk; drop it
    if a.cmdline:
        if b.version >= 3:
            b.cmdline = (b.cmdline + b" " + a.cmdline.encode()).strip()
        else:
            full = (b.cmdline + b.extra_cmdline + b" " + a.cmdline.encode()).strip()
            b.cmdline, b.extra_cmdline = full[:511], full[511:]
    open(a.output, "wb").write(b.build())
    print("wrote %s (header v%d, ramdisk %d bytes%s)" % (
        a.output, b.version, len(rd), ", MediaTek header" if name else ""))


def cmd_create(a):
    b = BootImage()
    b.version = a.version
    b.kernel = open(a.kernel, "rb").read()
    b.ramdisk = open(a.ramdisk, "rb").read()
    if a.mtk:
        b.kernel, b.ramdisk = mtk_wrap(b.kernel, "KERNEL"), mtk_wrap(b.ramdisk, "ROOTFS")
    if a.dtb:
        b.dtb = open(a.dtb, "rb").read()
    b.cmdline = a.cmdline.encode()
    b.kernel_addr, b.ramdisk_addr = 0x40080000, 0x41000000
    b.second_addr, b.tags_addr, b.dtb_addr = 0x40f00000, 0x40000100, 0x41f00000
    b.name = b"pryzent"
    open(a.output, "wb").write(b.build())
    print("wrote %s (header v%d)" % (a.output, b.version))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("info"); s.add_argument("image"); s.set_defaults(fn=cmd_info)
    s = sub.add_parser("unpack"); s.add_argument("image"); s.add_argument("outdir")
    s.set_defaults(fn=cmd_unpack)
    s = sub.add_parser("repack"); s.add_argument("image")
    s.add_argument("--ramdisk", required=True); s.add_argument("-o", "--output", required=True)
    s.add_argument("--cmdline", default=""); s.set_defaults(fn=cmd_repack)
    s = sub.add_parser("create")
    s.add_argument("--kernel", required=True); s.add_argument("--ramdisk", required=True)
    s.add_argument("-o", "--output", required=True)
    s.add_argument("--version", type=int, default=2, choices=range(5))
    s.add_argument("--dtb"); s.add_argument("--cmdline", default="")
    s.add_argument("--mtk", action="store_true"); s.set_defaults(fn=cmd_create)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
