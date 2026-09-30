#!/usr/bin/env python3
"""MCP server for Avventura games (stdio, no dependencies).

Lets an AI assistant such as Claude Code check, test, play and look at the game:
  adventure_lint        static checks of scripts and scenes
  adventure_test        run the walkthrough tests
  adventure_play        play with text commands in a persistent headless session
  adventure_screenshot  see the game (PNG image)
  adventure_live        drive the game window you are playing in (remote control)
  adventure_create      create a room, character or item following the conventions

Register it for Claude Code with the .mcp.json file in the project root, or:
  claude mcp add avventura -- python3 tools/adv_mcp.py
Set GODOT to the Godot 4 executable if it is not in PATH.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adv  # noqa: E402  (shared helpers: find_godot, godot, ensure_imported...)

VERSION = "0.1.0"
PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]

INSTRUCTIONS = """Avventura is a point & click adventure engine for Godot. Game content lives in game/:
rooms/<id>/<id>.tscn + <id>.adv, characters.adv, items.adv, game.adv, tests/*.advtest.
After editing scripts call adventure_lint, then adventure_test. Use adventure_play to try
puzzles: commands look like 'look sign', 'pick shovel', 'use key on door', 'talk to beppe',
'choose 2', 'scene' (lists hotspots and exits), 'state', 'expect has(key)'. The play session
keeps its state between calls; pass new_game=true to restart, restart=true after editing scenes."""

TOOLS = [
    {"name": "adventure_lint",
     "description": "Check all game scripts and room scenes: syntax errors, unknown rooms/hotspots/items/characters/dialogs, missing entries, variables never set. Returns 'file:line: level: message' lines.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "adventure_test",
     "description": "Run the walkthrough tests (game/**/*.advtest): each file is played from a new game, lines are commands and 'expect CONDITION' checks. Returns PASS/FAIL per file with the failing step.",
     "inputSchema": {"type": "object", "properties": {
         "file": {"type": "string", "description": "Only this test file, e.g. game/tests/walkthrough.advtest"}}}},
    {"name": "adventure_play",
     "description": "Play the game with text commands in a persistent headless session (instant mode). Returns what happens: dialogue, items gained, room changes, dialog choices. Commands: 'VERB TARGET' (look/use/talk/pick/open/walk... e.g. 'look sign', 'talk to beppe'), 'VERB ITEM on TARGET' ('use key on door', 'give worms to beppe'), 'choose N' or 'choose TEXT', 'scene' (what's in the room), 'state', 'inv', 'vars', 'eval EXPR', 'expect EXPR', 'goto ROOM', 'item add X', 'set VAR = EXPR', 'run STATEMENTS', 'help'.",
     "inputSchema": {"type": "object", "properties": {
         "commands": {"type": "string", "description": "One or more commands, separated by newlines or ';'"},
         "new_game": {"type": "boolean", "description": "Start a new game first"},
         "start_room": {"type": "string", "description": "With new_game: start in this room (room or room:entry)"},
         "restart": {"type": "boolean", "description": "Restart the Godot process (needed after editing .tscn scenes or GDScript; .adv changes are reloaded automatically)"}},
         "required": ["commands"]}},
    {"name": "adventure_screenshot",
     "description": "Take a screenshot of the game as it is in the play session (or in the live game window if live=true). Needs a display (or xvfb-run on Linux).",
     "inputSchema": {"type": "object", "properties": {
         "live": {"type": "boolean", "description": "Capture the running game window instead of the play session"},
         "gui": {"type": "string", "enum": ["two_click", "scumm"], "description": "Interface to show (play session only)"}}}},
    {"name": "adventure_live",
     "description": "Send commands to the game window the user is playing (started with 'python3 tools/adv.py run' or with remote control enabled). Same commands as adventure_play, with real walking and timing; add ' &' to a command to not wait for it.",
     "inputSchema": {"type": "object", "properties": {
         "commands": {"type": "string", "description": "Commands separated by newlines or ';'"},
         "port": {"type": "integer", "description": "Remote control port (default 7777)"}},
         "required": ["commands"]}},
    {"name": "adventure_create",
     "description": "Create a new room (scene + script), character (declaration, optional scene) or item (declaration) following the project conventions.",
     "inputSchema": {"type": "object", "properties": {
         "kind": {"type": "string", "enum": ["room", "character", "item"]},
         "id": {"type": "string", "description": "snake_case id"},
         "name": {"type": "string", "description": "Name shown to the player"},
         "color": {"type": "string", "description": "Character text color, e.g. #ffcc00"}},
         "required": ["kind", "id"]}},
]


class Session:
    """A headless Godot process driven over TCP (instant mode)."""

    def __init__(self):
        self.proc = None
        self.sock = None
        self.file = None
        self.log = None

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, start_room=""):
        self.stop()
        adv.ensure_imported()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        args = [adv.find_godot(), "--headless", "--path", str(adv.ROOT), "--",
                "--adv-remote=%d" % port, "--adv-fast", "--adv-start=" + (start_room or "")]
        if not start_room:
            args[-1] = "--adv-start="
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.proc.poll() is not None:
                self.log.seek(0)
                raise RuntimeError("Godot exited:\n" + adv.clean(self.log.read().decode("utf-8", "replace")))
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.sock.settimeout(300)
                self.file = self.sock.makefile("rwb")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("the game did not open its remote control port")

    def send(self, cmd):
        self.file.write((json.dumps({"cmd": cmd}) + "\n").encode("utf-8"))
        self.file.flush()
        line = self.file.readline()
        if not line:
            raise RuntimeError("the game closed the connection")
        return json.loads(line)

    def stop(self):
        try:
            if self.sock:
                self.sock.close()
        except OSError:
            pass
        if self.alive():
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = self.sock = self.file = None


