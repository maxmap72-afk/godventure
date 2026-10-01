# Avventura – notes for Claude Code

Avventura is a point & click adventure engine (SCUMM/AGS tradition) for **Godot 4.4+**,
plus a demo game in Italian ("Il Segreto del Faro"). Game content is written in
**AdvScript** (`.adv`, indentation based) and Godot scenes; the engine is GDScript in
`addons/avventura/`. The player-facing language of the demo is Italian: keep new game text
in Italian unless asked otherwise. Code, identifiers and comments are in English.

## Tools (always use them to verify your work)

MCP server `avventura` (see `.mcp.json`): `adventure_lint`, `adventure_test`,
`adventure_play`, `adventure_screenshot`, `adventure_live`, `adventure_create`.
The same things from the shell (`GODOT` env var = Godot 4 executable if not in PATH):

```sh
python3 tools/adv.py lint                        # file:line: level: message
python3 tools/adv.py test                        # all game/**/*.advtest walkthroughs
python3 tools/adv.py play "look cartello; pick pala" --new   # state persists between calls
python3 tools/adv.py play "scene"                # hotspots/exits of the current room
python3 tools/adv.py shot /tmp/s.png             # screenshot of the session (xvfb on Linux)
python3 tools/adv.py shot /tmp/s.png "gui show_pause" --gui scumm   # menus / other interface
python3 tools/adv.py new-room ID "Name" | new-character ID "Name" "#ffcc00" | new-item ID "Name"
python3 tools/adv.py import                      # after adding/changing art
```

Definition of done for any content change: **lint has 0 errors and tests pass**. When you
add or change a puzzle, extend `game/tests/walkthrough.advtest` (or add a new `.advtest`)
so the whole game stays solvable. Engine changes: also run the engine fixtures with
`godot --headless --path . -- --adv-game-dir=res://tests/fixture --adv-test`.

## Layout and conventions

```
game/game.adv              title, player, start room, global vars, fallback responses (on * *)
game/characters.adv        character declarations (+ their handlers and dialogs)
game/items.adv             item declarations; icons in game/items/<id>.svg|png
game/rooms/<id>/<id>.tscn  room scene (root AdvRoom); script <id>.adv next to it
game/characters/<id>/<id>.tscn   optional character scene (AnimatedSprite2D); otherwise a placeholder puppet
game/tests/*.advtest       walkthrough tests (console commands + `expect`)
game/audio/<name>.ogg      used by `sound NAME` / `music NAME`
game/game.gd               optional GDScript whose functions AdvScript can `call`
addons/avventura/          the engine (core/, nodes/, gui/, editor/)
tools/adv.py, tools/adv_mcp.py   CLI and MCP server
tools/ags/                 AGS 3.x importer: crm.py (room files), masks.py, ags_script.py (script translator), ags_import.py
```

- Ids are snake_case. A hotspot's id is its `hotspot_id` or its node name in snake_case.
- Room handlers in `rooms/<id>/<id>.adv` only apply in that room; other files are global.
  Lookup order: room then global; exact (`on use key on door`) → `on * door` → `on use *` → `on * *`.
- Entry points are Marker2D/AdvEntry nodes. A marker named like another room is where the
  player appears when arriving from that room (exits need no extra config).
- Hotspot shortcuts in the inspector: `description` (look), `pickup_item`, `exit_to`/`exit_entry`.
- Visual states: `state door open` plays animation "open" or shows children named `state_open`.
- `show`/`hide`/`enable`/`disable` work on hotspots, walk areas and any node by name.

## Editing .tscn by hand

Rooms are text scenes you can edit directly. Keep `script = ExtResource(...)` as the first
property of a node, then exported properties. Useful node types:
- `AdvRoom` (Node2D root): `display_name`, perspective `far_y/far_scale/near_y/near_scale`.
- `Background` Sprite2D with `centered = false`, `z_index = -100`.
- `AdvWalkArea` (Polygon2D) with `polygon = PackedVector2Array(x1, y1, x2, y2, ...)`; child
  Polygon2D nodes are obstacles.
