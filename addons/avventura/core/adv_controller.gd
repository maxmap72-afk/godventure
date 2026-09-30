class_name AdvController
extends Node
## Text command interface to the engine, shared by:
## - the in-game debug console (` key)
## - remote control over TCP (--adv-remote, used by tools/adv_mcp.py)
## - batch runs (--adv-run="look sign; use key on door")
## - walkthrough tests (.advtest files, --adv-test)
## Commands read like the game: `look sign`, `use key on door`, `talk to beppe`, `choose 2`.

const HELP := """Actions (like a click):
  VERB TARGET                 look cartello | talk to beppe | pick pala | walk porta
  VERB ITEM on TARGET         use chiave on porta | give vermi to beppe
  walk X Y                    walk to a point of the room
  choose N | choose TEXT      pick a dialog option
  skip                        skip the current line / cutscene
Inspect:
  scene [all]                 room, hotspots, exits, characters, inventory
  state | inv | vars          summaries
  get VAR | eval EXPR         read variables and expressions
  expect EXPR                 fail unless EXPR is true (tests), e.g. expect has(chiave)
Change (debug):
  set VAR = EXPR | item add|remove ITEM | goto ROOM [at ENTRY]
  run STATEMENTS              run AdvScript, use \\n between statements
  new [ROOM] | save SLOT | load SLOT | reload | fast on|off
  click X Y | rclick X Y      simulate mouse clicks (room coordinates)
  gui show_pause|show_save_menu|show_settings|toggle_console|close   open interface panels
  screenshot [PATH] | lint | record PATH|stop | wait SECONDS | quit"""

const COMMANDS := ["help", "do", "choose", "skip", "scene", "state", "inv", "inventory", "vars", "get",
	"eval", "expect", "set", "item", "goto", "run", "new", "save", "load", "reload", "fast", "click",
	"rclick", "gui", "screenshot", "lint", "record", "wait", "quit"]

var adv: Node
var _out: PackedStringArray = PackedStringArray()
var _capturing := false
var _server: TCPServer
var _peers: Array = []
var _queue: Array = []
var _serving := false
var _record_file := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	adv.transcript_line.connect(_on_line)
	adv.action_performed.connect(_on_action)
	adv.choice_made.connect(_on_choice)
	adv.room_entered.connect(func(id): _record("# room: " + id))


func _on_line(text: String) -> void:
	if _capturing:
		_out.append(text)


func _print(text: String) -> void:
	_out.append(text)


