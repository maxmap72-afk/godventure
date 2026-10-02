extends Node
## Avventura engine singleton, available everywhere as `Adv`.
##
## It loads rooms, runs AdvScript and offers the same commands to GDScript:
##   await Adv.say("nina", "Hello!")
##   await Adv.walk("nina", "door")
##   Adv.inventory_add("key")
##   await Adv.change_room("beach", "pier")
## GUIs listen to its signals; tools and tests drive it through [AdvController].

signal game_started
signal room_entered(room_id: String)
signal room_exiting(room_id: String)
signal speech_started(char_id: String, text: String)
signal speech_finished(char_id: String)
signal choice_requested(options: Array)
signal choice_made(index: int)
signal inventory_changed(char_id: String)
signal item_selected(item_id: String)
signal busy_changed(busy: bool)
signal cutscene_changed(active: bool)
signal player_changed(char_id: String)
signal transcript_line(text: String)
signal action_performed(verb: String, target: String, item: String)
signal game_ended
signal notify(text: String)
signal line_skipped
signal skip_started

enum Mode { IDLE, BUSY, CHOICE }

const VERSION := "0.1.0"
const DIRECTIONS := ["left", "right", "up", "down"]
const DEFAULTS := {
	"avventura/general/game_dir": "res://game",
	"avventura/gui/scene": "res://addons/avventura/gui/two_click_gui.tscn",
	"avventura/gui/show_title_menu": true,
	"avventura/text/seconds_per_character": 0.05,
	"avventura/text/min_seconds": 1.5,
	"avventura/interaction/walk_before_look": false,
	"avventura/dialog/player_says_options": true,
	"avventura/debug/remote_control": false,
	"avventura/debug/remote_port": 7777,
	"avventura/debug/console": true,
	"avventura/debug/show_walk_areas": false,
}

var registry := AdvRegistry.new()
var state := AdvState.new()
var interp: AdvInterpreter
var controller: AdvController
## Current room node.
var room: AdvRoom
## Node of the character controlled by the player (in the current room).
var player: AdvCharacter
var world: Node2D
var camera: Camera2D
var gui: Node
## Optional res://game/game.gd, instantiated at start: its functions are callable from AdvScript.
var game_script: Node
var mode := Mode.IDLE
## Instant mode: no walking animation, no text delays. Used by tests and headless play.
var fast := false
## True while a cutscene is being skipped.
var skipping := false
var game_over := false
var selected_item := ""
## Incremented on new game / load: scripts from a previous game stop.
var generation := 0
var rng := RandomNumberGenerator.new()
var game_dir := "res://game"
var player_says_options := true
var walk_before_look := false
## Pixels covered by a GUI panel at the bottom (SCUMM interface): the camera can scroll above it.
var gui_bottom_margin := 0.0
var error_count := 0
## Characters currently speaking.
var speaking: Dictionary = {}
## Options waiting for a choice (texts).
var pending_choices: Array = []
## Parsed --adv-* command line arguments.
var args: Dictionary = {}
## Where save slots live (tests use their own folder, so they never touch the player's saves).
var save_dir := "user://saves"
## Player preferences (user://settings.cfg).
var prefs := {"text_speed": 1.0, "auto_advance": true, "music_volume": 0.8, "sfx_volume": 1.0, "fullscreen": false}

var _main: Node
const OVERLAYS := "_overlays"
var _overlay_layer: CanvasLayer
## Fixed screen positions of the lines being spoken (say with @X,Y).
var speech_pos: Dictionary = {}
var _fade_rect: ColorRect
var _follow: Node2D
var _approaching := false
var _interaction := 0
var _busy := 0
var _cutscene_depth := 0
var _in_transition := false
var _recent: PackedStringArray = PackedStringArray()
var _music: AudioStreamPlayer
var _music_name := ""
var _shake := 0.0
var _warned: Dictionary = {}
var _entered := 0
var _icons: Dictionary = {}
var _regions_inside: Dictionary = {}
var _playing_video := false


class _Waiter:
	extends RefCounted
	signal finished
	var _done := false

	func done(_a: Variant = null) -> void:
		if _done:
			return
		_done = true
		finished.emit()


func _ready() -> void:
	interp = AdvInterpreter.new(self)
	args = _parse_args()
	if args.has("test") or args.has("run") or args.has("run-file"):
		save_dir = "user://saves_test"
	game_dir = str(args.get("game-dir", setting("avventura/general/game_dir"))).trim_suffix("/")
	player_says_options = setting("avventura/dialog/player_says_options")
	walk_before_look = setting("avventura/interaction/walk_before_look")
	if args.has("seed"):
		rng.seed = int(args.seed)
	else:
		rng.randomize()
	_load_prefs()


static func setting(name: String) -> Variant:
	return ProjectSettings.get_setting(name, DEFAULTS.get(name))


## Starts the engine. Called by the main scene (addons/avventura/core/adv_main.tscn).
func boot(main: Node) -> void:
	_main = main
	reload_scripts()
	_build_world()
	controller = AdvController.new()
	controller.name = "Controller"
	controller.adv = self
	add_child(controller)
	var headless := DisplayServer.get_name() == "headless"
	var cli := args.has("lint") or args.has("test") or args.has("scaffold") or args.has("run") or args.has("run-file")
	if cli:
		# Command line runs must always end, even if a script error aborts a coroutine.
		var limit := float(args.get("timeout", 600))
		get_tree().create_timer(limit, true, false, true).timeout.connect(func():
			printerr("Avventura: timeout after %d seconds (a script error may have stopped the run)" % limit)
			get_tree().quit(2))
	fast = args.has("fast") or args.has("test") or args.has("run") or args.has("run-file") or args.has("lint")
	if not headless and not args.has("lint") and not args.has("test") and not args.has("scaffold"):
		_create_gui()
	if args.has("lint"):
		controller.cli_lint()
		return
	if args.has("test"):
		controller.cli_test(str(args.test))
		return
	if args.has("scaffold"):
		controller.cli_scaffold(str(args.scaffold))
		return
	if args.has("run") or args.has("run-file"):
		controller.cli_run()
		return
	if args.has("remote") or (OS.is_debug_build() and setting("avventura/debug/remote_control")):
		var port := int(args.remote) if str(args.get("remote", "")).is_valid_int() else int(setting("avventura/debug/remote_port"))
		controller.start_remote(port)
	if args.has("record"):
		controller.start_recording(str(args.record))
	if args.has("load"):
		await load_game(str(args.load))
	elif args.has("start") or gui == null or not setting("avventura/gui/show_title_menu"):
		await new_game(str(args.get("start", "")))
	else:
		gui.show_title()
	if args.has("screenshot"):
		await controller.cli_screenshot(str(args.screenshot))


