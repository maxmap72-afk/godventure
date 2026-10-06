#!/usr/bin/env python3
"""Imports AGS 3.x rooms and scripts into an Avventura game.

  python3 tools/ags/ags_import.py room PATH/room1.crm [--asc PATH/room1.asc] [--game game] [--player cRay]
  python3 tools/ags/ags_import.py script PATH/GlobalScript.asc [--game game] [--player cRay]
  python3 tools/ags/ags_import.py game PATH/AGS_PROJECT_FOLDER [--game game] [--project .]
  python3 tools/ags/ags_import.py gui PATH/AGS_PROJECT_FOLDER     (only the icon bar + inventory window)
  python3 tools/ags/ags_import.py characters PATH/AGS_PROJECT_FOLDER  (only the character graphics)

A room becomes game/rooms/roomN/: roomN.tscn (background, walkable areas with holes,
hotspots, regions, walk-behinds, objects), roomN.adv (translated script) and ags/ (the
original script for reference). Untranslated code is kept as `# TODO AGS:` comments.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ags_script as S  # noqa: E402
import crm  # noqa: E402
import masks  # noqa: E402

ROOM_EVENTS = ["walk_off_left", "walk_off_right", "walk_off_bottom", "walk_off_top", "first_load",
               "load", "repeatedly", "after_fade_in", "leave", "unload"]
HOTSPOT_EVENTS = ["walk_on", "look", "interact", "useinv", "talk", "any", "mouse_over", "pick", "mode8", "mode9"]
OBJECT_EVENTS = ["look", "interact", "talk", "useinv", "any", "pick", "mode8", "mode9"]


def vec(points):
    return "PackedVector2Array(%s)" % ", ".join("%d, %d" % (x, y) for x, y in points)


def q(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


class Scene:
    def __init__(self):
        self.ext = []
        self.nodes = []

    def res(self, kind, path):
        rid = "%d_%s" % (len(self.ext) + 1, kind.lower())
        self.ext.append('[ext_resource type="%s" path="%s" id="%s"]' % ("Script" if kind == "Script" else "Texture2D", path, rid))
        return rid

    def node(self, name, type_, parent=None, props=None):
        head = '[node name="%s" type="%s"%s]' % (name, type_, "" if parent is None else ' parent="%s"' % parent)
        lines = [head]
        for k, v in (props or []):
            lines.append("%s = %s" % (k, v))
        self.nodes.append("\n".join(lines))

    def text(self):
        return "[gd_scene load_steps=%d format=3]\n\n%s\n\n%s\n" % (len(self.ext) + 1, "\n".join(self.ext), "\n\n".join(self.nodes))


def import_room(args, sprites=None, tr=None, start=None, quiet=False):
    """sprites: SpriteExporter for object images; tr: shared Translator; start: (x, y) of the
    player's starting position (adds a `start` marker)."""
    room = crm.read_crm(args.crm)
    num = re.findall(r"\d+", os.path.basename(args.crm))
    rid = args.id or ("room%s" % num[-1] if num else os.path.splitext(os.path.basename(args.crm))[0])
    out_dir = os.path.join(args.game, "rooms", rid)
    os.makedirs(os.path.join(out_dir, "ags"), exist_ok=True)
    res_dir = "res://" + os.path.relpath(out_dir, args.project).replace(os.sep, "/")
    scale = max(1, room.mask_resolution)
    report = []

    # background
    bg_file = "%s.png" % rid
    room.background.to_png(os.path.join(out_dir, bg_file))
    for k, frame in enumerate(room.bg_frames[1:], 1):
        frame.to_png(os.path.join(out_dir, "%s_bg%d.png" % (rid, k)))

    sc = Scene()
    s_room = sc.res("Script", "res://addons/avventura/nodes/adv_room.gd")
    s_walk = sc.res("Script", "res://addons/avventura/nodes/adv_walk_area.gd")
    s_hot = sc.res("Script", "res://addons/avventura/nodes/adv_hotspot.gd")
    s_reg = sc.res("Script", "res://addons/avventura/nodes/adv_region.gd")
    s_entry = sc.res("Script", "res://addons/avventura/nodes/adv_entry.gd")
    t_bg = sc.res("Texture2D", res_dir + "/" + bg_file)

    props = [("script", 'ExtResource("%s")' % s_room), ("display_name", q(args.name or rid.capitalize()))]
    # perspective from the first walkable area that has scaling
    for k, w in enumerate(room.walkareas):
        if k == 0:
            continue
        if w.get("scaling_near", -10000) != -10000:
            props += [("far_y", "%d.0" % w["top"]), ("far_scale", "%.2f" % ((w["scaling_far"] + 100) / 100.0)),
                      ("near_y", "%d.0" % w["bottom"]), ("near_scale", "%.2f" % ((w["scaling_near"] + 100) / 100.0))]
            break
        if w.get("scaling_far", 0) != 0:
            sc_ = (w["scaling_far"] + 100) / 100.0
            props += [("far_scale", "%.2f" % sc_), ("near_scale", "%.2f" % sc_)]
            break
    sc.node(rid.capitalize(), "Node2D", None, props)
    sc.node("Background", "Sprite2D", ".", [("z_index", "-100"), ("texture", 'ExtResource("%s")' % t_bg), ("centered", "false")])

    # walkable areas
    walk_count = 0
    for area in range(1, 16):
        polys = masks.outlines(room.walk_mask, area, scale)
        for k, p in enumerate(polys):
            name = "WalkArea%d" % area + ("_%d" % k if len(polys) > 1 else "")
            sc.node(name, "Polygon2D", ".", [("script", 'ExtResource("%s")' % s_walk),
                                             ("color", "Color(0.2, 0.9, 0.4, 0.25)"), ("polygon", vec(p["outer"]))])
            for h, hole in enumerate(p["holes"]):
                sc.node("Hole%d" % h, "Polygon2D", name, [("color", "Color(0.95, 0.25, 0.2, 0.3)"), ("polygon", vec(hole))])
            walk_count += 1
    report.append("walkable areas: %d polygon(s)" % walk_count)

    # walk-behinds: cut the background, y-sorted at their baseline
    wb_count = 0
    for k in range(1, len(room.walkbehind_baselines)):
        box = masks.bbox(room.walkbehind_mask, k)
        if not box:
            continue
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        m = room.walkbehind_mask
        full = all(m.pixels[(y0 + yy) * m.width + x0:(y0 + yy) * m.width + x1].count(k) == w for yy in range(h))
        base = room.walkbehind_baselines[k] if room.walkbehind_baselines[k] > 0 else y1 * scale
        wp = [("position", "Vector2(%d, %d)" % (x0 * scale, base))]
        if full and scale == 1:
            # the walk-behind fills its rectangle: reuse the background instead of a copy
            wp += [("texture", 'ExtResource("%s")' % t_bg), ("centered", "false"), ("offset", "Vector2(0, %d)" % (y0 - base)),
                   ("region_enabled", "true"), ("region_rect", "Rect2(%d, %d, %d, %d)" % (x0, y0, w, h))]
        else:
            rgba = bytearray(w * h * 4)
            src = room.background.pixels
            bw = room.background.width
            for yy in range(h):
                for xx in range(w):
                    if m.index((x0 + xx), (y0 + yy)) == k:
                        si = ((y0 + yy) * scale * bw + (x0 + xx) * scale) * 4
                        di = (yy * w + xx) * 4
                        rgba[di:di + 4] = src[si:si + 4]
            fname = "%s_wb%d.png" % (rid, k)
            crm.write_png(os.path.join(out_dir, fname), w, h, bytes(rgba), 4)
            tex = sc.res("Texture2D", res_dir + "/" + fname)
            wp += [("texture", 'ExtResource("%s")' % tex), ("centered", "false"),
                   ("offset", "Vector2(0, %d)" % (y0 * scale - base)), ("scale", "Vector2(%d, %d)" % (scale, scale))]
        sc.node("WalkBehind%d" % k, "Sprite2D", ".", wp)
        wb_count += 1
    report.append("walk-behinds: %d" % wb_count)

    # hotspots
    hot_names = {}
    hot_count = 0
    for k, h in enumerate(room.hotspots):
        if k == 0:
            continue
        polys = masks.outlines(room.hotspot_mask, k, scale)
        if not polys:
            continue
        hid = S.hotspot_id(h.get("script_name") or "hHotspot%d" % k)
        hot_names[S.snake((h.get("script_name") or "")[1:])] = hid
        node = (h.get("script_name") or "Hotspot%d" % k)
        hp = [("script", 'ExtResource("%s")' % s_hot), ("hotspot_id", q(hid)), ("display_name", q(h.get("name") or hid))]
        wx, wy = h["walk_to"]
        if wx or wy:
            hp.append(("walk_to", "Vector2(%d, %d)" % (wx, wy)))
        sc.node(node, "Area2D", ".", hp)
        for j, p in enumerate(polys):
            sc.node("Shape%d" % j, "CollisionPolygon2D", node, [("polygon", vec(p["outer"]))])
        hot_count += 1
    report.append("hotspots: %d" % hot_count)

    # regions
    reg_count = 0
    for k in range(1, max(room.region_count, 1)):
        polys = masks.outlines(room.region_mask, k, scale)
        for j, p in enumerate(polys):
            name = "Region%d" % k + ("_%d" % j if len(polys) > 1 else "")
            sc.node(name, "Polygon2D", ".", [("script", 'ExtResource("%s")' % s_reg), ("region_id", q("region%d" % k)),
                                             ("color", "Color(0.3, 0.6, 1, 0.25)"), ("polygon", vec(p["outer"]))])
            reg_count += 1
    report.append("regions: %d polygon(s)" % reg_count)

    # edges (room_LeaveLeft...) become regions at the borders
    edge_regions = []
    for idx, edge in ((0, "left"), (1, "right"), (2, "bottom"), (3, "top")):
        if idx < len(room.room_events) and room.room_events[idx]:
            e = room.edges
            W, H = room.width, room.height
            rect = {"left": (0, 0, e["left"], H), "right": (e["right"], 0, W, H),
                    "bottom": (0, e["bottom"], W, H), "top": (0, 0, W, e["top"])}[edge]
            x0, y0, x1, y1 = rect
            sc.node("Edge_" + edge, "Polygon2D", ".", [("script", 'ExtResource("%s")' % s_reg), ("region_id", q("edge_" + edge)),
                                                     ("polygon", vec([(x0, y0), (x1, y0), (x1, y1), (x0, y1)]))])
            edge_regions.append((edge, room.room_events[idx]))

    # objects: AGS places the sprite with its bottom-left corner at (x, y)
    missing = []
    for k, o in enumerate(room.objects):
        sname = o.get("script_name") or "oObject%d" % k
        oid = S.obj_id(sname)
        op = [("visible", "true" if o["visible"] else "false"), ("position", "Vector2(%d, %d)" % (o["x"], o["y"])),
              ("script", 'ExtResource("%s")' % s_hot), ("hotspot_id", q(oid)), ("display_name", q(o.get("name") or oid))]
        sc.node(sname, "Area2D", ".", op)
        tex = sprites.export(o["sprite"]) if sprites else None
        if tex:
            path, w, h = tex
            t = sc.res("Texture2D", path)
            sc.node("Sprite", "Sprite2D", sname, [("texture", 'ExtResource("%s")' % t), ("centered", "false"),
                                                ("offset", "Vector2(0, %d)" % -h)])
            sc.node("Shape", "CollisionPolygon2D", sname, [("polygon", vec([(0, -h), (w, -h), (w, 0), (0, 0)]))])
        else:
            missing.append(str(o["sprite"]))
            sc.node("Shape", "CollisionShape2D", sname, [])
    if room.objects:
        report.append("objects: %d" % len(room.objects) + (" (sprites not found: %s)" % ", ".join(missing) if missing else ""))
    if start:
        sc.node("start", "Marker2D", ".", [("position", "Vector2(%d, %d)" % start), ("script", 'ExtResource("%s")' % s_entry)])

    # entry point: centre of the largest walkable area
    best = None
    for area in range(1, 16):
        for p in masks.outlines(room.walk_mask, area, scale):
            xs = [x for x, _ in p["outer"]]
            ys = [y for _, y in p["outer"]]
            size = (max(xs) - min(xs)) * (max(ys) - min(ys))
            if best is None or size > best[0]:
                best = (size, (sum(xs) // len(xs), sum(ys) // len(ys)))
    cx, cy = best[1] if best else (room.width // 2, room.height * 3 // 4)
    sc.node("default", "Marker2D", ".", [("position", "Vector2(%d, %d)" % (cx, cy)), ("script", 'ExtResource("%s")' % s_entry)])

    with open(os.path.join(out_dir, rid + ".tscn"), "w") as f:
        f.write(sc.text())

    # script
    adv_lines = ["# Room %s imported from AGS (%s)" % (rid, os.path.basename(args.crm)),
                 "# Untranslated code is kept as '# TODO AGS:' comments.", ""]
    tr = tr or S.Translator(args.player)
    t0, d0 = tr.translated, tr.todo
    if args.asc:
        src = open(args.asc, encoding="utf-8", errors="replace").read()
        with open(os.path.join(out_dir, "ags", os.path.basename(args.asc)), "w") as f:
            f.write(src)
        prog = S.Parser(src).program()
        funcs = prog["functions"]
        event_of = {}
        for idx, fn in enumerate(room.room_events):
            if fn and idx < len(ROOM_EVENTS):
                event_of[fn] = ROOM_EVENTS[idx]
        first = funcs.pop(_key(event_of, "first_load"), None)
        after = funcs.pop(_key(event_of, "after_fade_in"), None)
        load = funcs.pop(_key(event_of, "load"), None)
        leave = funcs.pop(_key(event_of, "leave"), None)
        if load:
            adv_lines += S._emit("on setup:", load["body"], tr)
        if first or after:
            body = []
            if first and S._meaningful(first["body"]):
                body.append({"k": "if", "cond": {"k": "id", "v": "first"}, "then": {"k": "block", "body": first["body"]}, "else": None, "src": ""})
            if after:
                body += after["body"]
            adv_lines += S._emit("on enter:", body, tr)
        if leave:
            adv_lines += S._emit("on exit:", leave["body"], tr)
        for edge, fn in edge_regions:
            f = funcs.pop(fn, None)
            if f:
                adv_lines += S._emit("on walk_onto edge_%s:" % edge, f["body"], tr)
        handlers, other = S.translate_handlers(funcs, tr, hot_names)
        adv_lines += handlers
        for name in other:
            adv_lines += S.translate_function(name, funcs[name], tr)
        for g in prog["globals"]:
            adv_lines.append("# TODO AGS (global): " + " ".join(g.split()))
        report.append("script: %d statements translated, %d left as TODO" % (tr.translated - t0, tr.todo - d0))
    with open(os.path.join(out_dir, rid + ".adv"), "w") as f:
        f.write("\n".join(adv_lines).rstrip() + "\n")
    print("imported %s -> %s" % (args.crm, out_dir))
    for r in report:
        print("  " + r)
    if not quiet:
        _print_uses(tr)
    return rid


def _key(d, value):
    for k, v in d.items():
        if v == value:
            return k
    return None


def _print_uses(tr):
    if tr.used_chars:
        print("  characters used: " + ", ".join(sorted(tr.used_chars)))
    if tr.used_items:
        print("  items used: " + ", ".join(sorted(tr.used_items)))
    if tr.used_rooms:
        print("  rooms referenced: " + ", ".join(sorted(tr.used_rooms)))
    if tr.used_sounds:
        print("  sounds: " + ", ".join(sorted(tr.used_sounds)))


def import_script(args, tr=None, quiet=False):
    src = open(args.asc, encoding="utf-8", errors="replace").read()
    prog = S.Parser(src).program()
    tr = tr or S.Translator(args.player)
    t0, d0 = tr.translated, tr.todo
    lines = ["# Imported from AGS %s" % os.path.basename(args.asc),
             "# Untranslated code is kept as '# TODO AGS:' comments.", ""]
    skip = {"game_start", "repeatedly_execute", "repeatedly_execute_always", "on_key_press", "on_mouse_click",
            "on_event", "dialog_request", "ShowOptions"}
    funcs = {k: v for k, v in prog["functions"].items() if k not in skip and not re.search(r"_On(Click|SliderChange)$|_Click$", k)}
    gui = [k for k in prog["functions"] if re.search(r"_On(Click|SliderChange)$|_Click$", k)]
    tr.excluded |= skip | set(gui)
    handlers, other = S.translate_handlers(funcs, tr)
    lines += handlers
    for name in other:
        lines += S.translate_function(name, funcs[name], tr)
    if gui:
        lines.append("# TODO AGS: GUI callbacks to rebuild in Godot: " + ", ".join(gui))
    out = os.path.join(args.game, args.out or "ags_global.adv")
    with open(out, "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")
    print("translated %s -> %s" % (args.asc, out))
    print("  %d statements translated, %d left as TODO" % (tr.translated - t0, tr.todo - d0))
    if not quiet:
        _print_uses(tr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("room")
    r.add_argument("crm")
    r.add_argument("--asc")
    r.add_argument("--id")
    r.add_argument("--name")
    s = sub.add_parser("script")
    s.add_argument("asc")
    s.add_argument("--out")
    g = sub.add_parser("game", help="import a whole AGS project folder (Game.agf, acsprset.spr, rooms, scripts)")
    g.add_argument("ags_dir")
    u = sub.add_parser("gui", help="only the interface (icon bar + inventory window) from Game.agf")
    u.add_argument("ags_dir")
    c = sub.add_parser("characters", help="only the character scenes and their frames from Game.agf + acsprset.spr")
    c.add_argument("ags_dir")
    for p in (r, s, g, u, c):
        p.add_argument("--game", default="game")
        p.add_argument("--project", default=".")
        p.add_argument("--player", default="player", help="AGS script name of the main character, e.g. cRay")
    a = ap.parse_args()
    a.game = os.path.abspath(a.game)
    a.project = os.path.abspath(a.project)
    if a.cmd == "game":
        import ags_game
        ags_game.import_game(a)
    elif a.cmd == "characters":
        import ags_game
        ags_game.import_characters(a)
    elif a.cmd == "gui":
        import ags_game
        ags_game.import_gui(a)
    elif a.cmd == "room":
        import_room(a)
    else:
        import_script(a)


if __name__ == "__main__":
    main()