## Runs one command and returns {"ok": bool, "output": String, "status": String}.
func execute(line: String) -> Dictionary:
	line = line.strip_edges()
	if line == "" or line.begins_with("#"):
		return {"ok": true, "output": "", "status": status()}
	# "look sign &" starts the action and returns at once (to take screenshots mid-action).
	var background := line.ends_with(" &")
	if background:
		line = line.trim_suffix("&").strip_edges()
	var word := line.get_slice(" ", 0).to_lower()
	var rest := line.substr(word.length()).strip_edges()
	if word != "expect":
		adv.clear_recent()
	_out = PackedStringArray()
	_capturing = true
	var ok := true
	var settle := false
	match word:
		"help":
			_print(HELP)
		"do":
			ok = _do(rest)
			settle = ok
		"choose":
			ok = _choose(rest)
			settle = ok
		"skip":
			adv.skip_line()
			adv.skip_cutscene()
			settle = true
		"scene":
			_print(describe_scene(rest == "all"))
		"state":
			_print(describe_state())
		"inv", "inventory":
			_print(_describe_inventory())
		"vars":
			_print(_describe_vars())
		"get":
			_print("%s = %s" % [rest, JSON.stringify(adv.get_var(rest))])
		"eval":
			var r := _eval(rest)
			ok = not r.has("error")
			_print(r.get("error", JSON.stringify(r.get("value"))))
		"expect":
			ok = _expect(rest)
		"set":
			ok = _cmd_set(rest)
		"item":
			ok = _item(rest)
		"goto":
			ok = _goto(rest)
			settle = ok
		"run":
			ok = _run(rest.replace("\\n", "\n"))
			settle = ok
		"new":
			adv.new_game(rest)
			settle = true
		"save":
			ok = adv.save_game(rest if rest != "" else "quicksave")
		"load":
			adv.load_game(rest if rest != "" else "quicksave")
			settle = true
		"reload":
			var issues: Array = adv.reload_scripts()
			_print("scripts reloaded: %d error(s)" % adv.registry.error_count())
			for i in issues:
				_print("%s:%d: %s: %s" % [i.file, i.line, i.level, i.msg])
			ok = adv.registry.error_count() == 0
		"fast":
			adv.fast = rest != "off"
			_print("fast mode " + ("on" if adv.fast else "off"))
		"click", "rclick":
			ok = _click(rest, word == "rclick")
			settle = ok
		"gui":
			ok = _gui(rest)
			settle = ok
		"screenshot":
			var path := await screenshot(rest if rest != "" else "user://screenshot.png")
			ok = path != ""
			_print(path if ok else "screenshots need a window (not available in --headless mode)")
		"lint":
			var issues := AdvLinter.lint(adv)
			for i in issues:
				_print(AdvLinter.format(i))
			_print(AdvLinter.summary(issues))
			ok = AdvLinter.errors(issues) == 0
		"record":
			if rest == "stop" or rest == "":
				_record_file = ""
				_print("recording stopped")
			else:
				start_recording(rest)
				_print("recording to " + rest)
		"wait":
			await get_tree().create_timer(maxf(rest.to_float(), 0.0)).timeout
		"quit":
			quit()
		_:
			if _is_verb(word):
				ok = _do(line)
				settle = ok
			else:
				_print("unknown command '%s' (type 'help')" % word)
				ok = false
	if settle and not background:
		await _settle()
	elif settle:
		await get_tree().process_frame
	_capturing = false
	return {"ok": ok, "output": "\n".join(_out), "status": status()}


func status() -> String:
	if adv.game_over:
		return "ended"
	if adv.mode == adv.Mode.CHOICE:
		return "choice"
	if adv.is_idle() and not adv.is_speaking():
		return "ready"
	return "busy"


func _is_verb(word: String) -> bool:
	return adv.registry.verbs.has(word)


## Waits until the game needs the player again (idle or dialog choice).
func _settle(timeout: float = 120.0) -> void:
	var t0 := Time.get_ticks_msec()
	while true:
		if adv.mode == adv.Mode.CHOICE or adv.game_over:
			return
		if adv.is_idle() and not adv.is_speaking():
			return
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			_print("[timeout] still busy after %d seconds" % timeout)
			return
		await get_tree().process_frame


# --- commands ------------------------------------------------------------------------------

func _do(text: String) -> bool:
	var w := Array(text.split(" ", false))
	if w.is_empty():
		_print("write: VERB TARGET (e.g. look sign)")
		return false
	var verb: String = w[0]
	var rest := w.slice(1)
	if rest.size() >= 2 and rest[0] in ["to", "at"]:
		rest = rest.slice(1)
	if verb == "walk" and rest.size() >= 1:
		var coords := " ".join(rest).replace(",", " ").split(" ", false)
		if coords.size() == 2 and coords[0].is_valid_float() and coords[1].is_valid_float():
			if not _ready_for_input():
				return false
			adv.walk_player(Vector2(coords[0].to_float(), coords[1].to_float()))
			return true
	var item := ""
	var target := ""
	if rest.size() == 1:
		target = rest[0]
	elif rest.size() == 3 and rest[1] in ["on", "with", "to", "in", "at"]:
		item = rest[0]
		target = rest[2]
	else:
		_print("write: VERB TARGET or VERB ITEM on TARGET")
		return false
	if not _ready_for_input():
		return false
	var hs: AdvHotspot = adv.room.find_hotspot(target)
	if (hs == null or not hs.is_visible_in_tree() or not hs.interactive) and not adv.has_item(target):
		_print("[nothing] no '%s' here. You can use: %s" % [target, ", ".join(_available_ids())])
		return false
	if item != "" and not adv.has_item(item):
		_print("[nothing] you don't have '%s'. Inventory: %s" % [item, ", ".join(adv.player_items())])
		return false
	adv.perform(verb, target, item)
	return true