func _parse_args() -> Dictionary:
	var out := {}
	for a in Array(OS.get_cmdline_args()) + Array(OS.get_cmdline_user_args()):
		if not a.begins_with("--adv-"):
			continue
		var s: String = a.substr(6)
		var eq := s.find("=")
		if eq == -1:
			out[s] = true
		else:
			out[s.left(eq)] = s.substr(eq + 1)
	return out


## (Re)loads all .adv scripts. Safe while playing: running scripts keep their code.
func reload_scripts() -> Array:
	registry.load_game(game_dir)
	_icons.clear()
	for i in registry.issues:
		if i.level == "error":
			printerr("%s:%d: %s" % [i.file, i.line, i.msg])
	return registry.issues


func _build_world() -> void:
	world = Node2D.new()
	world.name = "World"
	_main.add_child(world)
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	world.add_child(camera)
	camera.make_current()
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "Overlays"
	_overlay_layer.layer = 5
	_main.add_child(_overlay_layer)
	var layer := CanvasLayer.new()
	layer.name = "Fade"
	layer.layer = 100
	_main.add_child(layer)
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color.BLACK
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.modulate.a = 0.0
	layer.add_child(_fade_rect)
	_music = AudioStreamPlayer.new()
	_music.bus = _bus("Music")
	add_child(_music)
	_bus("SFX")
	_apply_prefs()
	var gd_path := game_dir + "/game.gd"
	if ResourceLoader.exists(gd_path):
		var s = load(gd_path)
		if s is Script:
			game_script = s.new()
			game_script.name = "GameScript"
			add_child(game_script)


func _create_gui() -> void:
	var path := str(args.get("gui", setting("avventura/gui/scene")))
	if not "/" in path:
		path = "res://addons/avventura/gui/%s_gui.tscn" % path  # --adv-gui=scumm | two_click
	if not ResourceLoader.exists(path):
		push_error("Avventura: GUI scene not found: " + path)
		return
	gui = load(path).instantiate()
	_main.add_child(gui)


func _process(delta: float) -> void:
	if room and not game_over and not get_tree().paused:
		state.playtime += delta
		if mode == Mode.IDLE:  # like AGS, region events wait for blocking scripts to end
			_check_regions()
	if camera == null:
		return
	if _follow and is_instance_valid(_follow):
		camera.global_position = _follow.global_position + Vector2(0, -60)
	if _shake > 0.0:
		_shake -= delta
		camera.offset = Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)) if _shake > 0.0 else Vector2.ZERO


# --- game and rooms -----------------------------------------------------------------------

## Starts a new game. [param start] can be "room" or "room:entry" to begin elsewhere.
func new_game(start: String = "") -> void:
	_reset_runtime()
	state = AdvState.new()
	game_over = false
	var ctx := interp.new_ctx("", "", "init")
	for v in registry.vars:
		ctx.file = v.file
		ctx.line = v.line
		state.vars[v.name] = interp.eval(v.expr, ctx)
	state.player = registry.game.player
	if state.player == "":
		state.player = registry.characters.keys()[0] if not registry.characters.is_empty() else "player"
	for id in registry.characters:
		var p: Dictionary = registry.characters[id].get("props", {})
		if p.has("room"):
			state.chars[id] = {"room": str(p.room), "at": str(p.get("at", "")), "pos": _vec(p.get("pos", "")), "dir": str(p.get("face", ""))}
	if not state.chars.has(state.player):
		state.chars[state.player] = {"room": "", "at": "", "pos": null, "dir": ""}
	var room_id: String = registry.game.start
	var at: String = registry.game.start_at
	if start != "":
		var parts := start.split(":")
		room_id = parts[0]
		at = parts[1] if parts.size() > 1 else ""
	if room_id == "" and not registry.rooms.is_empty():
		var ids := registry.rooms.keys()
		ids.sort()
		room_id = ids[0]
	if room_id == "":
		script_error("no rooms found in %s/rooms" % game_dir)
		return
	game_started.emit()
	log_line("[new game]")
	_set_busy(true)
	await _enter_room(room_id, at, "new")
	var h := registry.find_event("", "start")
	var entered := _entered
	if not h.is_empty() and not args.has("from-room"):
		await interp.run_handler(h)
	if _entered == entered and room:
		await _room_event("enter")
	_set_busy(false)


## Moves the player to another room, running `on exit` / `on setup` / `on enter`.
## [param pos] (room coordinates) places the player at an exact point instead of an entry.
func change_room(room_id: String, at: String = "", pos: Variant = null) -> void:
	if not registry.rooms.has(room_id):
		script_error("unknown room '%s' (rooms: %s)" % [room_id, ", ".join(registry.rooms.keys())])
		return
	_set_busy(true)
	await _enter_room(room_id, at, "goto", pos)
	_set_busy(false)


func _enter_room(room_id: String, at: String, how: String, pos: Variant = null) -> void:
	var from := state.room
	_in_transition = true
	if room:
		if how == "goto":
			await _room_event("exit")
			room_exiting.emit(from)
		await fade(true, 0.3)
		_store_characters()
		_unload_room()
	var scene = load(registry.rooms.get(room_id, ""))
	var node: Node = scene.instantiate() if scene is PackedScene else null
	if not node is AdvRoom:
		script_error("room '%s': the scene root must be an AdvRoom node" % room_id)
		if node:
			node.free()
		_in_transition = false
		return
	room = node
	state.room = room_id
	if how != "load":
		state.visited[room_id] = int(state.visited.get(room_id, 0)) + 1
	world.add_child(room)
	_apply_room_state()
	_spawn_characters()
	var pc := _ensure_player()
	if pc:
		var c: Dictionary = state.chars[state.player]
		if how == "load" or (at == "" and c.get("room", "") == room_id and c.get("pos") is Vector2 and how != "new"):
			pc.teleport(c.pos if c.get("pos") is Vector2 else pc.room_position())
			if str(c.get("dir", "")) in DIRECTIONS:
				pc.face_dir(c.dir)
		elif pos is Vector2:
			pc.teleport(pos)
		else:
			var e := _entry_point(at, from)
			pc.teleport(e.pos)
			if e.face != "":
				pc.face_dir(e.face)
		c.room = room_id
	_setup_camera()
	_regions_inside = _regions_at_player()
	log_line("[room] %s" % room_id)
	await _room_event("setup")
	if room == null:
		_in_transition = false
		return
	if room.music != "":
		play_music(room.music)
	await fade(false, 0.3)
	_in_transition = false
	room_entered.emit(room_id)
	if how == "goto":
		await _room_event("enter")


