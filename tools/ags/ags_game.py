"""Imports a whole AGS 3.x project folder (Game.agf, acsprset.spr, roomN.crm/.asc,
GlobalScript.asc, videos and audio) into an Avventura game. Used by `ags_import.py game`."""

import argparse
import glob
import os
import re
import shutil

import agf
import ags_script as S
import crm
import spr

RESERVED_ANIMS = {"idle", "walk", "talk", "stop"}


def _png(path, w, h, rgba):
    crm.write_png(path, w, h, bytes(rgba), 4)


def _flip(img):
    w, h = img.width, img.height
    src = img.pixels
    out = bytearray(len(src))
    for y in range(h):
        row = y * w * 4
        for x in range(w):
            out[row + x * 4:row + x * 4 + 4] = src[row + (w - 1 - x) * 4:row + (w - x) * 4]
    return crm.Image(w, h, bytes(out), 4)


def _pad(img, w, h):
    """Pads to w x h keeping the sprite anchored at its bottom centre (AGS characters)."""
    out = bytearray(w * h * 4)
    ox = (w - img.width) // 2
    oy = h - img.height
    for y in range(img.height):
        d = ((oy + y) * w + ox) * 4
        s = y * img.width * 4
        out[d:d + img.width * 4] = img.pixels[s:s + img.width * 4]
    return bytes(out)


class SpriteExporter:
    """Writes sprites as PNG on demand into game/ags_sprites/."""

    def __init__(self, sprite_file, out_dir, res_dir):
        self.sf = sprite_file
        self.out_dir = out_dir
        self.res_dir = res_dir
        self.done = {}

    def export(self, n):
        """(res_path, width, height) of sprite n, or None."""
        if n in self.done:
            return self.done[n]
        img = self.sf.load(n) if self.sf else None
        if img is None:
            self.done[n] = None
            return None
        os.makedirs(self.out_dir, exist_ok=True)
        img.to_png(os.path.join(self.out_dir, "%d.png" % n))
        self.done[n] = (self.res_dir + "/%d.png" % n, img.width, img.height)
        return self.done[n]


class Tscn:
    def __init__(self):
        self.ext = []
        self.sub = []
        self.nodes = []

    def res(self, kind, path):
        rid = "%d_%s" % (len(self.ext) + 1, kind.lower()[:3])
        self.ext.append('[ext_resource type="%s" path="%s" id="%s"]' % (kind, path, rid))
        return rid

    def node(self, text):
        self.nodes.append(text)

    def text(self):
        parts = ["[gd_scene load_steps=%d format=3]" % (len(self.ext) + len(self.sub) + 1), "\n".join(self.ext)]
        parts += self.sub + self.nodes
        return "\n\n".join(p for p in parts if p) + "\n"


