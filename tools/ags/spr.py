"""Reads AGS sprite files (acsprset.spr, versions 4-12) and exports sprites as PNG.

    python3 tools/ags/spr.py acsprset.spr --list
    python3 tools/ags/spr.py acsprset.spr --out sprites/ [--only 26,37,38]
"""

import struct
import sys
import zlib

try:
    from .crm import Reader, Image, lzw_expand
except ImportError:
    from crm import Reader, Image, lzw_expand

SIG = b" Sprite File "
PALETTE_BPP = {32: 3, 33: 4, 34: 2}  # RGB888, ARGB8888, RGB565
MAGIC_PINK32 = 0xFF00FF
MAGIC_PINK16 = 0xF81F


class SpriteFile:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        r = Reader(self.data)
        self.version = r.i16()
        if r.read(13) != SIG or not 4 <= self.version <= 12:
            raise ValueError("not an AGS sprite file (version %d)" % self.version)
        self.compress = 0
        if self.version < 5:
            r.skip(256 * 3)
        elif self.version == 5:
            self.compress = 1
        else:
            self.compress = r.u8()
            r.i32()  # sprite file id
        topmost = r.u16() if self.version < 11 else r.i32()
        if self.version >= 12:
            r.skip(4)  # store flags + reserved
        self.offsets = {}
        self.sizes = {}
        for i in range(topmost + 1):
            if r.tell() >= len(self.data):
                break
            off = r.tell()
            hdr = self._header(r)
            if hdr is None:
                continue
            bpp, fmt, pal_count, comp, w, h = hdr
            pal_bpp = PALETTE_BPP.get(fmt, 0)
            r.skip(pal_count * pal_bpp)
            size = r.u32() if (self.version >= 12 or self.compress) else w * h * bpp
            r.skip(size)
            self.offsets[i] = off
            self.sizes[i] = (w, h)

    def _header(self, r):
        bpp = r.u8()
        fmt = r.u8()
        if bpp == 0:
            return None
        pal_count, comp = 0, self.compress
        if self.version >= 12:
            pal_count = r.u8() + 1
            comp = r.u8()
        w, h = r.i16(), r.i16()
        return bpp, fmt, pal_count, comp, w, h

    def load(self, index, alpha=True):
        """Image (RGBA) of sprite index, or None. alpha: use the alpha channel of 32-bit sprites."""
        off = self.offsets.get(index)
        if off is None:
            return None
        r = Reader(self.data)
        r.seek(off)
        bpp, fmt, pal_count, comp, w, h = self._header(r)
        pal_bpp = PALETTE_BPP.get(fmt, 0)
        palette = []
        for _ in range(pal_count if pal_bpp else 0):
            palette.append(r.u16() if pal_bpp == 2 else (r.u32() if pal_bpp == 4 else int.from_bytes(r.read(3), "little")))
        size = r.u32() if (self.version >= 12 or self.compress) else w * h * bpp
        raw = r.read(size)
        unit = 1 if pal_bpp else bpp
        n = w * h * unit
        if comp == 1:
            px = rle_decompress(raw, n, unit)
        elif comp == 2:
            px = lzw_expand(raw, n)
        elif comp == 3:
            px = zlib.decompress(raw)
        else:
            px = raw
        if pal_bpp:
            values = [palette[b] if b < len(palette) else 0 for b in px[:w * h]]
        elif bpp == 4:
            values = list(struct.unpack_from("<%dI" % (w * h), px))
        elif bpp == 2:
            values = list(struct.unpack_from("<%dH" % (w * h), px))
        else:
            values = list(px[:w * h])
        rgba = bytearray(w * h * 4)
        for k, v in enumerate(values):
            if bpp == 4:
                if (v & 0xFFFFFF) == MAGIC_PINK32 or (alpha and (v >> 24) == 0):
                    continue
                rgba[k * 4:k * 4 + 4] = bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) if alpha else 255))
            elif bpp == 2:
                if v == MAGIC_PINK16:
                    continue
                rgba[k * 4:k * 4 + 4] = bytes((((v >> 11) & 31) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31, 255))
            else:
                if v == 0:
                    continue
                rgba[k * 4:k * 4 + 4] = bytes((v, v, v, 255))  # 8-bit: needs the game palette
        return Image(w, h, bytes(rgba), 4)


def rle_decompress(src, size, unit):
    """AGS sprite RLE (cunpackbitl/16/32): signed control byte, runs of unit-sized pixels."""
    out = bytearray()
    i = 0
    while len(out) < size and i < len(src):
        cx = struct.unpack_from("b", src, i)[0]
        i += 1
        if cx == -128:
            cx = 0
        if cx < 0:
            px = src[i:i + unit]
            i += unit
            out += px * (1 - cx)
        else:
            cnt = (cx + 1) * unit
            out += src[i:i + cnt]
            i += cnt
    return bytes(out[:size])


if __name__ == "__main__":
    import argparse
    import os
    ap = argparse.ArgumentParser()
    ap.add_argument("spr")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--only")
    a = ap.parse_args()
    sf = SpriteFile(a.spr)
    if a.list or not a.out:
        print("version %d, compression %d, %d sprites" % (sf.version, sf.compress, len(sf.offsets)))
        for i, (w, h) in sorted(sf.sizes.items()):
            print(i, w, h)
        sys.exit(0)
    os.makedirs(a.out, exist_ok=True)
    only = [int(x) for x in a.only.split(",")] if a.only else sorted(sf.offsets)
    for i in only:
        img = sf.load(i)
        if img:
            img.to_png(os.path.join(a.out, "%d.png" % i))