## Regions: `on walk_onto REGION:` / `on walk_off REGION:` when the player crosses them.
func _regions_at_player() -> Dictionary:
	var out := {}
	if room == null or player == null:
		return out
	var p := player.room_position()
	for r in room.get_regions():
		if r.enabled and r.contains(p, room):
			out[r.get_region_id()] = true
	return out


func _check_regions() -> void:
	if room == null or player == null or _in_transition:
		return
	var now := _regions_at_player()
	if now == _regions_inside:
		return
	var entered := []
	var left := []
	for id in now:
		if not _regions_inside.has(id):
			entered.append(id)
	for id in _regions_inside:
		if not now.has(id):
			left.append(id)
	_regions_inside = now
	for id in left:
		_region_event("walk_off", id)
	for id in entered:
		_region_event("walk_onto", id)


func _region_event(event: String, id: String) -> void:
	var h := registry.find_handler(state.room, event, id, "", false)
	if h.is_empty():
		return
	log_line("[region] %s %s" % [event, id])
	_set_busy(true)
	await interp.run_handler(h, {"verb": event, "target": id, "item": ""})
	_set_busy(false)


func _room_event(event: String) -> void:
	var h := registry.find_event(state.room, event)
	if h.is_empty():
		return
	if event == "enter":
		_entered += 1
	await interp.run_handler(h)


func _unload_room() -> void:
	if room == null:
		return
	world.remove_child(room)
	room.queue_free()
	room = null
	player = null
	_follow = null


## Applies saved object overrides (visibility, state, enabled) to the room nodes.
func _apply_room_state() -> void:
	_apply_overlays()
	var prefix := state.room + "/"
	for key in state.objects:
		if not key.begins_with(prefix):
			continue
		var id: String = key.substr(prefix.length())
		var o: Dictionary = state.objects[key]
		var n := _object_node(id)
		if n == null:
			continue
		if o.has("visible") and n is CanvasItem:
			n.visible = o.visible
		if o.has("enabled"):
			if n is AdvHotspot:
				n.interactive = o.enabled
			elif n is AdvWalkArea or n is AdvRegion:
				n.enabled = o.enabled
		if o.has("state"):
			_apply_state(n, str(o.state))
	# Characters managed by the engine that are elsewhere now.
	for h in room.get_hotspots():
		if h is AdvCharacter and state.chars.has(h.get_id()) and state.chars[h.get_id()].get("room", "") != state.room:
			h.get_parent().remove_child(h)
			h.queue_free()
	room.rebuild_walkable()


func _spawn_characters() -> void:
	for id in state.chars:
		var c: Dictionary = state.chars[id]
		if c.get("room", "") != state.room:
			continue
		var node := get_character(id)
		if node == null:
			node = create_character(id)
			room.add_child(node)
		if c.get("pos") is Vector2:
			node.teleport(c.pos)
		elif str(c.get("at", "")) != "":
			var e := _entry_point(str(c.at), "")
			node.teleport(e.pos)
		if str(c.get("dir", "")) in DIRECTIONS:
			node.face_dir(c.dir)


func _ensure_player() -> AdvCharacter:
	var node := get_character(state.player)
	if node == null and state.player != "":
		node = create_character(state.player)
		room.add_child(node)
	player = node
	return node


func _store_characters() -> void:
	if room == null:
		return
	for h in room.get_hotspots():
		if h is AdvCharacter and state.chars.has(h.get_id()):
			var c: Dictionary = state.chars[h.get_id()]
			c.pos = h.room_position()
			c.dir = h.direction


## Where to put the player: entry [param at], else a marker named like the previous
## room, else "default"/"start", else the middle of the walk area.
func _entry_point(at: String, from: String) -> Dictionary:
	var names := [at] if at != "" else [from, "default", "start"]
	for id in names:
		if id == "":
			continue
		var m := room.find_marker(id)
		if m == null:
			continue
		var face := ""
		var pos: Vector2
		if m is AdvHotspot:
			pos = room.to_local(m.get_walk_point(m.global_position))
			if m.face != "auto":
				face = m.face
		else:
			pos = room.to_local(m.global_position)
			if m is AdvEntry and m.face != "auto":
				face = m.face
		return {"pos": pos, "face": face}
	if at != "":
		script_error("room '%s' has no entry point '%s' (markers: %s)" % [state.room, at, ", ".join(room.get_markers())])
	var s := room.get_size()
	return {"pos": room.closest_walkable(Vector2(s.x / 2.0, s.y * 0.8)), "face": ""}


func _setup_camera() -> void:
	var s := room.get_size()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(s.x)
	camera.limit_bottom = int(s.y + gui_bottom_margin)
	_follow = player if room.camera_follow and player else null
	if _follow:
		camera.global_position = _follow.global_position
	else:
		camera.global_position = room.to_global(s / 2.0)
	camera.reset_smoothing()


# --- characters ---------------------------------------------------------------------------

func resolve_char(who: String) -> String:
	return state.player if who == "player" else who


## The node of a character in the current room (null when not here).
func get_character(id: String) -> AdvCharacter:
	id = resolve_char(id)
	if room == null:
		return null
	for h in room.get_hotspots():
		if h is AdvCharacter and h.get_id() == id and not h.is_queued_for_deletion():
			return h
	return null