func _ready_for_input() -> bool:
	if adv.mode == adv.Mode.CHOICE:
		_print("a dialog is waiting for a choice: use 'choose N'\n" + _choices_text())
		return false
	if adv.game_over:
		_print("the game has ended (use 'new' to restart)")
		return false
	if not adv.accepts_input():
		_print("the game is busy (cutscene or script running)")
		return false
	return true


func _choose(text: String) -> bool:
	if adv.mode != adv.Mode.CHOICE:
		_print("no dialog choice is pending")
		return false
	var opts: Array = adv.pending_choices
	var idx := -1
	text = AdvParser._unquote(text)
	if text.is_valid_int():
		idx = int(text) - 1
	else:
		for i in opts.size():
			if text.to_lower() in str(opts[i]).to_lower():
				idx = i
				break
	if idx < 0 or idx >= opts.size():
		_print("no such option.\n" + _choices_text())
		return false
	adv.choose(idx)
	return true


func _choices_text() -> String:
	var lines := []
	for i in adv.pending_choices.size():
		lines.append("  %d) %s" % [i + 1, adv.pending_choices[i]])
	return "\n".join(lines)


func _eval(src: String) -> Dictionary:
	var r := AdvExpr.parse(src)
	if r.has("error"):
		return {"error": "expression error: " + r.error}
	var ctx: AdvInterpreter.Ctx = adv.interp.new_ctx("<console>", adv.state.room, "console")
	var before: int = adv.error_count
	var value = AdvExpr.evaluate(r.ast, ctx)
	if adv.error_count > before:
		return {"error": "error while evaluating '%s'" % src}
	return {"value": value}


func _expect(src: String) -> bool:
	var r := _eval(src)
	if r.has("error"):
		_print("FAILED: " + r.error)
		return false
	if AdvExpr.truthy(r.value):
		_print("ok: " + src)
		return true
	_print("FAILED: expect %s  (got %s)" % [src, JSON.stringify(r.value)])
	return false


func _cmd_set(src: String) -> bool:
	var eq := src.find("=")
	if eq == -1:
		_print("write: set NAME = VALUE")
		return false
	var name := src.left(eq).strip_edges()
	var r := _eval(src.substr(eq + 1))
	if r.has("error"):
		_print(r.error)
		return false
	adv.set_var(name, r.value)
	_print("%s = %s" % [name, JSON.stringify(r.value)])
	return true


func _item(src: String) -> bool:
	var w := src.split(" ", false)
	if w.size() != 2 or not w[0] in ["add", "remove"]:
		_print("write: item add ITEM | item remove ITEM")
		return false
	if w[0] == "add":
		adv.inventory_add(w[1])
	else:
		adv.inventory_remove(w[1])
	return true


func _goto(src: String) -> bool:
	var w := src.split(" ", false)
	if w.is_empty() or not adv.registry.rooms.has(w[0]):
		_print("unknown room. Rooms: " + ", ".join(adv.registry.rooms.keys()))
		return false
	if adv.mode != adv.Mode.IDLE:
		_print("the game is busy")
		return false
	adv.change_room(w[0], w[2] if w.size() == 3 and w[1] == "at" else "")
	return true


func _run(src: String) -> bool:
	var parsed := AdvParser.parse_statements(src)
	if not parsed.errors.is_empty():
		_print("script error: " + parsed.errors[0].msg)
		return false
	if adv.mode != adv.Mode.IDLE:
		_print("the game is busy")
		return false
	_run_body(parsed.body)
	return true


func _run_body(body: Array) -> void:
	adv._set_busy(true)
	await adv.interp.exec_block(body, adv.interp.new_ctx("<console>", adv.state.room, "console"))
	adv._set_busy(false)


