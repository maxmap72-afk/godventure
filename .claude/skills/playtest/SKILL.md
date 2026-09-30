---
name: playtest
description: Playtest the Avventura adventure game like a player to check that puzzles make sense, text is right and the game can be finished. Use when asked to test, playtest, try or verify the game, or after changing rooms, dialogs or puzzles.
---

# Playtest the game

1. `adventure_lint` (or `python3 tools/adv.py lint`). Fix errors before playing.
2. Start fresh: `adventure_play` with `new_game: true` and `commands: "scene"`.
3. Explore like a curious player, a few commands per call:
   - `scene` lists hotspots (id, name, main verb), exits and your inventory.
   - Try `look X` on everything, the main verb of each hotspot, `talk to X`, items on things
     (`use ITEM on X`, `give ITEM to CHARACTER`), and item combinations.
   - In dialogs use `choose N`; read every option at least once.
4. Note problems as you go: missing or generic answers where a specific one is expected,
   typos, wrong names, hints that point nowhere, puzzles solvable only by luck, dead ends
   (an item used up before it's needed), dialog options that never appear.
5. Look at the game when layout matters: `adventure_screenshot` (the user can also watch
   with `adventure_live` on their window).
6. Run `adventure_test` to confirm the official walkthrough still passes.
7. Report: what you tried, what worked, a prioritized list of issues with file:line
   (find handlers with grep on `on VERB TARGET`), and proposed fixes. Only change files
   if the user asked for fixes.