## Creates a character node from its scene (game/characters/<id>/<id>.tscn) or a placeholder,
## applying the properties of its `character` declaration.
func create_character(id: String) -> AdvCharacter:
	var decl: Dictionary = registry.characters.get(id, {})
	var node: AdvCharacter
	var scene_path: String = decl.get("scene", "")
	if scene_path != "":
		var inst = load(scene_path).instantiate()
		if inst is AdvCharacter:
			node = inst
		else:
			script_error("character scene %s: the root must be an AdvCharacter" % scene_path)
			if inst:
				inst.free()
	if node == null:
		node = AdvCharacter.new()
	node.hotspot_id = id
	node.name = id
	if decl.get("name", "") != "":
		node.display_name = decl.name
	var p: Dictionary = decl.get("props", {})
	if p.has("color"):
		node.text_color = Color.from_string(str(p.color), node.text_color)
		if scene_path == "":
			node.body_color = node.text_color.darkened(0.15)
	if p.has("body"):
		node.body_color = Color.from_string(str(p.body), node.body_color)
	if p.has("skin"):
		node.skin_color = Color.from_string(str(p.skin), node.skin_color)
	if p.has("hair"):
		node.hair_color = Color.from_string(str(p.hair), node.hair_color)
	if p.has("speed"):
		node.walk_speed = float(p.speed)
	if p.has("height"):
		node.height = float(p.height)
	if p.has("description"):
		node.description = str(p.description)
	return node


func character_room(id: String) -> String:
	id = resolve_char(id)
	if state.chars.has(id):
		return str(state.chars[id].get("room", ""))
	return state.room if get_character(id) else ""


## Moves a character: to a target in the current room, or into another room.
func place(who: String, room_id: String, loc: Variant) -> void:
	var id := resolve_char(who)
	if room_id == "":
		room_id = state.room
	if not registry.rooms.has(room_id):
		script_error("place: unknown room '%s'" % room_id)
		return
	if not state.chars.has(id):
		state.chars[id] = {"room": "", "at": "", "pos": null, "dir": ""}
	var c: Dictionary = state.chars[id]
	var old_room: String = c.get("room", "")
	if id == state.player and room_id != state.room:
		script_error("place: use 'goto' to move the player to another room")
		return
	c.room = room_id
	c.at = loc if loc is String else ""
	c.pos = loc if loc is Vector2 else null
	if room_id == state.room and room:
		var node := get_character(id)
		if node == null:
			node = create_character(id)
			room.add_child(node)
		var p = position_of(loc, node) if loc != null else _entry_point("", "").pos
		if p != null:
			node.teleport(p)
			c.pos = p
	elif old_room == state.room and room:
		var node := get_character(id)
		if node:
			node.get_parent().remove_child(node)
			node.queue_free()


## Switches the character controlled by the player (Maniac Mansion style).
func set_player(id: String) -> void:
	if not state.chars.has(id):
		if get_character(id) == null:
			script_error("control: character '%s' is not placed in any room (use 'place %s in ROOM')" % [id, id])
			return
		state.chars[id] = {"room": state.room, "at": "", "pos": get_character(id).room_position(), "dir": ""}
	_store_characters()
	state.player = id
	var r: String = state.chars[id].get("room", "")
	if r != state.room and r != "":
		await change_room(r)
	else:
		player = get_character(id)
		if room and room.camera_follow:
			_follow = player
	player_changed.emit(id)
	inventory_changed.emit(id)


# --- player actions -----------------------------------------------------------------------

## Is the game waiting for the player? (no script, no walk, no transition)
func is_idle() -> bool:
	return mode == Mode.IDLE and not _approaching and not _in_transition and (player == null or not player.is_walking)


## Can the player click on things now? (walking can be interrupted by a new click)
func accepts_input() -> bool:
	return mode == Mode.IDLE and not _in_transition and _cutscene_depth == 0 and not game_over and room != null


## Performs a player action, exactly like a click: walks to the target, then runs the
## matching `on VERB TARGET` (or `on VERB ITEM on TARGET`) handler.
func perform(verb: String, target: String, item: String = "", instant: bool = false) -> void:
	if not accepts_input():
		return
	var hs: AdvHotspot = room.find_hotspot(target)
	if hs and (not hs.is_visible_in_tree() or not hs.interactive):
		hs = null
	var inv := hs == null and has_item(target)
	if hs == null and not inv:
		log_line("[nothing] there is no '%s' here" % target)
		return
	if item != "" and not has_item(item):
		log_line("[nothing] you don't have '%s'" % item)
		return
	action_performed.emit(verb, target, item)
	_interaction += 1
	var my := _interaction
	if hs and hs != player and player:
		if hs.walk_before and (verb != "look" or walk_before_look):
			var ok := await _approach(hs, my, instant)
			if my != _interaction:
				return
			if not ok:
				log_line("[unreachable] %s" % target)
		else:
			player.face_towards(hs.global_position)
	if not accepts_input():
		return
	_set_busy(true)
	var locals := {"verb": verb, "target": target, "item": item}
	var h := registry.find_handler(state.room, verb, target, item, false)
	if item != "" and h.is_empty() and verb == "use" and hs is AdvCharacter:
		h = registry.find_handler(state.room, "give", target, item, false)
	if not h.is_empty():
		await interp.run_handler(h, locals)
	else:
		var done: bool = await _builtin(verb, hs, target, item)
		if not done:
			h = registry.find_handler(state.room, verb, target, item, true)
			if not h.is_empty():
				await interp.run_handler(h, locals)
			else:
				await say(state.player, tr(_fallback_line(verb)))
	_set_busy(false)


## Walks the player to a point of the room (floor click). Cancels a pending action.
func walk_player(to: Vector2) -> void:
	if not accepts_input() or player == null:
		return
	_interaction += 1
	_approaching = false
	if fast:
		_jump(player, to)
	else:
		player.move_to(to)


func _approach(hs: AdvHotspot, my: int, instant: bool) -> bool:
	var dest := room.to_local(hs.get_walk_point(player.global_position))
	_approaching = true
	var ok := true
	if fast or skipping or instant:
		ok = _jump(player, dest)
	else:
		ok = await player.move_to(dest)
	if my != _interaction:
		return false
	_approaching = false
	if hs.face != "auto":
		player.face_dir(hs.face)
	else:
		player.face_towards(hs.global_position)
	if hs is AdvCharacter:
		hs.face_towards(player.global_position)
	return ok