func _click(src: String, right: bool) -> bool:
	var c := src.replace(",", " ").split(" ", false)
	if c.size() != 2 or not c[0].is_valid_float() or not c[1].is_valid_float():
		_print("write: click X Y (room coordinates)")
		return false
	var room_pos := Vector2(c[0].to_float(), c[1].to_float())
	var world_pos: Vector2 = adv.room.to_global(room_pos) if adv.room else room_pos
	if adv.gui and adv.gui.has_method("click_world"):
		adv.gui.click_world(world_pos, MOUSE_BUTTON_RIGHT if right else MOUSE_BUTTON_LEFT)
		return true
	if not _ready_for_input():
		return false
	var hs: AdvHotspot = adv.hotspot_at(world_pos)
	if hs == null:
		if not right:
			adv.walk_player(room_pos)
		return true
	adv.perform("look" if right else hs.get_default_verb(), hs.get_id())
	return true


## Calls an interface function: gui show_pause | show_title | show_save_menu | show_load_menu |
## show_settings | toggle_console | close
func _gui(src: String) -> bool:
	if adv.gui == null:
		_print("no interface in this mode (headless)")
		return false
	var parts := src.split(" ", false)
	var method := parts[0] if not parts.is_empty() else ""
	if method == "close":
		method = "_close_all_menus"
	if method == "" or not adv.gui.has_method(method):
		_print("write: gui show_pause | show_title | show_save_menu | show_load_menu | show_settings | toggle_console | close")
		return false
	var call_args := []
	for a in parts.slice(1):
		call_args.append(a.to_int() if a.is_valid_int() else (a.to_float() if a.is_valid_float() else a))
	adv.gui.callv(method, call_args)
	return true


func screenshot(path: String) -> String:
	if DisplayServer.get_name() == "headless":
		return ""
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if path.get_base_dir() != "" and not path.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if img.save_png(path) != OK:
		return ""
	return ProjectSettings.globalize_path(path)


# --- descriptions ------------------------------------------------------------------------------

func describe_scene(all: bool = false) -> String:
	if adv.room == null:
		return "no room loaded"
	var r: AdvRoom = adv.room
	var s := r.get_size()
	var lines := ["Room: %s \"%s\" (%dx%d)" % [adv.state.room, r.get_display_name(), s.x, s.y]]
	if adv.player:
		var p: Vector2 = adv.player.room_position()
		lines.append("Player: %s at (%d, %d)" % [adv.state.player, p.x, p.y])
	lines.append("Hotspots:")
	for h in r.get_hotspots():
		if h == adv.player:
			continue
		var usable: bool = h.is_visible_in_tree() and h.interactive
		if not usable and not all:
			continue
		var pos: Vector2 = r.to_local(h.global_position if h is AdvCharacter else h.get_global_bounds().get_center())
		var line := "  %s \"%s\" at (%d, %d) verb=%s" % [h.get_id(), adv.tr(h.get_display_name()), pos.x, pos.y, h.get_default_verb()]
		if h is AdvCharacter:
			line += " [character]"
		if h.is_exit():
			line += " [exit -> %s]" % h.exit_to
		if h.pickup_item != "":
			line += " [pickup -> %s]" % h.pickup_item
		if h.state != "":
			line += " [state: %s]" % h.state
		if not usable:
			line += " [hidden]" if not h.is_visible_in_tree() else " [disabled]"
		lines.append(line)
	var markers: Array = r.get_markers()
	if not markers.is_empty():
		lines.append("Entries: " + ", ".join(markers))
	lines.append(_describe_inventory())
	if adv.mode == adv.Mode.CHOICE:
		lines.append("Waiting for a dialog choice:\n" + _choices_text())
	return "\n".join(lines)


func describe_state() -> String:
	var lines := []
	lines.append("Status: %s | room: %s | player: %s | playtime: %ds" % [status(), adv.state.room, adv.state.player, adv.state.playtime])
	lines.append(_describe_inventory())
	lines.append(_describe_vars())
	var visited := []
	for k in adv.state.visited:
		visited.append("%s(%d)" % [k, adv.state.visited[k]])
	lines.append("Visited: " + ", ".join(visited))
	if adv.mode == adv.Mode.CHOICE:
		lines.append("Waiting for a dialog choice:\n" + _choices_text())
	return "\n".join(lines)


