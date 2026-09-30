---
name: new-room
description: Add a new room to the Avventura game end to end (scene, walk area, hotspots, exits both ways, script, test). Use when asked to create or add a room/location/scene to the adventure.
---

# Add a room

1. Pick a snake_case id and create it: `adventure_create` kind=room (or
   `python3 tools/adv.py new-room ID "Nome"`). This makes `game/rooms/ID/ID.tscn` and `ID.adv`.
2. Art: put a background at `game/rooms/ID/ID.svg|png` (1280x720) and set it as the
   `Background` Sprite2D texture (ext_resource `Texture2D`). SVG is fine for prototypes.
   Without art the room draws `background_color` and characters are placeholder puppets.
3. Edit `ID.tscn`:
   - `WalkArea` polygon: the floor where feet can go (Polygon2D child = obstacle).
   - Perspective: `far_y/far_scale/near_y/near_scale` on the root if the floor recedes.
   - One `AdvHotspot` (Area2D) per interesting thing, with a `CollisionPolygon2D` child,
     `display_name` (Italian, shown on hover), `walk_to` or a `WalkTo` Marker2D inside the
     walk area, `default_verb` (look/use/open/talk/pick...). Use `description`,
     `pickup_item` or `exit_to` when no script is needed.
   - Exits: hotspot with `exit_to = "other_room"`; in the other room add a Marker2D/AdvEntry
     named after this room (arrival point). Add the way back too.
4. Write `ID.adv`: `on enter:` (with `if first:`), `on look X:` for every hotspot, puzzle
   handlers (`on use ITEM on X:`), in Italian, in the voice of the player character.
5. Connect it: an exit or a `goto ID` from an existing room.
6. `adventure_lint` → 0 errors; `adventure_play` with `restart: true` then
   `goto ID`/walk there and `scene`; `adventure_screenshot` to check the layout
   (hotspot shapes vs art, walk area, scale).
7. Extend `game/tests/walkthrough.advtest` if the room is part of the solution; `adventure_test`.