func _builtin(verb: String, hs: AdvHotspot, target: String, item: String) -> bool:
	if item != "":
		return false
	if hs == null:
		if verb == "look":
			var desc := str(registry.items.get(target, {}).get("props", {}).get("description", ""))
			if desc != "":
				await say(state.player, tr(desc))
				return true
		return false
	if hs.is_exit() and (verb == "walk" or verb == hs.get_default_verb()):
		await change_room(hs.exit_to, hs.exit_entry)
		return true
	if verb == "walk":
		return true
	if verb == "look" and hs.description != "":
		await say(state.player, tr(hs.description))
		return true
	if verb == "pick" and hs.pickup_item != "":
		await pickup(hs.get_id(), hs.pickup_item)
		return true
	return false


func _fallback_line(verb: String) -> String:
	match verb:
		"look":
			return "Nothing special."
		"talk":
			return "No answer."
		"pick":
			return "I can't pick that up."
		"open":
			return "It doesn't open."
		"close":
			return "It doesn't close."
		"push", "pull":
			return "It won't move."
	return "That doesn't work."


func select_item(item: String) -> void:
	if item != "" and not has_item(item):
		return
	selected_item = item
	item_selected.emit(item)


# --- commands used by scripts -------------------------------------------------------------

## Shows a line of dialogue and waits for it (click to skip).
## [param at]: optional fixed screen position of the text (top-left), like AGS SayAt.
func say(who: String, text: String, mood: String = "", at: Variant = null) -> void:
	var id := resolve_char(who)
	log_line("%s: %s" % [id, text])
	var ch := get_character(id)
	speaking[id] = true
	if at is Vector2:
		speech_pos[id] = at
	else:
		speech_pos.erase(id)
	speech_started.emit(id, text)
	if ch:
		ch.start_talking(mood)
	if not (fast or skipping):
		var secs := maxf(float(setting("avventura/text/min_seconds")), text.length() * float(setting("avventura/text/seconds_per_character")))
		secs /= maxf(float(prefs.text_speed), 0.1)
		var w := _Waiter.new()
		if prefs.auto_advance:
			get_tree().create_timer(secs, false).timeout.connect(w.done)
		line_skipped.connect(w.done, CONNECT_ONE_SHOT)
		await w.finished
	if ch and is_instance_valid(ch):
		ch.stop_talking()
	speaking.erase(id)
	speech_finished.emit(id)
	speech_pos.erase(id)


func skip_line() -> void:
	line_skipped.emit()


func is_speaking() -> bool:
	return not speaking.is_empty()


func walk(who: String, target: Variant, wait_arrival: bool = true, anywhere: bool = false) -> void:
	var ch := get_character(who)
	if ch == null:
		script_error("walk: '%s' is not in room '%s'" % [resolve_char(who), state.room])
		return
	var pos = position_of(target, ch)
	if pos == null:
		return
	if fast or skipping:
		if anywhere:
			ch.stop()
			ch.set_room_position(pos)
		else:
			_jump(ch, pos)
		return
	if wait_arrival:
		await ch.move_to(pos, anywhere)
	else:
		ch.move_to(pos, anywhere)


## Instant move that still respects the walk areas: false (and no move) when unreachable.
func _jump(ch: AdvCharacter, dest: Vector2) -> bool:
	var path := room.find_path(ch.room_position(), dest) if room else PackedVector2Array([dest])
	if path.is_empty():
		return false
	ch.teleport(path[path.size() - 1])
	return true


func face(who: String, to: String) -> void:
	var ch := get_character(who)
	if ch == null:
		script_error("face: '%s' is not in room '%s'" % [resolve_char(who), state.room])
		return
	if to in DIRECTIONS:
		ch.face_dir(to)
		return
	var n := room.find_marker(resolve_char(to))
	if n == null:
		script_error("face: unknown target '%s'" % to)
		return
	ch.face_towards(n.global_position)


func anim(who: String, anim_name: String, wait_end: bool = true, loop: bool = false) -> void:
	var ch := get_character(who)
	if ch == null:
		script_error("anim: '%s' is not in room '%s'" % [resolve_char(who), state.room])
		return
	if fast or skipping:
		if loop or anim_name in ["idle", "stop"]:
			ch.play_anim(anim_name, false, loop)
		return
	if wait_end:
		await ch.play_anim(anim_name, true, loop)
	else:
		ch.play_anim(anim_name, false, loop)


func wait(secs: float) -> void:
	if fast or skipping or secs <= 0.0:
		return
	var w := _Waiter.new()
	get_tree().create_timer(secs, false).timeout.connect(w.done)
	skip_started.connect(w.done, CONNECT_ONE_SHOT)
	await w.finished


## A position in room coordinates: a Vector2, or the walk point of a hotspot/marker/character.
func position_of(target: Variant, walker: Node2D = null) -> Variant:
	if target is Vector2:
		return target
	var id := resolve_char(str(target))
	var n: Node2D = room.find_marker(id) if room else null
	if n == null:
		script_error("unknown target '%s' in room '%s'" % [id, state.room])
		return null
	if n is AdvHotspot:
		return room.to_local(n.get_walk_point(walker.global_position if walker else n.global_position))
	return room.to_local(n.global_position)


func inventory_add(item: String, who: String = "player") -> void:
	var id := resolve_char(who)
	if not registry.items.has(item):
		_warn_once("item '%s' is not declared (add a line: item %s \"Name\")" % [item, item])
	var inv := state.items_of(id)
	if item in inv:
		return
	inv.append(item)
	log_line("[+%s] %s" % ["" if id == state.player else " " + id, item])
	inventory_changed.emit(id)


func inventory_remove(item: String, who: String = "player") -> void:
	var id := resolve_char(who)
	var inv := state.items_of(id)
	if not item in inv:
		return
	inv.erase(item)
	if selected_item == item and id == state.player:
		select_item("")
	log_line("[-%s] %s" % ["" if id == state.player else " " + id, item])
	inventory_changed.emit(id)


func has_item(item: String, who: String = "") -> bool:
	var id := resolve_char(who if who != "" else "player")
	return item in state.items_of(id)


## Walks to an object, picks it up (hides it) and adds the item to the inventory.
func pickup(obj: String, item: String = "") -> void:
	var hs: AdvHotspot = room.find_hotspot(obj) if room else null
	if item == "":
		item = hs.pickup_item if hs and hs.pickup_item != "" else obj
	if hs and player and hs != player and (fast or skipping):
		_jump(player, room.to_local(hs.get_walk_point(player.global_position)))
	elif hs and player and hs != player:
		var dest := room.to_local(hs.get_walk_point(player.global_position))
		if player.room_position().distance_to(dest) > 12.0:
			await player.move_to(dest)
		player.face_towards(hs.global_position)
		if player.has_anim("pickup"):
			await player.play_anim("pickup")
		else:
			player.play_anim("pickup", false)
			await wait(0.35)
	if hs:
		set_object_visible(obj, false)
	inventory_add(item)