func _describe_inventory() -> String:
	var items := []
	for i in adv.player_items():
		items.append("%s \"%s\"" % [i, adv.display_name(i)])
	return "Inventory: " + (", ".join(items) if not items.is_empty() else "(empty)")


func _describe_vars() -> String:
	var parts := []
	var keys: Array = adv.state.vars.keys()
	keys.sort()
	for k in keys:
		parts.append("%s=%s" % [k, JSON.stringify(adv.state.vars[k])])
	return "Vars: " + (", ".join(parts) if not parts.is_empty() else "(none)")


func _available_ids() -> Array:
	var ids := []
	if adv.room:
		for h in adv.room.get_hotspots():
			if h != adv.player and h.is_visible_in_tree() and h.interactive:
				ids.append(h.get_id())
	ids.append_array(adv.player_items())
	return ids


# --- recording ------------------------------------------------------------------------------------

func start_recording(path: String) -> void:
	_record_file = path
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("Avventura: cannot record to " + path)
		_record_file = ""
		return
	f.store_line("# Recorded walkthrough, %s. Add 'expect ...' lines to turn it into a test." % Time.get_datetime_string_from_system(false, true))
	f.close()


func _record(line: String) -> void:
	if _record_file == "":
		return
	var f := FileAccess.open(_record_file, FileAccess.READ_WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
	f.close()


func _on_action(verb: String, target: String, item: String) -> void:
	_record("%s %s on %s" % [verb, item, target] if item != "" else "%s %s" % [verb, target])


func _on_choice(index: int) -> void:
	if index >= 0:
		_record("choose %d" % (index + 1))


# --- command line modes ------------------------------------------------------------------------------

## --adv-run="cmd; cmd" or --adv-run-file=path: plays commands and prints the transcript.
func cli_run() -> void:
	var cmds: Array = []
	if adv.args.has("run-file"):
		cmds = Array(FileAccess.get_file_as_string(_res(str(adv.args["run-file"]))).split("\n"))
	else:
		cmds = Array(str(adv.args.run).split(";"))
	_out = PackedStringArray()
	_capturing = true
	if adv.args.has("load"):
		await adv.load_game(str(adv.args.load))
	else:
		await adv.new_game(str(adv.args.get("start", "")))
	await _settle()
	_capturing = false
	print("\n".join(_out))
	var failed := false
	for c in cmds:
		var cmd := str(c).strip_edges()
		if cmd == "" or cmd.begins_with("#"):
			continue
		print("> " + cmd)
		var r := await execute(cmd)
		if r.output != "":
			print(r.output)
		if not r.ok:
			failed = true
	if adv.args.has("save"):
		adv.save_game(str(adv.args.save))
	print("[status] " + status())
	if adv.args.has("screenshot"):
		await cli_screenshot(str(adv.args.screenshot))
		return
	quit(1 if failed else 0)


func cli_screenshot(path: String) -> void:
	for i in 12:
		await get_tree().process_frame
	var p := await screenshot(path)
	print("[screenshot] " + (p if p != "" else "unavailable in headless mode"))
	quit(0 if p != "" else 1)


## --adv-test[=path]: runs .advtest walkthroughs and exits with 1 on failure.
func cli_test(arg: String) -> void:
	var files: Array = []
	if arg == "" or arg == "true":
		files = AdvRegistry.find_files(adv.game_dir, ["advtest"])
		files.sort()
	else:
		files = [_res(arg)]
	var issues := AdvLinter.lint(adv)
	var lint_errors := AdvLinter.errors(issues)
	for i in issues:
		if i.level == "error":
			print(AdvLinter.format(i))
	var passed := 0
	var failed := 0
	print("Running %d test file(s)" % files.size())
	for f in files:
		var r := await run_test_file(f)
		if r.ok:
			passed += 1
			print("PASS %s (%d steps)" % [f, r.steps])
		else:
			failed += 1
			print("FAIL %s" % f)
			print(r.message)
	print("%d passed, %d failed%s" % [passed, failed, (", %d script error(s) found by lint" % lint_errors) if lint_errors > 0 else ""])
	quit(1 if failed > 0 or lint_errors > 0 or files.is_empty() else 0)


## Plays a test file from a new game. Stops at the first failing step.
func run_test_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "steps": 0, "message": "  file not found"}
	var lines := FileAccess.get_file_as_string(path).split("\n")
	adv.fast = true
	_out = PackedStringArray()
	_capturing = true
	adv.clear_recent()
	await adv.new_game()
	await _settle()
	var errors: int = adv.error_count
	var steps := 0
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		steps += 1
		var r := await execute(line)
		var msg := ""
		if not r.ok:
			msg = "  %s:%d: %s" % [path, i + 1, line]
		elif adv.error_count > errors:
			msg = "  %s:%d: script error while running '%s'" % [path, i + 1, line]
		if msg != "":
			return {"ok": false, "steps": steps, "message": msg + "\n" + _indent(r.output, "    ")}
		errors = adv.error_count
	return {"ok": true, "steps": steps, "message": ""}


