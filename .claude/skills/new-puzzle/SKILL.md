---
name: new-puzzle
description: Design and implement a puzzle in the Avventura game (items, dialog, state, walkthrough test). Use when asked to add a puzzle, quest, obstacle or item-based interaction.
---

# Add a puzzle

1. Understand the current solution: read `game/tests/walkthrough.advtest`, `game/game.adv`,
   `game/items.adv`, `game/characters.adv` and the room scripts involved.
2. Design it in one paragraph before writing code: goal, obstacle, how the player learns
   what to do (at least one hint: a description, a dialog line, a sign), the solution
   steps, and what changes afterwards. Avoid dead ends: items needed later must not be
   consumable earlier; every required hotspot must be findable (`scene`).
3. Declare new items in `game/items.adv` (`item id "Nome"` + `on look id:`), add icons to
   `game/items/` (SVG 64x64 is fine) or rely on the placeholder.
4. Implement with handlers: `on use ITEM on TARGET:`, `on give ITEM to CHARACTER:`,
   state in variables (`var` in game.adv, `set`), object `state`/`show`/`hide`, dialog
   options (`hidden` + `option on dialog.opt` to unlock them).
5. Write useful failure answers: specific `on use * on TARGET:` or `on use ITEM on *:`
   responses beat the generic `on * *`.
6. Add the steps (and `expect` checks on the state) to the walkthrough test in solution order.
7. `adventure_lint` (0 errors), `adventure_test` (all pass), then `adventure_play` a few
   wrong attempts to check the failure answers read well.