func set_object_visible(obj: String, value: bool, room_id: String = "") -> void:
	_set_object(obj, "visible", value, room_id)


func set_object_enabled(obj: String, value: bool, room_id: String = "") -> void:
	_set_object(obj, "enabled", value, room_id)


func set_object_state(obj: String, value: String, room_id: String = "") -> void:
	_set_object(obj, "state", value, room_id)


func _set_object(obj: String, key: String, value: Variant, room_id: String) -> void:
	if key == "visible" and room_id == "" and registry.overlays.has(obj) and _object_node(obj) == null:
		set_overlay_visible(obj, value)
		return
	var rid := room_id if room_id != "" else state.room
	if not registry.rooms.has(rid):
		script_error("unknown room '%s'" % rid)
		return
	state.set_object(rid, obj, key, value)
	if rid != state.room or room == null:
		return
	var n := _object_node(obj)
	if n == null:
		script_error("room '%s' has no object '%s'" % [rid, obj])
		return
	match key:
		"visible":
			if n is CanvasItem:
				n.visible = value
		"enabled":
			if n is AdvHotspot:
				n.interactive = value
			elif n is AdvWalkArea:
				n.enabled = value
				room.rebuild_walkable()
			elif n is AdvRegion:
				n.enabled = value
		"state":
			_apply_state(n, str(value))


func _apply_state(n: Node, value: String) -> void:
	if n is AdvHotspot:
		n.set_state(value)
	elif n is AnimatedSprite2D and n.sprite_frames and n.sprite_frames.has_animation(value):
		n.play(value)
	elif n is AnimationPlayer and n.has_animation(value):
		n.play(value)


func _object_node(id: String) -> Node:
	if room == null:
		return null
	var h := room.find_hotspot(id)
	if h:
		return h
	var a := room.find_walk_area(id)
	if a:
		return a
	for r in room.get_regions():
		if r.get_region_id() == id:
			return r
	return room.find_marker(id)


func get_object_state(obj: String, room_id: String = "") -> String:
	var rid := room_id if room_id != "" else state.room
	var o := state.object(rid, obj)
	if o.has("state"):
		return str(o.state)
	if rid == state.room:
		var h := room.find_hotspot(obj) if room else null
		if h:
			return h.state
	return ""


func is_object_visible(obj: String, room_id: String = "") -> bool:
	if room_id == "" and registry.overlays.has(obj) and _object_node(obj) == null:
		return bool(state.object(OVERLAYS, obj).get("visible", false))
	var rid := room_id if room_id != "" else state.room
	var o := state.object(rid, obj)
	if o.has("visible"):
		return o.visible
	if rid == state.room:
		var n := _object_node(obj)
		if n is CanvasItem:
			return n.visible
	return true


func is_object_enabled(obj: String, room_id: String = "") -> bool:
	var rid := room_id if room_id != "" else state.room
	var o := state.object(rid, obj)
	if o.has("enabled"):
		return o.enabled
	if rid == state.room:
		var n := _object_node(obj)
		if n is AdvHotspot:
			return n.interactive
		if n is AdvWalkArea or n is AdvRegion:
			return n.enabled
	return true


func set_option(ref: String, on: bool) -> void:
	var parts := ref.split(".")
	var d: Dictionary = registry.dialogs.get(parts[0], {})
	var found := false
	if parts.size() == 2 and not d.is_empty():
		for o in d.options:
			if o.id == parts[1]:
				found = true
				break
	if not found:
		script_error("option: unknown dialog option '%s'" % ref)
		return
	state.option(ref).on = on


func get_var(name: String) -> Variant:
	return state.vars.get(name, null)


func set_var(name: String, value: Variant) -> void:
	state.vars[name] = value


# --- dialogs, cutscenes, fades ----------------------------------------------------------------

## Shows dialog options and waits for the choice. Returns the index (or -1 if aborted).
func request_choice(texts: Array) -> int:
	pending_choices = texts.duplicate()
	mode = Mode.CHOICE
	var shown := []
	for i in texts.size():
		shown.append("%d) %s" % [i + 1, texts[i]])
	log_line("[choose] " + "  ".join(shown))
	choice_requested.emit(texts)
	var idx: int = await choice_made
	pending_choices = []
	if mode == Mode.CHOICE:
		mode = Mode.BUSY if _busy > 0 else Mode.IDLE
	return idx


func choose(index: int) -> void:
	if mode != Mode.CHOICE or index < 0 or index >= pending_choices.size():
		return
	mode = Mode.BUSY
	choice_made.emit(index)


func begin_cutscene() -> void:
	_cutscene_depth += 1
	if _cutscene_depth == 1:
		cutscene_changed.emit(true)


func end_cutscene() -> void:
	_cutscene_depth = maxi(0, _cutscene_depth - 1)
	if _cutscene_depth == 0:
		skipping = false
		cutscene_changed.emit(false)


func in_cutscene() -> bool:
	return _cutscene_depth > 0


## Fast-forwards the running cutscene (Esc).
func skip_cutscene() -> void:
	if _cutscene_depth > 0 and not skipping:
		skipping = true
		log_line("[skip]")
		skip_started.emit()
		line_skipped.emit()


func fade(out: bool, secs: float = 0.5) -> void:
	if _fade_rect == null:
		return
	var target := 1.0 if out else 0.0
	if fast or skipping or secs <= 0.0:
		_fade_rect.modulate.a = target
		return
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", target, secs)
	await tw.finished


func end_game() -> void:
	game_over = true
	log_line("[game ended]")
	game_ended.emit()


# --- camera and audio ---------------------------------------------------------------------------

func camera_follow(who: String) -> void:
	_follow = get_character(who)