func cli_lint() -> void:
	var issues := AdvLinter.lint(adv)
	for i in issues:
		print(AdvLinter.format(i))
	print(AdvLinter.summary(issues))
	quit(1 if AdvLinter.errors(issues) > 0 else 0)


## --adv-scaffold=room:id[:Name] | character:id[:Name] | item:id[:Name]
func cli_scaffold(spec: String) -> void:
	var parts := spec.split(":")
	var kind := parts[0]
	var id := parts[1] if parts.size() > 1 else ""
	var name := parts[2] if parts.size() > 2 else ""
	var r: Dictionary
	match kind:
		"room":
			r = AdvScaffold.new_room(adv.game_dir, id, name)
		"character":
			r = AdvScaffold.new_character(adv.game_dir, id, name, parts[3] if parts.size() > 3 else "")
		"item":
			r = AdvScaffold.new_item(adv.game_dir, id, name)
		_:
			r = {"error": "unknown kind '%s' (room, character, item)" % kind}
	if r.has("error") or not r.has("files"):
		print("error: " + str(r.get("error", "could not create %s '%s'" % [kind, id])))
		get_tree().quit(1)
		return
	for f in r.files:
		print("created " + f)
	get_tree().quit(0)


## Releases scripts waiting for input, then quits.
func quit(code: int = 0) -> void:
	adv._reset_runtime()
	await get_tree().process_frame
	get_tree().quit(code)


static func _indent(text: String, prefix: String) -> String:
	var out := []
	for l in text.split("\n"):
		out.append(prefix + l)
	return "\n".join(out)


static func _res(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return "res://" + path


# --- remote control (TCP, JSON lines) ------------------------------------------------------------------

func start_remote(port: int) -> void:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		printerr("Avventura: remote control can't listen on port %d (error %d)" % [port, err])
		_server = null
		return
	print("[avventura] remote control on 127.0.0.1:%d" % port)


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		_peers.append({"peer": _server.take_connection(), "buf": PackedByteArray()})
	for p in _peers.duplicate():
		var peer: StreamPeerTCP = p.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(p)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var res: Array = peer.get_data(n)
			if res[0] == OK:
				p.buf.append_array(res[1])
		while true:
			var nl: int = p.buf.find(10)
			if nl == -1:
				break
			var line: String = p.buf.slice(0, nl).get_string_from_utf8().strip_edges()
			p.buf = p.buf.slice(nl + 1)
			if line != "":
				_queue.append({"peer": peer, "line": line})
	if not _serving and not _queue.is_empty():
		_serve(_queue.pop_front())


func _serve(req: Dictionary) -> void:
	_serving = true
	var cmd: String = req.line
	var id = null
	if cmd.begins_with("{"):
		var j = JSON.parse_string(cmd)
		if j is Dictionary:
			id = j.get("id")
			cmd = str(j.get("cmd", ""))
	var r := await execute(cmd)
	r["id"] = id
	var peer: StreamPeerTCP = req.peer
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(r) + "\n").to_utf8_buffer())
	_serving = false