def _q(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def _color(hexstr, alpha=1.0):
    r, g, b = int(hexstr[1:3], 16), int(hexstr[3:5], 16), int(hexstr[5:7], 16)
    return "Color(%.3f, %.3f, %.3f, %.2f)" % (r / 255.0, g / 255.0, b / 255.0, alpha)


# --- characters --------------------------------------------------------------------------------

def character_scene(game, ch, sf, out_dir, res_dir, view_names):
    """game/characters/<id>/<id>.tscn with an AnimatedSprite2D built from the AGS views.
    Frames are padded to a common size so they stay anchored at the feet like in AGS."""
    cid = S.char_id(ch["script_name"])
    anims = []  # (name, [(sprite, flipped, delay)], fps, loop)
    walk = game.views.get(ch["view"])
    if walk:
        for i, loop in enumerate(walk["loops"][:4]):
            if not loop:
                continue
            d = agf.LOOP_DIRS[i]
            frames = [(f["image"], f["flipped"], f["delay"]) for f in loop]
            anims.append(("idle_" + d, frames[:1], 5.0, True))
            anims.append(("walk_" + d, frames[1:] or frames[:1], 40.0 / (ch["anim_delay"] + 1), True))
    talk = game.views.get(ch["speech_view"]) if ch["speech_view"] else None
    if talk:
        for i, loop in enumerate(talk["loops"][:4]):
            if loop:
                anims.append(("talk_" + agf.LOOP_DIRS[i], [(f["image"], f["flipped"], f["delay"]) for f in loop],
                              40.0 / (ch["speech_delay"] + 1), True))
    # other views (LockView/Animate): NAME_<direction>
    for vid in sorted(view_names):
        if vid in (ch["view"], ch["speech_view"]) or vid not in game.views:
            continue
        v = game.views[vid]
        name = S.snake(v["name"]) or "view%d" % vid
        if name in RESERVED_ANIMS:
            name = "view_" + name
        for i, loop in enumerate(v["loops"][:4]):
            if loop:
                anims.append(("%s_%s" % (name, agf.LOOP_DIRS[i]), [(f["image"], f["flipped"], f["delay"]) for f in loop],
                              40.0 / (ch["anim_delay"] + 1), True))
    if not anims:
        return None, 0
    images = {}
    for _, frames, _, _ in anims:
        for n, flipped, _ in frames:
            if (n, flipped) not in images:
                img = sf.load(n)
                if img is None:
                    continue
                images[(n, flipped)] = _flip(img) if flipped else img
    if not images:
        return None, 0
    W = max(i.width for i in images.values())
    H = max(i.height for i in images.values())
    frame_dir = os.path.join(out_dir, "frames")
    os.makedirs(frame_dir, exist_ok=True)
    t = Tscn()
    s_char = t.res("Script", "res://addons/avventura/nodes/adv_character.gd")
    tex = {}
    for (n, flipped), img in sorted(images.items()):
        fname = "%d%s.png" % (n, "f" if flipped else "")
        _png(os.path.join(frame_dir, fname), W, H, _pad(img, W, H))
        tex[(n, flipped)] = t.res("Texture2D", "%s/frames/%s" % (res_dir, fname))
    alist = []
    for name, frames, fps, loop in anims:
        fr = ", ".join('{"duration": %.2f, "texture": ExtResource("%s")}' % (1.0 + d / max(1.0, 40.0 / fps), tex[(n, fl)])
                       for n, fl, d in frames if (n, fl) in tex)
        if fr:
            alist.append('{"frames": [%s], "loop": %s, "name": &"%s", "speed": %.2f}' % (fr, "true" if loop else "false", name, fps))
    t.sub.append('[sub_resource type="SpriteFrames" id="SpriteFrames_1"]\nanimations = [%s]' % ", ".join(alist))
    speed = ch["speed"] * 40.0 / (ch["anim_delay"] + 1)
    t.node("\n".join(['[node name="%s" type="Area2D"]' % cid, 'script = ExtResource("%s")' % s_char,
                      "hotspot_id = %s" % _q(cid), "display_name = %s" % _q(ch["name"] or cid),
                      "text_color = %s" % _color(ch["color"]), "walk_speed = %.1f" % speed, "height = %d.0" % H]))
    first = "idle_down" if any(a[0] == "idle_down" for a in anims) else anims[0][0]
    t.node("\n".join(['[node name="Sprite" type="AnimatedSprite2D" parent="."]', 'sprite_frames = SubResource("SpriteFrames_1")',
                      'animation = &"%s"' % first, "offset = Vector2(0, %d)" % -(H // 2)]))
    path = os.path.join(out_dir, cid + ".tscn")
    with open(path, "w") as f:
        f.write(t.text())
    return path, len(alist)


# --- GUIs as overlays ------------------------------------------------------------------------------

def overlay_scene(gui, sprites, path):
    t = Tscn()
    gid = S.gui_id(gui["name"])
    W, H = gui["w"], gui["h"]
    nodes = ['[node name="%s" type="Control"]\nlayout_mode = 3\noffset_left = %d.0\noffset_top = %d.0\noffset_right = %d.0\noffset_bottom = %d.0\nmouse_filter = 2'
             % (gid, gui["x"], gui["y"], gui["x"] + W, gui["y"] + H)]
    alpha = 1.0 - gui["transparency"] / 100.0
    if gui["transparency"]:
        nodes[0] += "\nmodulate = Color(1, 1, 1, %.2f)" % alpha
    if gui["bg_color"]:
        nodes.append('[node name="Color" type="ColorRect" parent="."]\nlayout_mode = 0\noffset_right = %d.0\noffset_bottom = %d.0\nmouse_filter = 2\ncolor = %s'
                     % (W, H, _color(agf.color(gui["bg_color"]))))
    if gui["bg_image"]:
        e = sprites.export(gui["bg_image"])
        if e:
            r = t.res("Texture2D", e[0])
            nodes.append('[node name="Image" type="TextureRect" parent="."]\nlayout_mode = 0\noffset_right = %d.0\noffset_bottom = %d.0\nmouse_filter = 2\ntexture = ExtResource("%s")'
                         % (e[1], e[2], r))
    for c in gui["controls"]:
        if c["type"] == "GUILabel":
            nodes.append('[node name="%s" type="Label" parent="."]\nlayout_mode = 0\noffset_left = %d.0\noffset_top = %d.0\noffset_right = %d.0\noffset_bottom = %d.0\nmouse_filter = 2\ntheme_override_colors/font_color = %s\ntext = %s\nautowrap_mode = 3'
                         % (c["name"] or "Label", c["x"], c["y"], c["x"] + c["w"], c["y"] + c["h"], _color(c["color"]), _q(c["text"])))
    for n in nodes:
        t.node(n)
    with open(path, "w") as f:
        f.write(t.text())


# --- game ----------------------------------------------------------------------------------------

def _set_project(project, title, w, h):
    """Game name and resolution in project.godot."""
    p = os.path.join(project, "project.godot")
    if not os.path.exists(p):
        return False
    s = open(p).read()
    s = re.sub(r'(?m)^config/name=.*$', lambda m: 'config/name="%s"' % title.replace('"', "'"), s)
    s2 = re.sub(r"window/size/viewport_width=\d+", "window/size/viewport_width=%d" % w, s)
    s2 = re.sub(r"window/size/viewport_height=\d+", "window/size/viewport_height=%d" % h, s2)
    if "viewport_width" not in s2:
        if "[display]" in s2:
            s2 = s2.replace("[display]", "[display]\n\nwindow/size/viewport_width=%d\nwindow/size/viewport_height=%d" % (w, h), 1)
        else:
            s2 += "\n[display]\n\nwindow/size/viewport_width=%d\nwindow/size/viewport_height=%d\n" % (w, h)
    if s2 != open(p).read():
        with open(p, "w") as f:
            f.write(s2)
    return True


def _views_used_by(src_texts, game):
    """View ids referenced by LockView/Animate in the scripts, per character script name."""
    by_name = {S.snake(v["name"]).upper(): vid for vid, v in game.views.items()}
    used = {}
    for text in src_texts:
        for who, view in re.findall(r"(\w+)\.LockView\(\s*(\w+)", text):
            if view.upper() in by_name:
                used.setdefault(who, set()).add(by_name[view.upper()])
    return used


def import_game(args):
    import ags_import as I
    src = os.path.abspath(args.ags_dir)
    game_dir, project = args.game, args.project
    res_game = "res://" + os.path.relpath(game_dir, project).replace(os.sep, "/")
    g = agf.Game(os.path.join(src, "Game.agf"))
    spr_path = os.path.join(src, "acsprset.spr")
    sf = spr.SpriteFile(spr_path) if os.path.exists(spr_path) else None
    sprites = SpriteExporter(sf, os.path.join(game_dir, "ags_sprites"), res_game + "/ags_sprites")
    os.makedirs(game_dir, exist_ok=True)
    notes = []
    print("AGS game: %s (%dx%d), %d rooms, %d characters, %d items, %d sprites"
          % (g.title, g.resolution[0], g.resolution[1], len(g.rooms), len(g.characters), len(g.items), len(sf.offsets) if sf else 0))
    if not sf:
        notes.append("acsprset.spr not found: characters and objects have no graphics")

    player = g.player["script_name"] if g.player else "player"
    overlays = [x for x in g.guis if g.is_overlay(x)]
    engine_guis = [x["name"] for x in g.guis if not g.is_overlay(x)]
    music = [a["script_name"] for a in g.audio if a["type"].lower() == "music"]
    # "player" only for the AGS keyword: control can move to other characters (SetAsPlayer)
    tr = S.Translator("player", overlays=[x["name"] for x in overlays], engine_guis=engine_guis, music=music)

    # characters
    scripts = [open(p, encoding="utf-8", errors="replace").read() for p in glob.glob(os.path.join(src, "*.asc"))]
    views_used = _views_used_by(scripts, g)
    lines = ["# Characters imported from AGS (%s)" % os.path.basename(src), ""]
    for ch in g.characters:
        cid = S.char_id(ch["script_name"])
        lines.append('character %s "%s":' % (cid, ch["name"] or cid))
        lines.append("    color = %s" % ch["color"])
        if ch["room"] >= 0 and ch is not g.player:
            lines.append("    room = room%d" % ch["room"])
            lines.append("    pos = %d, %d" % (ch["x"], ch["y"]))
        lines.append("")
        if sf:
            out_dir = os.path.join(game_dir, "characters", cid)
            os.makedirs(out_dir, exist_ok=True)
            path, n = character_scene(g, ch, sf, out_dir, res_game + "/characters/" + cid,
                                      views_used.get(ch["script_name"], set()))
            print("  character %s: %s" % (cid, "%d animations" % n if path else "no graphics"))
    with open(os.path.join(game_dir, "characters.adv"), "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")

    # items
    lines = ["# Inventory items imported from AGS", ""]
    for it in g.items:
        iid = S.item_id(it["script_name"])
        lines.append('item %s "%s"' % (iid, it["name"] or iid))
        img = sf.load(it["image"]) if sf else None
        if img:
            os.makedirs(os.path.join(game_dir, "items"), exist_ok=True)
            img.to_png(os.path.join(game_dir, "items", iid + ".png"))
    with open(os.path.join(game_dir, "items.adv"), "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")

    # GUIs
    if overlays:
        os.makedirs(os.path.join(game_dir, "overlays"), exist_ok=True)
        for x in overlays:
            overlay_scene(x, sprites, os.path.join(game_dir, "overlays", S.gui_id(x["name"]) + ".tscn"))
        print("  overlays (AGS GUIs used as pictures): " + ", ".join(S.gui_id(x["name"]) for x in overlays))
    if engine_guis:
        notes.append("GUIs replaced by the engine's interface (menus, inventory, save/load): " + ", ".join(engine_guis))

    # audio and video
    missing = []
    for a in g.audio:
        name = S.snake(a["script_name"][1:] if a["script_name"][1:2].isupper() else a["script_name"])
        cands = [os.path.join(src, "AudioCache", a["cache"])] if a["cache"] else []
        base = re.split(r"[\\/]", a["source"])[-1] if a["source"] else ""
        if base:
            cands += [os.path.join(src, base), os.path.join(src, "AudioCache", base), os.path.join(src, "audio", base)]
        found = next((c for c in cands if os.path.isfile(c)), None)
        if found:
            os.makedirs(os.path.join(game_dir, "audio"), exist_ok=True)
            shutil.copy(found, os.path.join(game_dir, "audio", name + os.path.splitext(found)[1].lower()))
        else:
            missing.append("%s (%s)" % (name, base or "?"))
    if missing:
        notes.append("audio files not found, copy them to game/audio/ with these names: " + ", ".join(missing))
    for v in glob.glob(os.path.join(src, "*.ogv")) + glob.glob(os.path.join(src, "*.webm")):
        os.makedirs(os.path.join(game_dir, "video"), exist_ok=True)
        shutil.copy(v, os.path.join(game_dir, "video", os.path.basename(v)))

    # rooms
    start_room = g.player["room"] if g.player else -1
    for crm_path in sorted(glob.glob(os.path.join(src, "room*.crm")), key=lambda p: int(re.findall(r"\d+", os.path.basename(p))[-1])):
        n = int(re.findall(r"\d+", os.path.basename(crm_path))[-1])
        asc = os.path.join(src, "room%d.asc" % n)
        ra = argparse.Namespace(crm=crm_path, asc=asc if os.path.exists(asc) else None, id="room%d" % n,
                                name=g.rooms.get(n) or "Room %d" % n, game=game_dir, project=project, player=player)
        start = (g.player["x"], g.player["y"]) if n == start_room else None
        I.import_room(ra, sprites=sprites, tr=tr, start=start, quiet=True)

    # global script
    gs = os.path.join(src, "GlobalScript.asc")
    if os.path.exists(gs):
        I.import_script(argparse.Namespace(asc=gs, out=None, game=game_dir, player=player), tr=tr, quiet=True)
    for m in glob.glob(os.path.join(src, "*.asc")):
        b = os.path.basename(m)
        if b != "GlobalScript.asc" and not b.startswith("room"):
            notes.append("script module %s not imported (Godot has its own equivalent, or port it by hand)" % b)

    # game.adv
    pid = S.char_id(player)
    lines = ["# Imported from AGS: %s" % os.path.basename(src), "", 'title "%s"' % g.title, "player %s" % pid]
    if start_room >= 0:
        lines.append("start room%d at start" % start_room)
    for v in g.globals:
        val = v["value"] or ("0" if v["type"] in ("int", "float") else ('false' if v["type"] == "bool" else '""'))
        if v["type"] == "String":
            val = '"%s"' % val.strip('"')
        lines.append("var %s = %s" % (S.snake(v["name"]), val))
    with open(os.path.join(game_dir, "game.adv"), "w") as f:
        f.write("\n".join(lines) + "\n")

    if _set_project(project, g.title, *g.resolution):
        print("  project.godot: name \"%s\", resolution %dx%d" % ((g.title,) + g.resolution))
    print("scripts: %d statements translated, %d left as TODO" % (tr.translated, tr.todo))
    for note in notes:
        print("NOTE: " + note)