SESSION = Session()


def split_commands(text):
    out = []
    for line in text.replace("\r", "").split("\n"):
        for part in line.split(";") if not line.strip().startswith("run ") else [line]:
            if part.strip():
                out.append(part.strip())
    return out


def text_result(text, error=False):
    return {"content": [{"type": "text", "text": text or "(no output)"}], "isError": error}


def run_commands(send, commands):
    chunks, ok = [], True
    for c in split_commands(commands):
        r = send(c)
        chunks.append("> %s\n%s" % (c, r.get("output", "")))
        ok = ok and r.get("ok", False)
    status = r.get("status", "?") if chunks else "?"
    return "\n".join(chunks) + "\n[status: %s]" % status, ok


def tool_play(args):
    if args.get("restart") or not SESSION.alive():
        SESSION.start(args.get("start_room", ""))
        new = False
    else:
        new = args.get("new_game", False)
        SESSION.send("reload")
    prefix = ""
    if new:
        r = SESSION.send("new " + args.get("start_room", ""))
        prefix = "> new\n%s\n" % r.get("output", "")
    text, ok = run_commands(SESSION.send, args["commands"])
    return text_result(prefix + text, not ok)


def tool_screenshot(args):
    out = Path(tempfile.gettempdir()) / ("adv_shot_%d.png" % int(time.time() * 1000))
    if args.get("live"):
        r = adv.send_live("screenshot " + str(out), args.get("port", 7777))
        if not r.get("ok"):
            return text_result(r.get("output", "screenshot failed"), True)
    else:
        extra = []
        if SESSION.alive():
            save = adv.session_file("mcp")
            SESSION.send("save " + str(save))
            extra.append("--adv-load=" + str(save))
        if args.get("gui"):
            extra.append("--adv-gui=" + args["gui"])
        code, text = adv.godot(["--rendering-driver", "opengl3", "--", "--adv-run=scene",
                                "--adv-screenshot=" + str(out)] + extra, headless=False)
        if code != 0 or not out.exists():
            return text_result("screenshot failed:\n" + text, True)
    data = base64.b64encode(out.read_bytes()).decode("ascii")
    out.unlink(missing_ok=True)
    return {"content": [{"type": "image", "data": data, "mimeType": "image/png"}], "isError": False}


def tool_live(args):
    port = args.get("port", 7777)
    try:
        text, ok = run_commands(lambda c: adv.send_live(c, port), args["commands"])
    except OSError as e:
        return text_result("Cannot reach the game on port %d (%s). Start it with 'python3 tools/adv.py run' "
                           "or enable Project Settings > avventura/debug/remote_control." % (port, e), True)
    return text_result(text, not ok)


def call_tool(name, args):
    if name == "adventure_lint":
        code, out = adv.godot(["--", "--adv-lint"])
        return text_result(out, code != 0)
    if name == "adventure_test":
        f = args.get("file", "")
        code, out = adv.godot(["--", "--adv-test" + ("=" + f if f else "")])
        return text_result(out, code != 0)
    if name == "adventure_play":
        return tool_play(args)
    if name == "adventure_screenshot":
        return tool_screenshot(args)
    if name == "adventure_live":
        return tool_live(args)
    if name == "adventure_create":
        spec = "%s:%s:%s" % (args["kind"], args["id"], args.get("name", ""))
        if args["kind"] == "character" and args.get("color"):
            spec += ":" + args["color"]
        code, out = adv.godot(["--", "--adv-scaffold=" + spec])
        if code == 0:
            adv.ensure_imported()
        return text_result(out, code != 0)
    return text_result("unknown tool " + name, True)


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, id_ = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}
        try:
            if method == "initialize":
                wanted = params.get("protocolVersion", PROTOCOLS[0])
                reply(id_, {"protocolVersion": wanted if wanted in PROTOCOLS else PROTOCOLS[0],
                            "capabilities": {"tools": {"listChanged": False}},
                            "serverInfo": {"name": "avventura", "version": VERSION},
                            "instructions": INSTRUCTIONS})
            elif method == "ping":
                reply(id_, {})
            elif method == "tools/list":
                reply(id_, {"tools": TOOLS})
            elif method == "tools/call":
                reply(id_, call_tool(params.get("name"), params.get("arguments") or {}))
            elif id_ is not None and not method.startswith("notifications/"):
                reply(id_, error={"code": -32601, "message": "method not found: %s" % method})
        except Exception as e:  # report tool failures to the client instead of dying
            if id_ is not None:
                reply(id_, text_result("error: %s" % e, True))
    SESSION.stop()


if __name__ == "__main__":
    main()