func camera_to(target: Variant, secs: float = 0.0) -> void:
	_follow = null
	var p: Variant = target
	if not target is Vector2:
		var n: Node2D = room.find_marker(resolve_char(str(target))) if room else null
		if n == null:
			script_error("camera: unknown target '%s'" % target)
			return
		p = room.to_local(n.global_position)
	var gp: Vector2 = room.to_global(p)
	if fast or skipping or secs <= 0.0:
		camera.global_position = gp
		camera.reset_smoothing()
		return
	camera.position_smoothing_enabled = false
	var tw := create_tween()
	tw.tween_property(camera, "global_position", gp, secs).set_trans(Tween.TRANS_SINE)
	await tw.finished
	camera.position_smoothing_enabled = true


func camera_shake(secs: float = 0.5) -> void:
	_shake = secs


func play_sound(sound_name: String) -> void:
	var stream := _audio(sound_name)
	if stream == null:
		_warn_once("sound '%s' not found in %s/audio" % [sound_name, game_dir])
		return
	log_line("[sound] " + sound_name)
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "SFX"
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


func play_music(music_name: String) -> void:
	if music_name == _music_name and _music.playing:
		return
	var stream := _audio(music_name)
	if stream == null:
		_warn_once("music '%s' not found in %s/audio" % [music_name, game_dir])
		return
	if "loop" in stream:
		stream.loop = true
	_music_name = music_name
	_music.stream = stream
	_music.play()


## Plays a full-screen video (game/video/NAME.ogv). Click or Esc skips it.
func play_video(video_name: String) -> void:
	var path := _video_path(video_name)
	if path == "":
		_warn_once("video '%s' not found in %s/video" % [video_name, game_dir])
		return
	log_line("[video] " + video_name)
	if fast or skipping or DisplayServer.get_name() == "headless":
		return
	var layer := CanvasLayer.new()
	layer.layer = 90
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var player_node := VideoStreamPlayer.new()
	player_node.stream = load(path)
	player_node.expand = true
	player_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	player_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(player_node)
	add_child(layer)
	var w := _Waiter.new()
	player_node.finished.connect(w.done)
	line_skipped.connect(w.done, CONNECT_ONE_SHOT)
	skip_started.connect(w.done, CONNECT_ONE_SHOT)
	_playing_video = true
	player_node.play()
	await w.finished
	_playing_video = false
	layer.queue_free()


func _video_path(video_name: String) -> String:
	for dir in ["video", "videos", "audio"]:
		for ext in ["ogv", "webm"]:
			var p := "%s/%s/%s.%s" % [game_dir, dir, video_name, ext]
			if ResourceLoader.exists(p) or FileAccess.file_exists(p):
				return p
	return ""


func is_playing_video() -> bool:
	return _playing_video


func stop_music() -> void:
	_music_name = ""
	if _music:
		_music.stop()


func _audio(sound_name: String) -> AudioStream:
	for dir in ["audio", "music", "sounds"]:
		for ext in ["ogg", "wav", "mp3"]:
			var p := "%s/%s/%s.%s" % [game_dir, dir, sound_name, ext]
			if ResourceLoader.exists(p):
				return load(p)
	return null


func _bus(bus_name: String) -> String:
	if AudioServer.get_bus_index(bus_name) == -1:
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")
	return bus_name


# --- queries for GUIs and tools -----------------------------------------------------------------

## The topmost interactive hotspot at a world position.
func hotspot_at(world_pos: Vector2) -> AdvHotspot:
	if room == null:
		return null
	var best: AdvHotspot = null
	var best_key := []
	for h in room.get_hotspots():
		if h == player or not h.interactive or not h.is_visible_in_tree():
			continue
		if not h.contains_point(world_pos):
			continue
		var key := [h.click_priority, 1 if h is AdvCharacter else 0, h.z_index, -_click_area(h)]
		if best == null or key > best_key:
			best = h
			best_key = key
	return best


func _click_area(h: AdvHotspot) -> float:
	for c in h.get_children():
		if c is CollisionPolygon2D:
			var a := 0.0
			var p: PackedVector2Array = c.polygon
			for i in p.size():
				a += p[i].cross(p[(i + 1) % p.size()])
			return absf(a) / 2.0
		if c is CollisionShape2D and c.shape:
			var r: Rect2 = c.shape.get_rect()
			return r.size.x * r.size.y
		if c is Sprite2D or c is AnimatedSprite2D:
			var r := AdvHotspot.sprite_rect(c)
			return r.size.x * r.size.y
	var fr := h._fallback_rect()
	return fr.size.x * fr.size.y if fr.size != Vector2.ZERO else 1e9


func screen_to_world(screen_pos: Vector2) -> Vector2:
	return world.get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func world_to_screen(world_pos: Vector2) -> Vector2:
	return world.get_viewport().get_canvas_transform() * world_pos


## Screen position above a speaking character (null when not in the room).
func speech_anchor(char_id: String) -> Variant:
	var ch := get_character(char_id)
	if ch:
		return world_to_screen(ch.get_speech_anchor())
	# Objects can talk too (a parrot, a talking skull...): above their shape.
	var h: AdvHotspot = room.find_hotspot(char_id) if room else null
	if h and h.is_visible_in_tree():
		var b := h.get_global_bounds()
		return world_to_screen(Vector2(b.get_center().x, b.position.y - 10))
	return null


func display_name(id: String) -> String:
	if room:
		var h := room.find_hotspot(id)
		if h:
			return tr(h.get_display_name())
	if registry.items.has(id):
		return tr(registry.item_name(id))
	var c: Dictionary = registry.characters.get(id, {})
	if c.get("name", "") != "":
		return tr(c.name)
	return tr(id.capitalize())


func text_color(char_id: String) -> Color:
	var ch := get_character(char_id)
	if ch:
		return ch.text_color
	var p: Dictionary = registry.characters.get(resolve_char(char_id), {}).get("props", {})
	if p.has("color"):
		return Color.from_string(str(p.color), Color.WHITE)
	return Color(0.95, 0.95, 0.95)


func item_icon(item: String) -> Texture2D:
	# Cached: textures must stay referenced while the GUI draws them.
	if _icons.has(item):
		return _icons[item]
	var tex := _find_item_icon(item)
	_icons[item] = tex
	return tex


func _find_item_icon(item: String) -> Texture2D:
	var p: Dictionary = registry.items.get(item, {}).get("props", {})
	var candidates := []
	if p.has("icon"):
		candidates.append(str(p.icon))
	for ext in ["png", "svg", "webp"]:
		candidates.append("%s/items/%s.%s" % [game_dir, item, ext])
	for path in candidates:
		if ResourceLoader.exists(path):
			var t = load(path)
			if t is Texture2D:
				return t
	return null


