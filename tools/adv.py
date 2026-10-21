#!/usr/bin/env python3
"""Avventura command line: check, test and play the game from a terminal.

Made for humans and for AI assistants such as Claude Code. Only needs Python 3.8+ and
Godot 4.4+ (set the GODOT environment variable if `godot` is not in your PATH).

  python3 tools/adv.py lint                       static checks (file:line: level: message)
  python3 tools/adv.py test [FILE]                run walkthrough tests (.advtest)
  python3 tools/adv.py play "look sign; pick shovel" [--session NAME] [--new]
                                                  play with text commands; the game state is
                                                  kept between calls (per session)
  python3 tools/adv.py shot OUT.png ["commands"] [--session NAME] [--gui scumm]
                                                  screenshot (needs a display or xvfb-run)
  python3 tools/adv.py live "command"             send a command to a running game
  python3 tools/adv.py run [--room ROOM]          start the game in a window, remote control on
  python3 tools/adv.py new-room ID ["Name"]       create game/rooms/ID/ID.tscn + ID.adv
  python3 tools/adv.py new-character ID ["Name"] [COLOR]
  python3 tools/adv.py new-item ID ["Name"]
  python3 tools/adv.py import                     (re)import assets, needed after adding art
  python3 tools/adv.py i18n LOCALE                create/update the translation GAME/lang/LOCALE.po
  python3 tools/adv.py export [PRESET ...]        build the presets of export_presets.cfg (all by
                                                  default) into their export paths
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SESSIONS = ROOT / ".adv" / "sessions"
ASSET_EXT = {".png", ".svg", ".jpg", ".jpeg", ".webp", ".ogg", ".wav", ".mp3", ".ttf", ".otf",
             ".csv", ".tscn", ".tres", ".gd", ".glb", ".gltf"}
NOISE = ("Godot Engine v", "ObjectDB instances were leaked", "resources still in use at exit",
         "   at: ", "     at: ", "ALSA lib", "libpulse", "All audio drivers failed",
         "Condition \"status < 0\"", "Could not set V-Sync", "VK_KHR_surface",
         "Condition \"err != OK\"", "OpenGL API", "Vulkan", "--verbose for details")


def find_godot():
    env = os.environ.get("GODOT") or os.environ.get("GODOT_BIN")
    if env:
        return env
    for name in ("godot", "godot4", "Godot", "godot-4"):
        p = shutil.which(name)
        if p:
            return p
    candidates = [
        "/Applications/Godot.app/Contents/MacOS/Godot",
        "/Applications/Godot_mono.app/Contents/MacOS/Godot",
        str(Path.home() / "Applications/Godot.app/Contents/MacOS/Godot"),
        "/opt/godot/godot", "/usr/local/bin/godot",
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    sys.exit("Godot not found: set the GODOT environment variable to the Godot 4 executable.")


def clean(text):
    return "\n".join(l for l in text.splitlines() if not any(n in l for n in NOISE)).strip("\n")


def godot(args, headless=True, timeout=600, check_import=True):
    if check_import:
        ensure_imported()
    cmd = [find_godot()]
    if headless:
        cmd.append("--headless")
    cmd += ["--path", str(ROOT)] + args
    env = dict(os.environ)
    if not headless and sys.platform.startswith("linux") and not env.get("DISPLAY") and not env.get("WAYLAND_DISPLAY"):
        xvfb = shutil.which("xvfb-run")
        if not xvfb:
            sys.exit("No display available: install xvfb-run or run on a desktop to take screenshots.")
        cmd = [xvfb, "-a", "-s", "-screen 0 1280x720x24"] + cmd
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, "timeout: Godot did not finish in %d seconds" % timeout
    return p.returncode, clean(p.stdout)


def ensure_imported():
    """Imports assets when the .godot cache is missing or older than the project files."""
    stamp = ROOT / ".godot" / ".adv_import_stamp"
    cache = ROOT / ".godot" / "global_script_class_cache.cfg"
    needed = not cache.exists() or not stamp.exists()
    if not needed:
        t = stamp.stat().st_mtime
        for base, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in files:
                if Path(f).suffix.lower() in ASSET_EXT and os.path.getmtime(os.path.join(base, f)) > t:
                    needed = True
                    break
            if needed:
                break
    if needed:
        print("[adv] importing assets...", file=sys.stderr)
        subprocess.run([find_godot(), "--headless", "--path", str(ROOT), "--import"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
        stamp.parent.mkdir(exist_ok=True)
        stamp.write_text(str(time.time()))


def session_file(name):
    SESSIONS.mkdir(parents=True, exist_ok=True)
    return SESSIONS / (name + ".json")


def cmd_play(a):
    save = session_file(a.session)
    args = ["--", "--adv-run=" + a.commands, "--adv-save=" + str(save)]
    if save.exists() and not a.new:
        args.append("--adv-load=" + str(save))
    if a.room:
        args.append("--adv-start=" + a.room)
    if a.lang:
        args.append("--adv-lang=" + a.lang)
    code, out = godot(args)
    print(out)
    return code


def cmd_shot(a):
    out = str(Path(a.out).resolve())
    args = ["--rendering-driver", "opengl3", "--", "--adv-run=" + (a.commands or "scene"),
            "--adv-screenshot=" + out]
    save = session_file(a.session)
    if save.exists():
        args.append("--adv-load=" + str(save))
    if a.gui:
        args.append("--adv-gui=" + a.gui)
    if a.lang:
        args.append("--adv-lang=" + a.lang)
    code, text = godot(args, headless=False)
    print(text)
    return code


def send_live(command, port=7777, timeout=300):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        s.settimeout(timeout)
        f = s.makefile("rwb")
        f.write((json.dumps({"id": 1, "cmd": command}) + "\n").encode())
        f.flush()
        line = f.readline()
    return json.loads(line)


def cmd_live(a):
    try:
        r = send_live(a.command, a.port)
    except OSError as e:
        print("cannot reach the game on port %d (%s). Start it with: python3 tools/adv.py run" % (a.port, e))
        return 1
    print(r.get("output", ""))
    print("[%s]" % r.get("status"))
    return 0 if r.get("ok") else 1


def cmd_run(a):
    ensure_imported()
    cmd = [find_godot(), "--path", str(ROOT), "--", "--adv-remote=%d" % a.port]
    if a.room:
        cmd.append("--adv-start=" + a.room)
    if a.gui:
        cmd.append("--adv-gui=" + a.gui)
    if a.lang:
        cmd.append("--adv-lang=" + a.lang)
    print("[adv] starting the game with remote control on port %d" % a.port)
    subprocess.Popen(cmd)
    return 0


def export_presets():
    """The presets in export_presets.cfg as [(name, export_path)]."""
    cfg = ROOT / "export_presets.cfg"
    if not cfg.exists():
        return []
    out, name = [], None
    for line in cfg.read_text(encoding="utf-8").splitlines():
        if line.startswith("[preset.") and not line.endswith(".options]"):
            name = None
        elif line.startswith("name=") and name is None:
            name = line[5:].strip('"')
        elif line.startswith("export_path=") and name:
            out.append((name, line[12:].strip('"')))
    return out


def cmd_export(a):
    presets = export_presets()
    if not presets:
        sys.exit("No export_presets.cfg: create the presets in Godot (Project > Export).")
    chosen = [p for p in presets if not a.presets or p[0] in a.presets]
    unknown = set(a.presets) - {p[0] for p in presets}
    if unknown:
        sys.exit("Unknown preset(s): %s (there are: %s)" % (", ".join(sorted(unknown)), ", ".join(p[0] for p in presets)))
    failed = 0
    for name, path in chosen:
        (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
        code, out = godot(["--export-release", name, path], timeout=1800)
        errors = [l for l in out.splitlines() if l.startswith("ERROR") and "still in use" not in l]
        if code == 0 and (ROOT / path).exists():
            print("ok    %-10s %s" % (name, path))
        else:
            failed += 1
            print("FAIL  %-10s %s" % (name, path))
            for l in errors[:5] + [l for l in out.splitlines() if "configuration errors" in l][:1]:
                print("      " + l)
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description="Avventura command line", formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("lint", help="static checks")
    t = sub.add_parser("test", help="run walkthrough tests")
    t.add_argument("file", nargs="?")
    p = sub.add_parser("play", help="play with text commands (separated by ;)")
    p.add_argument("commands")
    p.add_argument("--session", default="default")
    p.add_argument("--new", action="store_true", help="start a new game")
    p.add_argument("--room", help="start a new game in this room (with --new)")
    p.add_argument("--lang", help="language (a translation in GAME/lang/)")
    s = sub.add_parser("shot", help="take a screenshot")
    s.add_argument("out")
    s.add_argument("commands", nargs="?")
    s.add_argument("--session", default="default")
    s.add_argument("--gui", help="two_click or scumm")
    s.add_argument("--lang", help="language (a translation in GAME/lang/)")
    lv = sub.add_parser("live", help="send a command to a running game")
    lv.add_argument("command")
    lv.add_argument("--port", type=int, default=7777)
    r = sub.add_parser("run", help="start the game in a window with remote control")
    r.add_argument("--room")
    r.add_argument("--gui")
    r.add_argument("--lang")
    r.add_argument("--port", type=int, default=7777)
    for kind in ("room", "character", "item"):
        n = sub.add_parser("new-" + kind, help="create a " + kind)
        n.add_argument("id")
        n.add_argument("name", nargs="?", default="")
        if kind == "character":
            n.add_argument("color", nargs="?", default="")
    sub.add_parser("import", help="import assets")
    tl = sub.add_parser("i18n", help="create/update a translation file (GAME/lang/LOCALE.po)")
    tl.add_argument("locale")
    ex = sub.add_parser("export", help="build the export presets (export_presets.cfg)")
    ex.add_argument("presets", nargs="*", help="preset names (default: all)")
    a = ap.parse_args()

    if a.cmd == "lint":
        code, out = godot(["--", "--adv-lint"])
        print(out)
        return code
    if a.cmd == "test":
        code, out = godot(["--", "--adv-test" + ("=" + a.file if a.file else "")])
        print(out)
        return code
    if a.cmd == "play":
        return cmd_play(a)
    if a.cmd == "shot":
        return cmd_shot(a)
    if a.cmd == "live":
        return cmd_live(a)
    if a.cmd == "run":
        return cmd_run(a)
    if a.cmd.startswith("new-"):
        spec = "%s:%s:%s" % (a.cmd[4:], a.id, a.name)
        if a.cmd == "new-character" and a.color:
            spec += ":" + a.color
        code, out = godot(["--", "--adv-scaffold=" + spec])
        print(out)
        if code == 0:
            ensure_imported()
        return code
    if a.cmd == "i18n":
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import i18n
        return i18n.run(ROOT, godot, a.locale)
    if a.cmd == "export":
        return cmd_export(a)
    if a.cmd == "import":
        (ROOT / ".godot" / ".adv_import_stamp").unlink(missing_ok=True)
        ensure_imported()
        print("imported")
        return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
