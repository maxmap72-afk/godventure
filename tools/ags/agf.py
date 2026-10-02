"""Reads an AGS 3.x project file (Game.agf): settings, characters, views, inventory items,
GUIs, audio clips, dialogs and global variables."""

import xml.etree.ElementTree as ET

# Colors 0-31 of hi-color AGS games come from the classic palette.
EGA = [(0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170), (170, 0, 0), (170, 0, 170), (170, 85, 0),
       (170, 170, 170), (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255), (255, 85, 85),
       (255, 85, 255), (255, 255, 85), (255, 255, 255)]
LOOP_DIRS = ["down", "left", "right", "up", "down_right", "up_right", "down_left", "up_left"]


def color(n):
    """AGS color number -> '#rrggbb'."""
    n = int(n or 0)
    if n < 16:
        rgb = EGA[n]
    elif n < 32:
        v = (n - 16) * 255 // 15
        rgb = (v, v, v)
    else:
        rgb = (((n >> 11) & 31) * 255 // 31, ((n >> 5) & 63) * 255 // 63, (n & 31) * 255 // 31)
    return "#%02x%02x%02x" % rgb


def _t(e, tag, default=""):
    v = e.findtext(tag)
    return default if v is None else v


def _i(e, tag, default=0):
    try:
        return int(_t(e, tag, str(default)))
    except ValueError:
        return default


class Game:
    def __init__(self, path):
        root = ET.parse(path).getroot()
        g = root.find("Game")
        s = g.find("Settings")
        self.title = _t(s, "GameName", "AGS game")
        res = _t(s, "CustomResolution", "")
        self.resolution = tuple(int(x) for x in res.split(",")) if "," in res else (320, 200)
        self.player_index = _i(g, "PlayerCharacter")

        self.views = {}
        for v in g.iter("View"):
            if v.findtext("ID") is None:
                continue
            loops = []
            for loop in v.iter("Loop"):
                frames = [{"image": _i(f, "Image"), "flipped": _t(f, "Flipped") == "True", "delay": _i(f, "Delay")}
                          for f in loop.iter("ViewFrame")]
                loops.append(frames)
            self.views[_i(v, "ID")] = {"name": _t(v, "Name"), "loops": loops}

        self.characters = []
        for c in g.iter("Character"):
            self.characters.append({
                "index": _i(c, "ID"), "script_name": _t(c, "ScriptName"), "name": _t(c, "RealName"),
                "room": _i(c, "StartingRoom", -1), "x": _i(c, "StartX"), "y": _i(c, "StartY"),
                "view": _i(c, "NormalView"), "speech_view": _i(c, "SpeechView"), "idle_view": _i(c, "IdleView"),
                "color": color(_t(c, "SpeechColor", "15")), "speed": _i(c, "MovementSpeed", 3),
                "anim_delay": _i(c, "AnimationDelay", 4), "speech_delay": _i(c, "SpeechAnimationDelay", 5),
                "scaling": _t(c, "UseRoomAreaScaling") == "True", "clickable": _t(c, "Clickable") == "True"})
        self.player = next((c for c in self.characters if c["index"] == self.player_index),
                           self.characters[0] if self.characters else None)

        self.items = []
        for i in g.iter("InventoryItem"):
            self.items.append({"index": _i(i, "ID"), "script_name": _t(i, "Name"), "name": _t(i, "Description"),
                               "image": _i(i, "Image"), "start": _t(i, "PlayerStartsWithItem") == "True"})

        self.guis = []
        for m in g.iter("GUIMain"):
            n = m.find("NormalGUI")
            if n is None:
                continue
            controls = []
            for c in m.find("Controls") or []:
                controls.append({"type": c.tag, "name": _t(c, "Name"), "x": _i(c, "Left"), "y": _i(c, "Top"),
                                 "w": _i(c, "Width"), "h": _i(c, "Height"), "image": _i(c, "Image", 0),
                                 "text": _t(c, "Text"), "color": color(_t(c, "TextColor", "15"))})
            self.guis.append({"name": _t(n, "Name"), "x": _i(n, "Left"), "y": _i(n, "Top"), "w": _i(n, "Width"),
                              "h": _i(n, "Height"), "bg_color": _i(n, "BackgroundColor"), "bg_image": _i(n, "BackgroundImage"),
                              "visible": _t(n, "Visible") == "True", "popup": _t(n, "PopupStyle", "Normal"),
                              "transparency": _i(n, "Transparency"), "controls": controls})

        types = {}
        for t in g.iter("AudioClipType"):
            types[_i(t, "TypeID")] = _t(t, "Name")
        self.audio = []
        for a in g.iter("AudioClip"):
            self.audio.append({"script_name": _t(a, "ScriptName"), "source": _t(a, "SourceFileName"),
                               "cache": _t(a, "CacheFileName"), "type": types.get(_i(a, "Type"), ""),
                               "index": _i(a, "Index", -1)})

        self.dialogs = []
        for d in g.iter("Dialog"):
            opts = [{"text": _t(o, "Text"), "show": _t(o, "Show") == "True", "say": _t(o, "Say") == "True"}
                    for o in d.iter("DialogOption")]
            self.dialogs.append({"name": _t(d, "Name"), "script": _t(d, "Script"), "options": opts,
                                 "parser": _t(d, "ShowTextParser") == "True"})

        self.globals = [{"name": _t(v, "Name"), "type": _t(v, "Type"), "value": _t(v, "DefaultValue")}
                        for v in g.iter("GlobalVariable")]
        self.rooms = {_i(r, "Number"): _t(r, "Description") for r in g.iter("UnloadedRoom")}

    def is_overlay(self, gui):
        """GUIs that are just pictures (no buttons, sliders, @macros@) become overlays."""
        if gui["popup"] != "Normal":
            return False
        for c in gui["controls"]:
            if c["type"] != "GUILabel" or "@" in c["text"]:
                return False
        return True