- `AdvHotspot` (Area2D) + child `CollisionPolygon2D` (click shape) and optional `WalkTo` Marker2D.
- `AdvCharacter` (Area2D) for NPCs fixed in one room; engine-managed characters are declared
  in characters.adv with `room = ...` and `at = MARKER` instead.
After editing scenes restart the play session (`adventure_play` with `restart: true`).

## AdvScript cheat sheet

```
on look cartello:                    # handler: on VERB TARGET / on VERB ITEM on TARGET / on EVENT
    nina: C'è scritto "{nome}".       # dialogue: speaker(mood): text with {expressions}
    if has(chiave) and not faro_aperto:
        set tentativi += 1
    elif visited(molo):
        narrator: ...
    else:
        walk to porta                # walk [CHAR] to TARGET|X,Y [nowait]; face; anim NAME
walk [char] to T|X,Y / walk [char] by DX,DY [nowait] [anywhere] / face / anim / wait 1.5
pickup obj [as item] / inventory add|remove item [to|from char] / video name (game/video/name.ogv)
show|hide|enable|disable obj [in room] / state obj value [in room] / goto room [at entry|X,Y]
on walk_onto REGION: / on walk_off REGION:   (AdvRegion nodes, like AGS regions)
place char at target / place char in room [at entry] / control char / camera follow|to|shake
dialog name / option on|off dialog.opt / end / back / stop / call fn(args) / end_game
cutscene: / bg: / random: / cycle: / sequence: / once: / do: / while cond:
sound name / music name|stop / fade out|in [secs] / print text
dialog beppe:
    on start:
        beppe: Che ti serve?
    option faro "Il faro è spento" once|hidden|silent if COND:
        ...
Top level: title "..", player id, start room [at entry], var x = 0,
           item id "Name"[:  props], character id "Name"[: color/body/hair/room/at/speed/...]
Expressions: and or not == != < > + - * / in; has(item) visited(room) state(obj) shown(obj)
             room() player() used(dialog.opt) room_of(char) name(id) random(a,b) chance(pct)
Handler locals: times, first, verb, target, item. Comments: "# " (hash + space).
```

Full reference (Italian): `docs/GUIDA.md`.

## Engine map (for engine work)

- `core/adv.gd` – autoload `Adv`: rooms, player actions (`perform`), speech, inventory,
  objects, dialogs/choices, cutscenes, camera, audio, save/load (JSON in `user://saves`).
- `core/adv_parser.gd`, `adv_expr.gd` – AdvScript parser and expression language.
- `core/adv_interpreter.gd` – executes statements (every statement is awaited).
- `core/adv_registry.gd` – loads all `.adv`, handler lookup; `adv_state.gd` – saved state.
- `core/adv_controller.gd` – text command language (console, TCP remote, batch, tests).
- `core/adv_linter.gd`, `adv_scaffold.gd`, `adv_pathfinder.gd` (visibility graph).
- `nodes/` – AdvRoom, AdvHotspot, AdvCharacter (placeholder puppet), AdvWalkArea, AdvEntry.
- `gui/` – AdvGui base, TwoClickGui (default), ScummGui; `editor/` – workspace tab, highlighter.
Command line flags (after `--`): `--adv-lint`, `--adv-test[=file]`, `--adv-run="cmds"`,
`--adv-load=/--adv-save=path`, `--adv-start=room[:entry]`, `--adv-fast`, `--adv-remote[=port]`,
`--adv-screenshot=path`, `--adv-gui=scumm|two_click`, `--adv-game-dir=res://...`, `--adv-seed=N`.
Godot quirks: run `--import` when `.godot/` is missing (the CLI does it); textures loaded
inside `_draw` must stay referenced (see `Adv.item_icon` cache).
