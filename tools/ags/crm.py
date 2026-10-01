"""Reader for AGS compiled room files (roomN.crm), AGS 3.x formats (room versions 26-33).

Ported from the AGS source (Common/game/room_file.cpp, util/compress.cpp, util/lzw.cpp,
release-3.6.1, Artistic License 2.0). Pure Python, no dependencies.

    room = read_crm("room1.crm")
    room.width, room.height, room.hotspots, room.objects, room.background (Image)...
"""
import io
import struct
import zlib

PASSWENC = b"Avis Durgan"
MAX_WALK_AREAS = 16  # legacy constant used for the duplicated player-view table


class Image:
    """Simple RGBA image (or 8-bit index map when `palette` is None and bpp == 1)."""

    def __init__(self, width, height, pixels, bpp):
        self.width = width
        self.height = height
        self.pixels = pixels  # bytes: 1 byte per pixel (index) or 4 bytes RGBA
        self.bpp = bpp

    def index(self, x, y):
        return self.pixels[y * self.width + x]

    def to_png(self, path):
        write_png(path, self.width, self.height, self.pixels, 4 if self.bpp == 4 else 1)


def write_png(path, w, h, data, channels):
    """Writes RGBA (channels=4) or grayscale (channels=1) PNG with the standard library."""
    color_type = 6 if channels == 4 else 0
    stride = w * channels
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += data[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


class Reader:
    def __init__(self, data):
        self.s = io.BytesIO(data)

    def i8(self):
        return struct.unpack("<b", self.s.read(1))[0]

    def u8(self):
        return self.s.read(1)[0]

    def i16(self):
        return struct.unpack("<h", self.s.read(2))[0]

    def u16(self):
        return struct.unpack("<H", self.s.read(2))[0]

    def i32(self):
        return struct.unpack("<i", self.s.read(4))[0]

    def i64(self):
        return struct.unpack("<q", self.s.read(8))[0]

    def read(self, n):
        return self.s.read(n)

    def skip(self, n):
        self.s.seek(n, 1)

    def tell(self):
        return self.s.tell()

    def seek(self, pos):
        self.s.seek(pos)

    def cstr(self):
        out = bytearray()
        while True:
            c = self.s.read(1)
            if not c or c == b"\0":
                return decode(out)
            out += c

    def fixed_str(self, n):
        return decode(self.s.read(n).split(b"\0")[0])

    def lstr(self):
        n = self.i32()
        return decode(self.s.read(n)) if n > 0 else ""


def decode(b):
    # AGS 3.6 games may be UTF-8; older ones use the Windows ANSI codepage.
    try:
        return bytes(b).decode("utf-8")
    except UnicodeDecodeError:
        return bytes(b).decode("cp1252", errors="replace")


# --- decompression --------------------------------------------------------------------

def lzw_expand(src, dst_size):
    N, F = 4096, 16
    buf = bytearray(N)
    i = N - F
    out = bytearray()
    p = 0
    n = len(src)
    while p < n and len(out) < dst_size:
        bits = src[p]
        p += 1
        mask = 1
        while mask & 0xFF:
            if bits & mask:
                if p > n - 2:
                    break
                j = struct.unpack_from("<h", src, p)[0]
                p += 2
                length = ((j >> 12) & 15) + 3
                j = (i - j - 1) & (N - 1)
                if len(out) > dst_size - length:
                    break
                for _ in range(length):
                    c = buf[j]
                    out.append(c)
                    buf[i] = c
                    j = (j + 1) & (N - 1)
                    i = (i + 1) & (N - 1)
            else:
                c = src[p]
                p += 1
                out.append(c)
                buf[i] = c
                i = (i + 1) & (N - 1)
            if len(out) >= dst_size or p >= n:
                break
            mask <<= 1
    return bytes(out)


def rle_unpack8(r, size):
    out = bytearray()
    while len(out) < size:
        cx = r.i8()
        if cx == -128:
            cx = 0
        if cx < 0:
            ch = r.read(1)
            out += ch * (1 - cx)
        else:
            out += r.read(cx + 1)
    return bytes(out[:size])


def load_rle_bitmap8(r):
    w = r.i16()
    h = r.i16()
    data = rle_unpack8(r, w * h)
    r.skip(256 * 3)  # palette
    return Image(w, h, data, 1)


def load_lzw(r, bpp):
    pal = r.read(256 * 4)  # RGB structs with filler
    uncomp = r.i32()
    comp = r.i32()
    raw = lzw_expand(r.read(comp), uncomp)
    stride, height = struct.unpack_from("<ii", raw, 0)
    px = raw[8:]
    width = stride // bpp
    rgba = bytearray(width * height * 4)
    if bpp == 4:
        # Allegro 32-bit: 0xAARRGGBB little endian -> B, G, R, A in memory
        for k in range(width * height):
            b, g, r_, a = px[k * 4:k * 4 + 4]
            rgba[k * 4:k * 4 + 4] = bytes((r_, g, b, 255))
    elif bpp == 2:
        for k in range(width * height):
            v = px[k * 2] | (px[k * 2 + 1] << 8)  # RGB565
            rgba[k * 4:k * 4 + 4] = bytes((((v >> 11) & 31) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31, 255))
    else:
        for k in range(width * height):
            idx = px[k]
            # VGA palette entries are 0-63
            rgba[k * 4:k * 4 + 4] = bytes((min(pal[idx * 4] * 4, 255), min(pal[idx * 4 + 1] * 4, 255), min(pal[idx * 4 + 2] * 4, 255), 255))
    return Image(width, height, bytes(rgba), 4)


# --- room ---------------------------------------------------------------------------------

class Room:
    def __init__(self):
        self.version = 0
        self.bpp = 1
        self.width = self.height = 0
        self.mask_resolution = 1
        self.walkbehind_baselines = []
        self.hotspots = []      # dicts: name, script_name, walk_to (x, y), events, properties
        self.objects = []       # dicts: sprite, x, y, visible, baseline, flags, name, script_name, events
        self.region_count = 0
        self.regions = []       # dicts: light, tint, events
        self.walkareas = []     # dicts: scaling_far, scaling_near, top, bottom
        self.edges = {}
        self.room_events = []
        self.messages = []
        self.properties = {}
        self.options = {}
        self.background = None
        self.bg_frames = []
        self.region_mask = self.walk_mask = self.walkbehind_mask = self.hotspot_mask = None


def read_events(r):
    n = r.i32()
    return [r.cstr() for _ in range(n)]


def read_properties(r):
    ver = r.i32()
    n = r.i32()
    out = {}
    for _ in range(n):
        if ver == 1:
            k, v = r.fixed_str(200), r.fixed_str(500)
        else:
            k, v = r.lstr(), r.lstr()
        out[k] = v
    return out


def read_main(room, r, ver):
    room.bpp = max(r.i32(), 1)
    wb = r.i16()
    room.walkbehind_baselines = [r.i16() for _ in range(wb)]
    hc = r.i32() or 20
    room.hotspots = [{"walk_to": (r.i16(), r.i16())} for _ in range(hc)]
    for h in room.hotspots:
        h["name"] = r.lstr() if ver >= 31 else r.cstr() if ver >= 28 else r.fixed_str(30)
    for h in room.hotspots:
        h["script_name"] = r.lstr() if ver >= 31 else r.fixed_str(20)
    if r.i32() > 0:
        raise ValueError("legacy poly-point areas are not supported")
    room.edges = {"top": r.i16(), "bottom": r.i16(), "left": r.i16(), "right": r.i16()}
    oc = r.u16()
    room.objects = [{"sprite": r.u16(), "x": r.i16(), "y": r.i16(), "room": r.i16(), "visible": r.i16() != 0} for _ in range(oc)]
    if ver >= 19:
        for _ in range(r.i32()):
            r.fixed_str(23)
            r.i8()
            r.i32()
    if ver < 26:
        raise ValueError("rooms older than AGS 3.0 (version %d) are not supported" % ver)
    room.region_count = r.i32()
    room.room_events = read_events(r)
    for h in room.hotspots:
        h["events"] = read_events(r)
    for o in room.objects:
        o["events"] = read_events(r)
    room.regions = [{"events": read_events(r)} for _ in range(room.region_count)]
    for o in room.objects:
        o["baseline"] = r.i32()
    room.width = r.i16()
    room.height = r.i16()
    for o in room.objects:
        o["flags"] = r.i16()
    room.mask_resolution = r.i16()
    wc = r.i32()
    room.walkareas = [{} for _ in range(wc)]
    for w in room.walkareas:
        w["scaling_far"] = r.i16()
    for w in room.walkareas:
        w["player_view"] = r.i16()
    for w in room.walkareas:
        w["scaling_near"] = r.i16()
    for w in room.walkareas:
        w["top"] = r.i16()
    for w in room.walkareas:
        w["bottom"] = r.i16()
    r.skip(11)  # legacy password
    room.options = {"startup_music": r.i8(), "save_load_disabled": r.i8() != 0, "player_char_off": r.i8() != 0,
                    "player_view": r.i8(), "music_volume": r.i8(), "flags": r.i8()}
    r.skip(4)
    mc = r.i16()
    if ver >= 25:
        room.game_id = r.i32()
    infos = [(r.i8(), r.i8()) for _ in range(mc)]
    for _ in range(mc):
        n = r.i32()
        raw = bytearray(r.read(n))
        for k in range(len(raw)):
            raw[k] = (raw[k] - PASSWENC[k % 11]) & 0xFF
        room.messages.append(decode(raw.split(b"\0")[0]))
    if r.i16() > 0:
        raise ValueError("legacy room animations are not supported")
    for _ in range(MAX_WALK_AREAS):
        r.i16()
    for reg in room.regions:
        reg["light"] = r.i16()
    for reg in room.regions:
        reg["tint"] = r.i32()
    room.background = load_lzw(r, room.bpp)
    room.bg_frames = [room.background]
    room.region_mask = load_rle_bitmap8(r)
    room.walk_mask = load_rle_bitmap8(r)
    room.walkbehind_mask = load_rle_bitmap8(r)
    room.hotspot_mask = load_rle_bitmap8(r)


def read_crm(path):
    data = open(path, "rb").read()
    r = Reader(data)
    room = Room()
    room.version = ver = r.i16()
    while True:
        bid = r.u8()
        if bid == 0xFF:
            break
        ext = ""
        if bid == 0:
            ext = r.fixed_str(16)
        length = r.i64() if ver >= 32 else r.i32()
        start = r.tell()
        if bid == 1:
            read_main(room, r, ver)
        elif bid == 5 or bid == 9:  # object names / script names
            n = r.u8()
            key = "name" if bid == 5 else "script_name"
            for o in room.objects[:n]:
                o[key] = r.lstr() if ver >= 31 else r.fixed_str(30 if bid == 5 else 20)
        elif bid == 6:  # animated background frames
            count = r.i8()
            room.bg_anim_speed = r.u8()
            for _ in range(count):
                r.i8()  # shared palette flags
            for _ in range(1, count):
                room.bg_frames.append(load_lzw(r, room.bpp))
        elif bid == 8:
            if r.i32() == 1:
                room.properties = read_properties(r)
                for h in room.hotspots:
                    h["properties"] = read_properties(r)
                for o in room.objects:
                    o["properties"] = read_properties(r)
        elif bid == 0 and ext.lower() == "ext_sopts":
            room.str_options = {}
            for _ in range(r.i32()):
                k = r.lstr()
                room.str_options[k] = r.lstr()
        r.seek(start + length)
    return room


if __name__ == "__main__":
    import json
    import sys
    room = read_crm(sys.argv[1])
    print(json.dumps({
        "version": room.version, "size": [room.width, room.height], "bpp": room.bpp,
        "mask_resolution": room.mask_resolution, "edges": room.edges,
        "hotspots": [{k: h[k] for k in ("name", "script_name", "walk_to", "events")} for h in room.hotspots],
        "objects": room.objects, "regions": room.regions, "walkareas": room.walkareas,
        "walkbehinds": room.walkbehind_baselines, "room_events": room.room_events,
        "messages": room.messages, "properties": room.properties,
        "background": [room.background.width, room.background.height], "bg_frames": len(room.bg_frames),
    }, indent=1, ensure_ascii=False))