func item_color(item: String) -> Color:
	var p: Dictionary = registry.items.get(item, {}).get("props", {})
	if p.has("color"):
		return Color.from_string(str(p.color), Color(0.6, 0.5, 0.35))
	return Color.from_hsv(float(hash(item) % 360) / 360.0, 0.45, 0.75)


func player_items() -> Array:
	return state.items_of(state.player).duplicate()


func recently_said(text: String) -> bool:
	var t := text.to_lower()
	for line in _recent:
		if t in line.to_lower():
			return true
	return false


func clear_recent() -> void:
	_recent = PackedStringArray()


## A GDScript object (room script or game.gd) that has [param method].
func find_script_method(method: String) -> Object:
	if room and room.has_method(method):
		return room
	if game_script and game_script.has_method(method):
		return game_script
	return null


# --- save / load -----------------------------------------------------------------------------

func can_save() -> bool:
	return mode == Mode.IDLE and not _in_transition and _cutscene_depth == 0 and room != null and not game_over


func save_game(slot: String) -> bool:
	if room == null:
		return false
	_store_characters()
	var path := save_path(slot)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var data := state.to_dict()
	data["meta"] = {"title": registry.game.title, "room_name": room.get_display_name(),
		"time": Time.get_datetime_string_from_system(false, true), "engine": VERSION}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		script_error("cannot write save file %s" % path)
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	log_line("[saved] %s" % path)
	return true


func load_game(slot: String) -> bool:
	var path := save_path(slot)
	if not FileAccess.file_exists(path):
		script_error("save file not found: %s" % path)
		return false
	var s := AdvState.from_json(FileAccess.get_file_as_string(path))
	if s == null or not registry.rooms.has(s.room):
		script_error("invalid save file: %s" % path)
		return false
	_reset_runtime()
	state = s
	game_over = false
	_set_busy(true)
	await _enter_room(state.room, "", "load")
	_set_busy(false)
	log_line("[loaded] %s" % path)
	return true


func save_path(slot: String) -> String:
	if slot.contains("/") or slot.ends_with(".json"):
		return slot
	return "%s/%s.json" % [save_dir, slot]


## Save slots with their metadata, newest first.
func list_saves() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(save_dir):
		return out
	for f in DirAccess.get_files_at(save_dir):
		if f.get_extension() != "json":
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(save_dir + "/" + f))
		if data is Dictionary:
			out.append({"slot": f.get_basename(), "meta": data.get("meta", {}),
				"modified": FileAccess.get_modified_time(save_dir + "/" + f)})
	out.sort_custom(func(a, b): return a.modified > b.modified)
	return out


# --- overlays ----------------------------------------------------------------------------------

## Shows or hides a full-screen overlay (game/overlays/ID.tscn), drawn above the room and
## below the interface. Imported AGS GUIs become overlays.
func set_overlay_visible(id: String, value: bool) -> void:
	state.set_object(OVERLAYS, id, "visible", value)
	log_line("[overlay] %s %s" % [id, "show" if value else "hide"])
	_apply_overlays()


func _apply_overlays() -> void:
	if _overlay_layer == null:
		return
	for c in _overlay_layer.get_children():
		if not bool(state.object(OVERLAYS, str(c.name)).get("visible", false)):
			_overlay_layer.remove_child(c)
			c.queue_free()
	for id in registry.overlays:
		if bool(state.object(OVERLAYS, id).get("visible", false)) and not _overlay_layer.has_node(NodePath(id)):
			var inst: Node = load(registry.overlays[id]).instantiate()
			inst.name = id
			_overlay_layer.add_child(inst)


# --- internals ---------------------------------------------------------------------------------

func _reset_runtime() -> void:
	generation += 1
	_interaction += 1
	_approaching = false
	_busy = 0
	_cutscene_depth = 0
	skipping = false
	mode = Mode.IDLE
	speaking.clear()
	speech_pos.clear()
	selected_item = ""
	pending_choices = []
	_in_transition = false
	line_skipped.emit()
	skip_started.emit()
	choice_made.emit(-1)
	item_selected.emit("")
	cutscene_changed.emit(false)
	if _fade_rect:
		_fade_rect.modulate.a = 0.0


func _set_busy(b: bool) -> void:
	_busy = _busy + 1 if b else maxi(0, _busy - 1)
	if mode == Mode.CHOICE:
		return
	var m := Mode.BUSY if _busy > 0 else Mode.IDLE
	if m != mode:
		mode = m
		busy_changed.emit(mode != Mode.IDLE)


func log_line(text: String) -> void:
	_recent.append(text)
	if _recent.size() > 400:
		_recent = _recent.slice(200)
	transcript_line.emit(text)
	if args.has("verbose"):
		print(text)


func script_error(msg: String, file: String = "", line: int = 0) -> void:
	error_count += 1
	var where := "%s:%d: " % [file, line] if file != "" else ""
	printerr("Avventura: " + where + msg)
	log_line("[error] " + where + msg)


func _warn_once(msg: String) -> void:
	if _warned.has(msg):
		return
	_warned[msg] = true
	log_line("[warning] " + msg)


func _vec(v: Variant) -> Variant:
	if v is Vector2:
		return v
	var parts := str(v).split(",")
	if parts.size() == 2 and parts[0].strip_edges().is_valid_float() and parts[1].strip_edges().is_valid_float():
		return Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
	return null


# --- preferences ---------------------------------------------------------------------------------

func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return
	for k in prefs:
		prefs[k] = cfg.get_value("prefs", k, prefs[k])


func save_prefs() -> void:
	var cfg := ConfigFile.new()
	for k in prefs:
		cfg.set_value("prefs", k, prefs[k])
	cfg.save("user://settings.cfg")
	_apply_prefs()


func _apply_prefs() -> void:
	for pair in [["Music", "music_volume"], ["SFX", "sfx_volume"]]:
		var i := AudioServer.get_bus_index(pair[0])
		if i != -1:
			AudioServer.set_bus_volume_db(i, linear_to_db(maxf(float(prefs[pair[1]]), 0.0001)))
	if DisplayServer.get_name() != "headless":
		var want := DisplayServer.WINDOW_MODE_FULLSCREEN if prefs.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		if (DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN) != prefs.fullscreen:
			DisplayServer.window_set_mode(want)
