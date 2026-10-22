# Avventura Guide

*Versione italiana: [GUIDA.md](GUIDA.md).*

Avventura is an engine for point-and-click graphic adventures in the style of SCUMM and AGS,
built as a plugin for **Godot 4.4 or later**. This guide explains how to make a game, from
the first hotspot to exporting it. The demo game *Il Segreto del Faro* ("The Secret of the
Lighthouse", folder `game/`) uses almost everything described here: keep it open as an
example. The demo is in Italian, so its files and objects have Italian names (`faro` =
lighthouse, `molo` = pier, `spiaggia` = beach...); the examples in this guide use English
names.

**Contents**

1. [Concepts](#1-concepts)
2. [Structure of a game](#2-structure-of-a-game)
3. [Your first game in ten minutes](#3-your-first-game-in-ten-minutes)
4. [Rooms](#4-rooms)
5. [Hotspots](#5-hotspots)
6. [Characters](#6-characters)
7. [Inventory items](#7-inventory-items)
8. [The AdvScript language](#8-the-advscript-language)
9. [Dialogs](#9-dialogs)
10. [Game interfaces](#10-game-interfaces)
11. [Saving](#11-saving)
12. [GDScript: when you need more power](#12-gdscript-when-you-need-more-power)
13. [Tests, console and tools](#13-tests-console-and-tools)
14. [Working with Claude Code](#14-working-with-claude-code)
15. [Project settings](#15-project-settings)
16. [Exporting and translating](#16-exporting-and-translating)
17. [Importing an AGS game](#17-importing-an-ags-game)

---

## 1. Concepts

| Concept | What it is | Where it is defined |
|---|---|---|
| **Room** | a place: background, walkable area, things to interact with | scene `game/rooms/<id>/<id>.tscn` + script `<id>.adv` |
| **Hotspot** | anything clickable: a door, a sign, an exit | `AdvHotspot` node in the room scene |
| **Character** | the player character or an NPC; walks, talks, animates | declared in `characters.adv`, optional scene |
| **Item** | what ends up in the inventory | declared in `items.adv`, icon in `game/items/` |
| **Dialog** | a tree of choices, as in Monkey Island | `dialog` block in a `.adv` file |
| **Script** | what happens when the player does something | `.adv` files (AdvScript) |

The player performs **actions**: a *verb* on a *target*, possibly with an *item*
(`look sign`, `use key on door`, `give worms to beppe`). The engine looks for the script
that handles that action (`on look sign:`) and runs it. If there is none, it uses the
hotspot's shortcuts (description, pick-up, exit) or the generic responses.

## 2. Structure of a game

```
project.godot
addons/avventura/            the engine (no need to touch it)
game/
  game.adv                   title, player character, starting room, variables, generic responses
  characters.adv             characters, their scripts and their dialogs
  items.adv                  inventory items
  items/<id>.svg|png         item icons (optional)
  rooms/<id>/<id>.tscn       room scene
  rooms/<id>/<id>.adv        room script (applies only there)
  characters/<id>/<id>.tscn  character scene (optional)
  audio/<name>.ogg|wav|mp3   sounds and music (audio/menu.* loops on the title menu)
  overlays/splash.tscn       if present, shown on black before the title menu (metadata "seconds", default 5)
  gui/font.ttf|otf|fnt       the game's font (for example a pixel font: it is used without antialiasing)
  tests/*.advtest            automatic walkthroughs (tests)
  title.svg|png              background of the title menu (optional)
  title_logo.png|svg         small logo in the top right corner of the title menu (optional)
  game.gd                    GDScript functions callable from scripts (optional)
```

Naming conventions do the configuration work: a room is named after its folder, a room's
script sits next to its scene, an icon is named after its item. Ids are in `snake_case`
(lowercase, no spaces).

## 3. Your first game in ten minutes

1. **Open the project** in Godot 4.4+. The plugin is already enabled: at the top, next to
   2D, 3D, Script, you'll find the **Avventura** tab.
2. **Create a room**: **+ Room** button, id `kitchen`, name `Kitchen`. The scene and its
   script open.
3. **Background**: drag a 1280×720 image onto the *Texture* property of the `Background`
   node. Without a background the room uses a color: you can prototype without art.
4. **Walkable area**: select `WalkArea` and edit the polygon with the tools in the 2D
   toolbar. It is the floor where the characters' *feet* can be.
5. **A hotspot**: add an `AdvHotspot` node (named for example `Fridge`), give it a
   `CollisionPolygon2D` child and draw the clickable shape. In the inspector set
   *Display Name* to `Fridge` and *Description* to `A humming fridge.`: right-click already
   works, without writing any script.
6. **A script**: in the Avventura tab open `rooms/kitchen/kitchen.adv` and write:

   ```
   on use fridge:
       nina: Let's see what's inside...
       inventory add milk
       nina: Some milk!
   ```

   and in `items.adv` add `item milk "Milk"`.
7. **Connect the room**: in another room add a hotspot with *Exit To* = `kitchen`; in
   `kitchen.tscn` add a `Marker2D` named after the room the player comes from: that's
   where the player character will appear.
8. **Try it**: *Play from this room* (or F6 on the room scene). **Check** reports errors and
   wrong references with file and line.

## 4. Rooms

The root of the scene is an **AdvRoom** node:

| Property | Meaning |
|---|---|
| `room_id` | id used in scripts; empty = file name |
| `display_name` | name shown in saved games |
| `size` | size; zero = the background's size |
| `music` | music from `game/audio/` played on entering |
| `background_color` | color used when there is no `Background` |
| `far_y`, `far_scale`, `near_y`, `near_scale` | perspective: characters shrink towards `far_y` |
| `camera_follow` | the camera follows the player character (rooms wider than the screen) |

Typical children:

- **Background** – a `Sprite2D` with `centered = false` and `z_index = -100`.
- **AdvWalkArea** – a polygon (it is a `Polygon2D`, so you draw it with the polygon editor).
  Its `Polygon2D` children are **obstacles** (a table, a rock). You can have several areas:
  the ones that touch are merged. `blocked = true` turns an area into an obstacle;
  `enabled = false` disables it (a bridge that isn't there yet): in scripts `enable bridge` /
  `disable bridge`. The shortest path is computed automatically.
- **Entry points** – `Marker2D` or `AdvEntry` nodes (the latter also has the direction to
  face). `goto pier at jetty` takes the player character to the marker `jetty`; without
  `at`, the marker named after the room you come from is used, then `default`.
- **Hotspots and characters** – as direct children of the room they are depth-sorted by
  their Y (whoever is lower down stands in front). For things that are always in the
  foreground use a positive `z_index`.
- **Footsteps** – the room's `footsteps` property is the sound of its floor (a file in
  `audio/`, or variants `NAME_1`, `NAME_2`... picked at random): every walking character plays
  it in time with the walk animation (on the first frame and halfway through the cycle), from
  where it stands and more quietly when it is far away. `footsteps = false` on a character
  makes it silent.
- **Darkness** – an `AdvDarkness` node (a ColorRect, direct child of the room) covers the room
  in darkness: only a circle of light is visible around the character in `lit_by` (empty = the
  player, `-` = nobody, total darkness) and around its child Marker2D nodes (fixed lights,
  radius in the `radius` metadata). The parts already lit stay dimly visible, so the map is
  revealed by exploring; what has been seen is kept in the save.
- **Trails (maps)** – `AdvWalkPath` nodes (Line2D): for map rooms seen from above, Monkey
  Island style. If the room has at least one, characters walk only along the lines (joined
  where they cross or where a vertex touches another line) and the walk areas are ignored. A
  click leads to the nearest point of the trails; if that point is in a part that isn't
  connected (a maze), the character stops at the closest reachable point and an unreachable
  exit doesn't fire. The room's `walk_speed_scale` speeds up small figures. `enable`/`disable`
  switch a trail on and off (a bridge that collapses...).
- **Walk-behinds** – `AdvWalkBehind` nodes (like the *walk-behind areas* of AGS): a piece of
  the background (a column, a balustrade, the back of a seat) that is redrawn over the
  characters standing *behind* it. The piece is the polygon (drawn over the background with
  the polygon editor) or the opaque pixels of `mask`, an image as large as the background and
  transparent elsewhere (handy for thin shapes such as ropes and railings). `baseline` is the
  room Y that separates front and back: whoever has their feet higher up passes behind,
  whoever has them lower down passes in front (0 = the lowest point of the polygon or mask).
  It must be a direct child of the room; `show`/`hide` turn it on and off. If the piece
  stands on the floor, remove its footprint from the walkable area, so nobody walks into it.

- **Regions** – `AdvRegion` nodes (invisible polygons on the floor): when the player
  character enters or leaves one, `on walk_onto ID:` and `on walk_off ID:` run (like the
  *WalksOnto* events of AGS). They only fire when the game isn't running a script;
  `enable`/`disable` turn them on and off.

Room events, in the room's script:

```
on setup:      # the room is loaded but not visible yet (also after loading a saved game)
on enter:      # the player character has entered (not after loading a saved game)
on exit:       # about to leave
```

`setup` should only arrange how things look (it may run more than once); entrance scenes
go in `enter`, often with `if first:`.

## 5. Hotspots

An **AdvHotspot** is an `Area2D`. The clickable shape is a `CollisionPolygon2D` (or
`CollisionShape2D`) child; if there is none, the rectangle of a `Sprite2D` /
`AnimatedSprite2D` child is used (with `pixel_perfect`, only its non-transparent pixels).

| Property | Meaning |
|---|---|
| `hotspot_id` | id for scripts; empty = the node name in snake_case (`OldChest` → `old_chest`) |
| `display_name` | name shown when the mouse is over it |
| `description` | line said by the player character on *look* when there is no script |
| `default_verb` | action of the main click (two-click interface) or of the right click (SCUMM) |
| `walk_to` | point where the player character stops (relative); or a `Marker2D` child named `WalkTo` |
| `face` | direction to face on arrival |
| `walk_before` | whether the player character walks up to the hotspot before acting |
| `interactive` | clickable or not (in scripts: `enable` / `disable`) |
| `pickup_item` | shortcut: *pick up* hides it and adds this item to the inventory |
| `exit_to`, `exit_entry` | shortcut: it is an exit to that room (and that entry point) |
| `click_priority` | wins when two hotspots overlap (on a tie the smaller one wins) |

**Visual states.** `state door open` plays the animation `open` of an `AnimatedSprite2D` or
`AnimationPlayer` child, and shows the children named `state_open` while hiding the other
`state_...` ones. In the demo the barrel has two sprites, `state_chiuso` and `state_aperto`
(closed and open). The state is saved and restored.

**Talking objects.** A hotspot can talk too: `seagull: Squawk!` shows the text above the
seagull.

**Showing and hiding.** `show`, `hide`, `enable`, `disable` and `state` work on hotspots,
walkable areas and any node by name (for example a `Hole` sprite), even in other rooms
(`hide boat in pier`): the engine remembers it.

## 6. Characters

They are declared in `game/characters.adv`:

```
character beppe "Beppe":
    color = #ffd166      # text color (and color of the puppet)
    body = #e9b949       # puppet: clothes
    hair = #d9d9d9       # puppet: hair
    skin = #f5cfa9       # puppet: skin
    speed = 180          # pixels per second
    scale = 0.65         # size relative to the artwork (1 = original)
    anim_speed = 1.5     # speed of the animations (1 = normal)
    height = 150         # height (puppet, clickable area, position of the speech text)
    room = pier          # where they are when the game starts
    at = beppe_spot      # at which point (marker or hotspot)
    description = An old fisherman.
```

The player character is the one named by `player` in `game.adv`.

**Graphics.** Without a scene the character is a **puppet drawn by the engine** (it walks,
talks, picks things up): you can finish a whole game before drawing anything. For real
graphics create `game/characters/<id>/<id>.tscn` with an `AdvCharacter` root and an
`AnimatedSprite2D` child (the **+ Character** button with "Also create a scene for sprites"
prepares everything). Animation names:

| Animation | When |
|---|---|
| `idle_down`, `idle_up`, `idle_side` | standing still (`side` faces right; `side_faces_left` if it's the other way round) |
| `walk_down`, `walk_up`, `walk_side` | walking |
| `talk_down`, `talk_side`, ... | talking (`talk_happy` for `beppe(happy): ...`) |
| `idle_left` / `idle_right` etc. | alternatives to `side`, if you drew them |
| `fidget_down`, `fidget_side`, `fidget2_*`, `fidget3_*` | idle gestures (not looped): every 5-11 seconds a character standing still plays one at random; `fidgets = false` on the node turns them off |
| any other name | `anim beppe dance` |

**Shadow.** Characters with sprites cast a soft shadow on the floor under their feet, which
follows the room's perspective. In the character scene it is set with `shadow` (on/off),
`shadow_opacity` and `shadow_offset` (a shift to the right, for light coming from the left).

**Who turns round.** When the player character walks up to a character (to talk, give or use
something on them) that character turns towards them. `turns_to_player = false` on the node
prevents it: a guard who has his back turned and must stay that way (from a GDScript script:
`Adv.get_character("beppe").turns_to_player = false`).

If a variant is missing, the engine falls back to the closest one (`walk_left` →
`walk_side` mirrored → `walk_down` → `walk` → `idle`). For the pick-up animation use
`pickup`.

**Two kinds of NPC.** A character *declared* in `characters.adv` is managed by the engine:
it can change room (`place beppe in lighthouse at stairs`), its position is saved and it can
become the player character (`control beppe`, Maniac Mansion style). An `AdvCharacter`
placed directly in a room scene is instead a *local* NPC of that room (the crab in the
demo).

## 7. Inventory items

```
item key "Lighthouse key"
item worms "Worms":
    description = A handful of worms.   # answer to "look" when there is no script
    icon = res://art/worms.png          # optional: by default game/items/worms.svg|png|webp
    color = #c9a36d                     # color of the placeholder when there is no icon
```

Without an icon a colored placeholder with the item's initial is drawn. Typical scripts:

```
on look key:                    # looking at an inventory item
    nina: A big iron key.
on use shovel:                  # using an item on its own (SCUMM interface)
    nina: I have to decide where to dig.
on use worms on shovel:         # combining two items (works both ways round)
    nina: The shovel isn't hungry.
on use key on door:             # an item on a hotspot
on give worms to beppe:         # giving to a character (using an item on a character tries it too)
on walk floor:                  # a click on the floor (before walking); `stop` cancels the walk
```

## 8. The AdvScript language

AdvScript is designed for people who write stories: it reads like a screenplay. It is based
on **indentation** like GDScript and Python (4 spaces recommended). Comments start with `#`
followed by a space (`#ffcc00` is a color, not a comment).

### 8.1 Top-level blocks

```
title "The Secret of the Lighthouse"   # title of the game
player nina                            # player character
start beach at default                 # starting room (and point)
var coins = 0                          # variable with its initial value
score points 50                        # optional: score (variable, most points), in the pause menu
item ... / character ...               # declarations (see above)

on EVENT:                              # start (in game.adv), enter/setup/exit (rooms)
on VERB TARGET:                        # on look sign:
on VERB ITEM on TARGET:                # on use key on door:  (also with / to / in / at)
dialog NAME:                           # see chapter 9
function NAME(parameters):             # reusable sequences: call NAME(values)
```

**Score.** With `score points 50` (after `var points = 0`) the pause menu shows
"Score: 12 of 50"; points are given with `set points += 2`. From GDScript, `Adv.score()`
returns `[points, most]` (empty if the game keeps no score), for example for the end credits.

**Verbs.** The standard ones are `walk`, `look`, `use`, `talk`, `pick`, `open`, `close`,
`push`, `pull`, `give`; you can invent others (`on lick stamp:`) and use them as the default
verb of a hotspot or in the SCUMM interface.

**Wildcards.** `*` means "any": `on look *:` (looking at anything), `on use * on door:` (any
item on the door), `on * *:` (any action).

**Which script wins.** For `use key on door` the engine tries, in order:
`on use key on door` → `on use door on key` (useful for combining two items) →
`on use * on door` → `on use key on *` → `on use * on *` → `on * *`. For an action without an
item: `on look sign` → the hotspot's shortcuts (description, exit, pick-up) →
`on * sign` → `on look *` → `on * *`. At every step the **room** script wins over the global
one. Using an item on a character also tries `on give ITEM to CHARACTER`.

**Local variables of a script:** `verb`, `target`, `item` (the action), `times` (how many
times this script has already run) and `first` (true the first time).

### 8.2 Statements

| Statement | Example | Notes |
|---|---|---|
| line of dialogue | `nina: Hello!` · `beppe(happy): "Hooray!"` | `narrator:` for the narrator; `{expressions}` in the text |
| `walk` | `walk to door` · `walk beppe to 400, 520` · `walk to boat nowait` · `walk beppe by 100, -20` | `nowait` doesn't wait for the arrival; `by` moves relative to the current position; `anywhere` ignores the walkable areas |
| `face` | `face left` · `face beppe nina` | left/right/up/down or a target |
| `anim` | `anim dig` · `anim beppe dance loop` · `anim idle` | `nowait`, `loop`; `idle` stops |
| `wait` | `wait 1.5` | seconds |
| `set` | `set coins += 1` · `set name = "Nina"` | `=`, `+=`, `-=` |
| `if` / `elif` / `else` | `if has(key) and not lighthouse_open:` | |
| `while` | `while attempts < 3:` | |
| `inventory` | `inventory add key` · `inventory remove worms` · `inventory add note to beppe` | |
| `pickup` | `pickup shovel` · `pickup crate as hammer` | walks, picks up, hides, adds |
| `show` / `hide` | `show hole` · `hide boat in pier` · `show dawn fade 3` | hotspots, nodes, in other rooms; `fade N`: dissolve over N seconds |
| `enable` / `disable` | `disable door` · `enable bridge` | interactivity, walkable areas |
| `state` | `state barrel open` · `state lighthouse lit in beach` | saved visual state |
| `goto` | `goto lighthouse` · `goto pier at jetty` · `goto pier at 240, 350` | changes room (also to a precise point) |
| `place` | `place beppe at barrel` · `place beppe in lighthouse at stairs` · `place beppe in lighthouse at 600, 500` · `place beppe at -60, 500 anywhere` | moves a character (to the nearest walkable point; with `anywhere` exactly there, even off screen, so it can then walk in) |
| `control` | `control beppe` | changes the player character |
| `dialog` | `dialog beppe` | opens a dialog |
| `option` | `option on beppe.worms` · `option off beppe.lighthouse` | enables/disables options |
| `end` / `back` | `end` | closes the dialog / goes back to the previous dialog |
| `stop` | `stop` | stops the script (or the function) |
| `call` | `call help(2)` · `call open_trapdoor()` | AdvScript or GDScript function |
| `cutscene:` | block | hides the interface; Esc skips it |
| `bg:` | block | runs in the background, without stopping the game |
| `random:` · `cycle:` · `sequence:` | block of alternatives | one line at random / in turn / in sequence until the last one |
| `once:` | block | only the first time |
| `do:` | block | groups several lines (for example as one alternative of `random:`) |
| `sound` / `music` | `sound door` · `music theme` · `music stop` | files in `game/audio/` |
| `video` | `video intro` | full-screen movie from `game/video/intro.ogv`; a click or Esc skips it |
| `camera` | `camera to lighthouse 2` · `camera follow` · `camera shake 0.5` | |
| `fade` | `fade out 1` · `fade in` | fade to black |
| `print` | `print coins={coins}` | debug message |
| `end_game` | `end_game` | end of the game (back to the menu) |

**Music transitions (iMuse style).** The music never stops abruptly: when the track changes
(from `music` or from a room's music) the old one fades out while the new one comes in, in
`avventura/audio/music_fade` seconds (1.5); `music stop` fades out the same way. Going back
to a track heard recently (within `avventura/audio/music_resume_seconds`, 3 minutes) resumes
it where it was instead of starting over. Sounds still playing in the room being left
(ambiences, loops) also fade out, in `avventura/audio/room_sound_fade` seconds.

A complete example with almost everything:

```
on use lever:
    if state(lever) == "down":
        nina: It's already down.
        stop
    walk to lever
    anim pull
    state lever down
    camera shake 0.3
    enable bridge
    cutscene:
        camera to bridge 1.5
        wait 1
        narrator: With a creak, the bridge comes down.
        camera follow
    set levers_used += 1
    random:
        nina: Done!
        nina: There you go.
        do:
            nina: Phew...
            nina: That was hard.
```

### 8.3 Expressions

Operators: `and`, `or`, `not`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `%`,
`in` (also `not in`), parentheses, lists `[1, 2]`, text in quotes.

The language is forgiving: a variable that was never assigned is `null`, which is equal to
`false`, `0` and `""`; `true == 1`; `"coins: " + 3` gives `"coins: 3"`; `7 / 2` gives `3.5`.
The check (lint) still reports variables that are never assigned, because they are often
typos. Variable names can contain dots (`beppe.angry`).

Available functions:

| Function | Result |
|---|---|
| `has(item)` · `has(item, character)` | the item is in the inventory |
| `visited(room)` · `visits(room)` | already visited / how many times |
| `room()` · `player()` | current room / current player character |
| `state(obj)` · `state(obj, room)` | visual state |
| `shown(obj)` · `enabled(obj)` | visible / interactive (also in other rooms) |
| `room_of(character)` | where a character is |
| `near(character, target)` | whether it is close (40 pixels, or a third argument) |
| `used(dialog.option)` | how many times an option has been chosen |
| `name(id)` | display name of an item, hotspot or character |
| `is_player(character)` | is the player character |
| `random(a, b)` · `chance(percent)` | random number / true with that probability |
| `str()` · `int()` · `float()` · `len()` · `min()` · `max()` · `abs()` | utilities |
| `said(text)` · `ended()` | for tests: it has been said / the game has ended |
| any GDScript function | of the room or of `game.gd` (see chapter 12) |

A handy rule: in the functions that take an **id** (`has`, `visited`, `state`, `shown`,
`enabled`, `room_of`, `used`, `name`, `is_player`, `near`) a name without quotes is the id
itself: `has(key)` is the same as `has("key")`. Elsewhere text goes in quotes:
`state(barrel) == "open"`.

In the text of dialogue lines, expressions go in braces: `nina: I have {coins} coins.`
(to write a brace: `\{`).

## 9. Dialogs

```
dialog beppe:
    on start:                       # runs when the dialog opens (optional)
        once:
            beppe: Ahoy there, girl!
        beppe: What do you need?

    option "Who are you?" once:      # "once": disappears after being chosen
        beppe: The name's Beppe.

    option lighthouse "The lighthouse is out. Can I help?":
        beppe: Bring me some worms.
        option on beppe.worms        # unlocks a hidden option

    option worms "Where can I find worms?" hidden once:
        beppe: Under the wet sand.

    option "Let's talk about something else":
        dialog beppe_gossip          # sub-dialog: "back" returns here

    option "Have you seen the treasure?" if visited(cave):   # visible only if the condition is true
        beppe: What treasure?

    option "Bye, Beppe.":
        beppe: Good luck!
        end                          # closes the whole dialog
```

- The player character automatically **says** the text of the chosen option; add `silent`
  to the option to avoid it (or turn off `avventura/dialog/player_says_options`).
- An id (such as `lighthouse`) lets other scripts refer to the option
  (`option off beppe.lighthouse`, `used(beppe.lighthouse)`); without an id, it is derived
  from the text.
- After a choice the menu comes back, until a script does `end`, a sub-dialog does `back`,
  or no options are left.
- A dialog is started with `dialog NAME`, usually from `on talk character:`.

## 10. Game interfaces

You choose it in the Avventura tab (*Interface* menu) or in *Project Settings →
avventura/gui/scene*.

**Two-click (default, modern).** Left click: walk, or do the hotspot's main action (talk to
characters, pick up items, leave through exits...). Right click: look. The inventory slides
up from the bottom edge: click an item to take it in hand, then click something to use it;
right-click an item to look at it. Double-click on an exit: leave immediately.

**SCUMM verbs (Monkey Island 2 style).** Nine verbs, the sentence line ("Use key with
door") and the inventory in a panel at the bottom. Right click performs the default verb,
highlighted in the panel. Rooms designed for this interface should leave the bottom strip
free (about 190 pixels), as in the original games; otherwise the camera scrolls above the
panel. The verbs can be configured in the `verbs` property.
An item that has both `on use ITEM:` and some `on use ITEM on ...:` (a suit to wash in the
fountain and then to put on) waits for the second target ("Use Suit with"): a click on the
same item or on the player character performs the use on its own. In every interface, while
an item waits for its target, the player character can be clicked too: `on use ITEM on nina:`
if it exists, otherwise `on use ITEM:`.

**AGS style (icon bar).** As in the Adventure Game Studio templates: moving the mouse to the
top of the screen reveals an icon bar (inventory, save, load, menu); the inventory is a
window with the grid of items, the "select" and "look" buttons, arrows to scroll and
"Close". In the rooms the mouse works as in the two-click interface; an item selected in the
window stays in hand and is used by clicking on something. Key **I**: opens and closes the
inventory. Positions and images come from `game/gui/ags_gui.json`, written by the AGS
importer from the GUIs of the original game (it can be edited by hand: coordinates, images,
the bar's actions `inventory`/`save`/`load`/`menu`/`quit` and the window's
`select`/`look`/`up`/`down`/`close`). Without that file it uses a plain bar and window.

Controls common to all interfaces:

| Key | Action |
|---|---|
| click / Space / . | skips the line |
| Esc | skips the cutscene, puts down the item in hand, opens the pause menu |
| Tab (held down) | shows the names of all hotspots |
| 1–9 | chooses a dialog option |
| F5 / F9 | quick save / quick load |
| \ (the key left of 1) or F12 | debug console (debug builds only) |

**Customizing.** The exported properties of the `two_click_gui.tscn` and `scumm_gui.tscn`
scenes (font sizes, colors, verbs) are changed in the inspector; `gui_theme` accepts a Godot
theme. For a brand-new interface (for example a "verb coin") extend `AdvGui` and override
`click_world()`, `click_item()` and `hover_text()`, then set your scene in the settings.

The title menu shows `game/title.svg|png` if it exists, and `game/title_logo.png` (120 pixels
wide) in the top right corner. The player can adjust the text
speed, auto-advance, volumes and full screen (saved in `user://settings.cfg`).

## 11. Saving

The pause menu offers six save slots plus the quick save. You can save when the game is
waiting for the player (not during scripts or cutscenes). The file is readable JSON in
`user://saves/` and contains variables, inventories, room, character positions, object
states, dialog options and counters (`times`, `cycle`...). After loading, the room's
`on setup` runs, not `on enter`.

### Chapters (starting from a point in the story)

In walkthrough tests, the command `checkpoint ID Title` saves the state of the game at the
moment of the last entrance into a room (before its `on enter`) to `game/scene/ID.json`:

```
use stained_glass
expect room() == "car"
checkpoint 02_car Shanghai - The escape in the Duesenberg
```

If the `scene/` folder contains these files, **Ctrl+Shift+S** (in the title menu or while
playing) opens the **Chapters** list; the entry doesn't appear in the menus, so the player
doesn't skip the story. Choosing a title restarts from there, with items, variables and characters exactly as in a real game,
and the room's entrance (its opening scene) runs again. The files are regenerated every time
the tests run; from the console you can try one with `chapter ID`.

## 12. GDScript: when you need more power

AdvScript covers most cases; for the rest there is GDScript.

**Room functions.** Give the room's root a script that extends `AdvRoom`; its functions can
be called from AdvScript:

```gdscript
extends AdvRoom

func open_trapdoor() -> void:          # call open_trapdoor()
	$Trapdoor/AnimationPlayer.play("open")
	await $Trapdoor/AnimationPlayer.animation_finished

func right_combination(n) -> bool:     # if right_combination(code):
	return n == 1234
```

**Global functions.** The same goes for `game/game.gd` (it extends `Node`), created at
startup.

**The engine from GDScript.** The `Adv` autoload offers the same commands as the scripts:

```gdscript
await Adv.say("nina", "Hello!")
await Adv.walk("nina", "door")           # or a Vector2 position
Adv.face("nina", "left")
await Adv.anim("beppe", "dance")
Adv.inventory_add("key")
Adv.has_item("key")
Adv.set_var("coins", 3); Adv.get_var("coins")
Adv.set_object_state("door", "open")
Adv.set_object_visible("hole", true)
await Adv.change_room("lighthouse", "entrance")
Adv.perform("use", "door", "key")        # like a click by the player
await Adv.interp.run_source("nina: I can run AdvScript!")
Adv.save_game("slot1"); await Adv.load_game("slot1")
```

Useful signals: `room_entered`, `speech_started`, `speech_finished`, `choice_requested`,
`inventory_changed`, `item_selected`, `cutscene_changed`, `game_started`, `game_ended`,
`transcript_line` (everything that happens, as text). `Adv.state.custom` is a free
dictionary that is saved with the game.

## 13. Tests, console and tools

### The command language

The debug console, the automatic tests, remote control and Claude Code all use the same
language, which looks like the game itself:

```
look sign                  talk to beppe            use key on door
pick shovel                give worms to beppe      walk pier_exit      walk 400 600
choose 2                   choose "Who are you"     skip
scene                      state     inv     vars     get coins     eval has(key)
expect has(key)            expect room() == "lighthouse"  expect said("Beppe")
goto lighthouse            item add key             set coins = 10
run nina: I can say anything I like\ndialog beppe
new     save test     load test     reload     fast on|off     screenshot     lint
click 400 600     rclick 400 600     gui show_pause     gui show_settings     gui close
```

`scene` lists the room's hotspots with id, name, main verb and exits: it is the quickest way
to get your bearings. `reload` reloads the `.adv` scripts without restarting the game.
Adding ` &` at the end of a command doesn't wait for it to finish.

### Automatic tests (`.advtest`)

A `.advtest` file is a written playthrough: one line per command, plus `expect` checks.
Each file starts from a new game in instant mode (no waiting). Example:

```
look sign
expect said("Beppe")
pick shovel
expect has(shovel)
use shovel on sand
expect has(worms)
```

Always keep the full walkthrough up to date (`game/tests/walkthrough.advtest`): it tells
you right away if a change makes the game impossible to finish. You can also **record** a
game played by hand: start the game with `-- --adv-record=res://game/tests/new.advtest`
(or `record path` from the console), then add the `expect` lines.

### Check (lint)

It finds syntax errors, rooms/hotspots/items/characters/dialogs that don't exist (with
"did you mean...?" suggestions), missing entry points, exits to rooms that aren't there,
variables that are never assigned, hidden options that are never unlocked, hotspots with no
responses.

### From the terminal

```sh
python3 tools/adv.py lint
python3 tools/adv.py test
python3 tools/adv.py play "look sign; pick shovel" --new    # the state is kept between commands
python3 tools/adv.py shot screenshot.png
python3 tools/adv.py run          # starts the game with remote control enabled
python3 tools/adv.py live "scene" # sends a command to the running game
python3 tools/adv.py new-room cave "The cave"
```

It requires Python 3.8+; if `godot` is not in the PATH, set the `GODOT` environment
variable. The same tools are available directly from Godot with arguments after `--`:
`--adv-lint`, `--adv-test`, `--adv-run="commands"`, `--adv-remote=7777`, `--adv-start=room`,
`--adv-gui=scumm`, `--adv-fast`, `--adv-load`/`--adv-save`, `--adv-screenshot`,
`--adv-record`, `--adv-seed`, `--adv-game-dir`.

### Remote control

With `--adv-remote[=port]` (or *avventura/debug/remote_control* in debug builds) the game
accepts commands over TCP on `127.0.0.1`, one JSON line per command
(`{"id": 1, "cmd": "look sign"}`), with the reply `{"id", "ok", "output", "status"}`.

## 14. Working with Claude Code

The project is ready for Claude Code:

- **`CLAUDE.md`** explains the structure, the conventions and the language to Claude.
- **MCP server** (`.mcp.json`, file `tools/adv_mcp.py`, no dependencies): Claude can check
  (`adventure_lint`), test (`adventure_test`), **play** in a session that remembers the state
  (`adventure_play`), **see** the game (`adventure_screenshot`), create
  rooms/characters/items (`adventure_create`) and even drive the window you are playing in
  (`adventure_live`, after `python3 tools/adv.py run`).
  The first time, Claude Code asks you to approve the project's server.
- **Skills** in `.claude/skills/`: `playtest` (plays the game like a player and writes a
  report), `new-room` (creates a complete room), `new-puzzle` (designs and implements a
  puzzle together with its test).

Typical requests: *"add a cave reachable from the beach, with a puzzle about the tide"*,
*"do a playtest and tell me where a player gets stuck"*, *"make Nina's comments more varied
when an action doesn't work"*. Claude edits scripts and scenes, then checks its work with
lint, the tests, a playthrough and a screenshot.

## 15. Project settings

| Setting | Default | Meaning |
|---|---|---|
| `avventura/general/game_dir` | `res://game` | game folder |
| `avventura/gui/scene` | `two_click_gui.tscn` | interface |
| `avventura/gui/show_title_menu` | `true` | title menu |
| `avventura/general/source_language` | `it` | language the game's texts are written in |
| `avventura/general/intro_video` | `""` | video (in `game/video/`) shown on every *New game* from the title menu; it can't be skipped |
| `avventura/audio/music_fade` | `1.5` | seconds of crossfade between two tracks |
| `avventura/audio/music_resume_seconds` | `180` | a track played again within this time continues where it was |
| `avventura/audio/room_sound_fade` | `1.0` | seconds of fade-out for the sounds of the room being left |
| `avventura/gui/language` | `""` | starting language (`it`, `en`...; empty = the system's, if the game has it) |
| `avventura/text/seconds_per_character` | `0.05` | duration of the lines |
| `avventura/text/min_seconds` | `1.5` | minimum duration of a line |
| `avventura/interaction/walk_before_look` | `false` | walk up to things before looking at them |
| `avventura/dialog/player_says_options` | `true` | the player character says the chosen option |
| `avventura/debug/remote_control` | `false` | remote control in debug builds |
| `avventura/debug/remote_port` | `7777` | port of the remote control |
| `avventura/debug/console` | `true` | debug console |
| `avventura/debug/show_walk_areas` | `false` | shows the walkable areas while playing |

## 16. Exporting and translating

**Exporting.** Use Godot's normal *Project → Export*. The plugin adds the `.adv` files to
the package by itself (Godot already includes the `.po` translations and the `scene/*.json`
chapter starts as resources). The `tests/` and `tools/` folders aren't needed by the game: you
can exclude them in the export filters (*Filters to exclude files*: `tests/*, tools/*, docs/*`).

Once the presets exist (saved in `export_presets.cfg`) and Godot's export templates are
installed (*Editor → Manage Export Templates*), you can rebuild everything from a terminal:
`python3 tools/adv.py export` exports every preset to its path, `python3 tools/adv.py export
Windows Web` only the ones named. For the Web pick the variant without threads (*Thread
Support* off): the game then runs on any plain static hosting, with no special headers.

**Translations.** As in AGS, each language is a translation file: `game/lang/<code>.po`
(gettext format, it opens in any PO editor such as Poedit, or in a text editor). Each text
has the original (`msgid`) and the translation (`msgstr`); an empty translation leaves the
original text. The file is created and updated with:

```sh
python3 tools/adv.py i18n en      # creates or updates game/lang/en.po
```

It collects everything the player reads: lines (also `char@X,Y:`), dialog options, names
and descriptions of items and characters, the title, the names and descriptions of the
hotspots in the scenes, chapter titles and the texts in the game's GDScript files
(`tr("...")` and the "Name: text" lines of mini-games). Translations already done are kept;
texts gone from the game end up at the bottom as obsolete (`#~`). Run it again after every
change to the texts: new lines will have an empty translation. The `{expressions}` of the
lines must be copied as they are into the translation.

The player chooses the language in *Settings → Language* (it appears when there is at least
one translation) and the choice is saved; it switches live, without restarting. To try it:
`python3 tools/adv.py play "..." --lang en`, `shot ... --lang en`, `run --lang en`, or
`--adv-lang=en` to Godot. Tests (`.advtest`) always run in the original language.
The interface texts are already in English, Italian, German, Spanish and French
(`addons/avventura/i18n/avventura.csv`); add a column for other languages.

## 17. Importing an AGS game

`tools/ags/` converts games made with Adventure Game Studio 3.x (formats 3.0–3.6). The
easiest way is to import the whole AGS project folder into a new Godot project (containing
`addons/avventura` and `tools`):

```sh
python3 tools/ags/ags_import.py game PATH/AGS_FOLDER
```

From the folder it reads:

- `Game.agf`: title, resolution (also set in `project.godot`), characters with their text
  color, starting room and position, inventory items, global variables;
- `acsprset.spr`: the sprites. Each character becomes a scene
  `game/characters/<id>/<id>.tscn` with the animations taken from its *views* (`walk_*` and
  `idle_*` from the normal view, `talk_*` from the speech view, the other views used by
  `LockView` with their own name, e.g. `climb_down`); the edges of the frames are cleaned of
  the light halo left by cut-out sprites; the icons go into `game/items/`;
- GUIs that are just pictures (e.g. a full-screen picture) become *overlays* in
  `game/overlays/<id>.tscn`, shown with `show id` / `hide id`; the icon bar and the
  inventory window become the **AGS style** interface (`game/gui/ags_gui.json`,
  chapter 10); the other panels (saves, options) use the engine's menus;
- all the `roomN.crm` / `roomN.asc` files, the global script, the `.ogv`/`.webm` videos
  (into `game/video/`) and the audio, if the files are in the folder (otherwise the final
  list tells you which files to copy into `game/audio/` and under which names).

Single pieces can be imported as well:

```sh
# a room: background, walkable areas (with holes), hotspots, regions, walk-behinds, objects, script
python3 tools/ags/ags_import.py room PATH/room1.crm --asc PATH/room1.asc --player cRay
# the global script (character and object handlers, functions)
python3 tools/ags/ags_import.py script PATH/GlobalScript.asc --player cRay
# only the interface (icon bar + inventory window), without touching rooms and scripts
python3 tools/ags/ags_import.py gui PATH/AGS_FOLDER
# only the character graphics (scenes, animations, frames), without touching rooms and scripts
python3 tools/ags/ags_import.py characters PATH/AGS_FOLDER
# only the sprites, as PNG
python3 tools/ags/spr.py PATH/acsprset.spr --out folder/ [--only 26,37]
```

`--player` is the script name of the AGS player character. Masks become polygons,
walk-behinds become sprites cut out of the background and sorted at their *baseline*, room
edges with an event become the regions `edge_left`, `edge_right`... The code is translated
into AdvScript: `Say`, `SayAt` (`john@476,172: text`), `Walk` (also relative, and
`eAnywhere`), inventory, `ChangeRoom`, `SetAsPlayer`, dialogs, cutscenes, `Wait`,
`LockView`, `PlayVideo`, music and sounds, GUIs shown/hidden, the 9-verb *Verbs* module
(`AnyClick`, `UsedAction`, `MovePlayer`), `ActiveInventory`, `Game.DoOnceOnly`... Whatever it
can't translate stays in the file as `# TODO AGS:` with the original code; the original
script is copied into `rooms/<id>/ags/`. The check (lint) then lists the references that
still need fixing. Not imported yet: the dialog text from `Game.agf`, fonts and additional
script modules.
