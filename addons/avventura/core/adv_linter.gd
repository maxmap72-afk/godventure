class_name AdvLinter
extends RefCounted
## Static checks for a game: script errors, references to rooms, hotspots, items,
## characters, dialogs and variables that don't exist. Output is `file:line: level: message`,
## easy to read for people, editors and AI assistants alike.

const LOCALS := ["times", "first", "verb", "target", "item"]
const BUILTIN_FUNCS := ["has", "visited", "visits", "room", "player", "state", "shown", "enabled",
	"room_of", "used", "name", "is_player", "said", "ended", "random", "chance", "str", "int",
	"float", "len", "min", "max", "abs", "near"]
const EVENTS := ["enter", "exit", "setup", "start"]

var adv: Node
var reg: AdvRegistry
var issues: Array = []
## room_id -> {hotspots: {id: {exit_to, exit_entry, pickup_item, is_character}}, markers: {}, areas: {}, methods: {}}
var rooms: Dictionary = {}
var game_methods: Dictionary = {}
var set_vars: Dictionary = {}
var enabled_options: Dictionary = {}
var added_items: Dictionary = {}


static func lint(engine: Node) -> Array:
	var l := AdvLinter.new()
	l.adv = engine
	l.reg = engine.registry
	l._run()
	l.issues.sort_custom(func(a, b): return [a.file, a.line] < [b.file, b.line])
	return l.issues


static func format(i: Dictionary) -> String:
	return "%s:%d: %s: %s" % [i.file, i.line, i.level, i.msg]


static func errors(list: Array) -> int:
	var n := 0
	for i in list:
		if i.level == "error":
			n += 1
	return n


static func summary(list: Array) -> String:
	var e := errors(list)
	var w := list.size() - e
	if list.is_empty():
		return "lint: no problems found"
	return "lint: %d error(s), %d warning(s)" % [e, w]


func _run() -> void:
	for i in reg.issues:
		issues.append(i)
	_scan_rooms()
	_scan_game_script()
	_collect_sets()
	var game_file := _game_file()
	# Game declarations
	if reg.rooms.is_empty():
		_add(reg.game_dir, 0, "error", "no rooms found: create %s/rooms/<id>/<id>.tscn" % reg.game_dir)
	if reg.game.player == "":
		_add(game_file, 0, "warning", "no 'player CHARACTER' declaration: the first character will be used")
	elif not reg.characters.has(reg.game.player):
		_add(game_file, 0, "error", "player '%s' is not a declared character%s" % [reg.game.player, _hint(reg.game.player, reg.characters.keys())])
	if reg.game.start != "":
		if not reg.rooms.has(reg.game.start):
			_add(game_file, 0, "error", "start room '%s' does not exist%s" % [reg.game.start, _hint(reg.game.start, reg.rooms.keys())])
		elif reg.game.start_at != "" and not _has_marker(reg.game.start, reg.game.start_at):
			_add(game_file, 0, "error", "room '%s' has no entry '%s'" % [reg.game.start, reg.game.start_at])
	# Characters
	for id in reg.characters:
		var c: Dictionary = reg.characters[id]
		var p: Dictionary = c.get("props", {})
		if p.has("room") and not reg.rooms.has(str(p.room)):
			_add(c.get("file", reg.game_dir), c.get("line", 0), "error", "character '%s': unknown room '%s'" % [id, p.room])
		elif p.has("at") and p.has("room") and not _has_marker(str(p.room), str(p.at)):
			_add(c.get("file", reg.game_dir), c.get("line", 0), "error", "character '%s': room '%s' has no entry '%s'" % [id, p.room, p.at])
	# Room scenes
	for rid in rooms:
		var info: Dictionary = rooms[rid]
		var scene_path: String = reg.rooms[rid]
		if info.has("error"):
			_add(scene_path, 0, "error", info.error)
			continue
		if info.areas.is_empty():
			_add(scene_path, 0, "warning", "room '%s' has no AdvWalkArea: characters can walk anywhere" % rid)
		for hid in info.hotspots:
			var h: Dictionary = info.hotspots[hid]
			if h.exit_to != "":
				if not reg.rooms.has(h.exit_to):
					_add(scene_path, 0, "error", "exit '%s' leads to unknown room '%s'%s" % [hid, h.exit_to, _hint(h.exit_to, reg.rooms.keys())])
				else:
					var entry: String = h.exit_entry if h.exit_entry != "" else rid
					if not _has_marker(h.exit_to, entry):
						var level := "error" if h.exit_entry != "" else "warning"
						_add(scene_path, 0, level, "exit '%s': room '%s' has no entry named '%s' (add a Marker2D with that name)" % [hid, h.exit_to, entry])
			if h.pickup_item != "" and not reg.items.has(h.pickup_item):
				_add(scene_path, 0, "warning", "hotspot '%s': pickup item '%s' is not declared" % [hid, h.pickup_item])
	# Handlers
	for path in reg.files:
		var f: Dictionary = reg.files[path]
		var scope := reg.room_of_path(path)
		if scope != "" and not reg.rooms.has(scope):
			_add(path, 0, "warning", "script is in rooms/%s but there is no scene rooms/%s/%s.tscn" % [scope, scope, scope])
		for h in f.handlers:
			_check_handler(h, scope)
			_block(h.body, scope, path, {}, false)
		for name in f.dialogs:
			var d: Dictionary = f.dialogs[name]
			_block(d.start, scope, path, {}, true)
			for o in d.options:
				if o.cond != null:
					_expr(o.cond, scope, path, o.line, {})
				_block(o.body, scope, path, {}, true)
				if o.hidden and not enabled_options.has(name + "." + o.id):
					_add(path, o.line, "warning", "option '%s.%s' is hidden and never enabled with 'option on %s.%s'" % [name, o.id, name, o.id])
		for name in f.functions:
			var fn: Dictionary = f.functions[name]
			var locals := {}
			for p in fn.params:
				locals[p] = true
			_block(fn.body, scope, path, locals, true)
		for d in f.decls:
			if d.k == "var":
				_expr(d.expr, "", path, d.line, {})
	# Hotspots without any handler for their main verb
	for rid in rooms:
		var info: Dictionary = rooms[rid]
		if info.has("error"):
			continue
		for hid in info.hotspots:
			var h: Dictionary = info.hotspots[hid]
			if h.exit_to != "" or h.pickup_item != "" or h.description != "":
				continue
			var verb: String = h.verb
			var handled := false
			for v in [verb, "look", "*"]:
				if not reg.find_handler(rid, v, hid, "", false).is_empty():
					handled = true
			if not handled:
				_add(reg.rooms[rid], 0, "warning", "hotspot '%s' has no 'on %s %s:' or 'on look %s:' handler and no description" % [hid, verb, hid, hid])


func _check_handler(h: Dictionary, scope: String) -> void:
	if h.target == "" and h.item == "":
		if not h.verb in EVENTS:
			_add(h.file, h.line, "warning", "unknown event 'on %s:' (events: %s; for actions write 'on VERB TARGET:')" % [h.verb, ", ".join(EVENTS)])
		elif h.verb in ["enter", "exit", "setup"] and scope == "":
			_add(h.file, h.line, "warning", "'on %s:' only works in a room script (rooms/<id>/<id>.adv)" % h.verb)
		elif h.verb == "start" and scope != "":
			_add(h.file, h.line, "warning", "'on start:' only works in a global script such as game.adv")
		return
	for id in [h.target, h.item]:
		if id == "" or id == "*":
			continue
		if not _is_thing(id, scope):
			var where := "room '%s'" % scope if scope != "" else "any room"
			_add(h.file, h.line, "warning", "'%s' is not a hotspot of %s, an item or a character%s" % [id, where, _hint(id, _thing_names(scope))])


func _block(body: Array, scope: String, path: String, locals: Dictionary, in_dialog: bool) -> void:
	for st in body:
		_stmt(st, scope, path, locals, in_dialog)


func _stmt(st: Dictionary, scope: String, path: String, locals: Dictionary, in_dialog: bool) -> void:
	var line: int = st.line
	match st.k:
		"say":
			_char(st.who, scope, path, line, true)
			for p in st.parts:
				if p is Array:
					_expr(p[1], scope, path, line, locals)
		"if":
			for b in st.branches:
				if b.cond != null:
					_expr(b.cond, scope, path, line, locals)
				_block(b.body, scope, path, locals, in_dialog)
		"while":
			_expr(st.cond, scope, path, line, locals)
			_block(st.body, scope, path, locals, in_dialog)
		"set":
			_expr(st.expr, scope, path, line, locals)
		"walk":
			_char(st.who, scope, path, line)
			if st.loc.has("id"):
				_target(st.loc.id, scope, path, line)
		"face":
			_char(st.who, scope, path, line)
			if not st.to in ["left", "right", "up", "down"]:
				_target(st.to, scope, path, line)
		"anim":
			_char(st.who, scope, path, line)
		"wait":
			_expr(st.secs, scope, path, line, locals)
		"inventory":
			_item(st.item, path, line)
			if st.who != "player":
				_char(st.who, scope, path, line)
		"pickup":
			if scope != "":
				_object(st.obj, scope, path, line)
			_item(st.item if st.item != "" else _pickup_item(st.obj, scope), path, line)
		"show", "hide", "enable", "disable", "state":
			var r: String = st.room if st.room != "" else scope
			if st.room != "" and not reg.rooms.has(st.room):
				_add(path, line, "error", "unknown room '%s'%s" % [st.room, _hint(st.room, reg.rooms.keys())])
			elif r != "":
				_object(st.obj, r, path, line)
		"goto":
			if not reg.rooms.has(st.room):
				_add(path, line, "error", "unknown room '%s'%s" % [st.room, _hint(st.room, reg.rooms.keys())])
			elif st.at != "" and not _has_marker(st.room, st.at):
				_add(path, line, "error", "room '%s' has no entry '%s'%s" % [st.room, st.at, _hint(st.at, _marker_names(st.room))])
		"place":
			_char(st.who, scope, path, line)
			if st.room != "" and not reg.rooms.has(st.room):
				_add(path, line, "error", "unknown room '%s'" % st.room)
			elif st.loc != null and st.loc.has("id"):
				var r: String = st.room if st.room != "" else scope
				if r != "" and not _has_marker(r, st.loc.id):
					_add(path, line, "error", "room '%s' has no entry or hotspot '%s'" % [r, st.loc.id])
		"control":
			_char(st.name, scope, path, line)
		"dialog":
			if not reg.dialogs.has(st.name):
				_add(path, line, "error", "unknown dialog '%s'%s" % [st.name, _hint(st.name, reg.dialogs.keys())])
		"option":
			var parts: PackedStringArray = st.ref.split(".")
			var d: Dictionary = reg.dialogs.get(parts[0], {})
			if d.is_empty():
				_add(path, line, "error", "unknown dialog '%s'" % parts[0])
			else:
				var ids := []
				for o in d.options:
					ids.append(o.id)
				if parts.size() != 2 or not parts[1] in ids:
					_add(path, line, "error", "dialog '%s' has no option '%s' (options: %s)" % [parts[0], parts[1] if parts.size() > 1 else "", ", ".join(ids)])
		"end", "back":
			if not in_dialog:
				_add(path, line, "warning", "'%s' only makes sense inside a dialog option" % st.k)
		"call":
			for a in st.args:
				_expr(a, scope, path, line, locals)
			if not reg.functions.has(st.name) and not _has_method(st.name, scope):
				_add(path, line, "error", "unknown function '%s'%s" % [st.name, _hint(st.name, reg.functions.keys())])
		"camera":
			if st.op == "follow":
				_char(st.who, scope, path, line)
			elif st.op == "to" and st.loc.has("id"):
				_target(st.loc.id, scope, path, line)
		"cutscene", "bg", "random", "cycle", "sequence", "once", "do":
			_block(st.body, scope, path, locals, in_dialog)
		"print":
			for p in st.parts:
				if p is Array:
					_expr(p[1], scope, path, line, locals)
		"sound", "music":
			if st.name != "stop" and adv._audio(st.name) == null:
				_add(path, line, "warning", "%s '%s' not found in %s/audio" % [st.k, st.name, reg.game_dir])
		"video":
			if adv._video_path(st.name) == "":
				_add(path, line, "warning", "video '%s' not found in %s/video" % [st.name, reg.game_dir])


func _expr(ast: Variant, scope: String, path: String, line: int, locals: Dictionary) -> void:
	if ast == null:
		return
	var vars := {}
	var calls := {}
	AdvExpr.collect(ast, vars, calls)
	for v in vars:
		if v in LOCALS or locals.has(v) or set_vars.has(v):
			continue
		_add(path, line, "warning", "variable '%s' is never set (declare it with 'var %s = ...' or put quotes around text)%s" % [v, v, _hint(v, set_vars.keys())])
	for c in calls:
		if not c in BUILTIN_FUNCS and not _has_method(c, scope):
			_add(path, line, "error", "unknown function '%s()'%s" % [c, _hint(c, BUILTIN_FUNCS)])
	_id_args(ast, scope, path, line)


## Checks literal ids given to has(), visited(), state()...
func _id_args(ast: Array, scope: String, path: String, line: int) -> void:
	match ast[0]:
		"call":
			var args: Array = ast[2]
			var lit := ""
			if not args.is_empty():
				if args[0][0] == "var" and ast[1] in AdvExpr.ID_FUNCS:
					lit = args[0][1]
				elif args[0][0] == "lit" and args[0][1] is String:
					lit = args[0][1]
			if lit != "":
				match ast[1]:
					"has":
						_item(lit, path, line)
					"visited", "visits":
						if not reg.rooms.has(lit):
							_add(path, line, "error", "unknown room '%s'%s" % [lit, _hint(lit, reg.rooms.keys())])
					"state", "shown", "enabled":
						var r := scope
						if args.size() > 1 and args[1][0] in ["var", "lit"]:
							r = str(args[1][1])
						if r != "":
							_object(lit, r, path, line)
					"room_of":
						_char(lit, scope, path, line)
					"used":
						var parts := lit.split(".")
						var d: Dictionary = reg.dialogs.get(parts[0], {})
						var found := false
						for o in d.get("options", []):
							if parts.size() == 2 and o.id == parts[1]:
								found = true
						if not found:
							_add(path, line, "error", "unknown dialog option '%s' (write used(dialog.option))" % lit)
			for a in args:
				_id_args(a, scope, path, line)
		"not", "neg":
			_id_args(ast[1], scope, path, line)
		"and", "or":
			_id_args(ast[1], scope, path, line)
			_id_args(ast[2], scope, path, line)
		"op":
			_id_args(ast[2], scope, path, line)
			_id_args(ast[3], scope, path, line)
		"list":
			for a in ast[1]:
				_id_args(a, scope, path, line)


# --- references ---------------------------------------------------------------------------------

func _char(id: String, scope: String, path: String, line: int, speaker: bool = false) -> void:
	if id in ["player", "narrator"] and (speaker or id == "player"):
		return
	if reg.characters.has(id):
		return
	var here: Dictionary = rooms.get(scope, {}).get("hotspots", {}).get(id, {})
	if not here.is_empty() and (speaker or here.is_character):
		return  # a hotspot of this room can talk too (a parrot, a talking skull...)
	for rid in rooms:
		if rooms[rid].get("hotspots", {}).get(id, {}).get("is_character", false):
			return
	_add(path, line, "error" if not speaker else "warning", "unknown character '%s'%s" % [id, _hint(id, reg.characters.keys() + ["player", "narrator"])])


func _item(id: String, path: String, line: int) -> void:
	if id != "" and not reg.items.has(id):
		_add(path, line, "error", "item '%s' is not declared (add: item %s \"Name\")%s" % [id, id, _hint(id, reg.items.keys())])


func _object(id: String, room_id: String, path: String, line: int) -> void:
	var info: Dictionary = rooms.get(room_id, {})
	if info.is_empty() or info.has("error"):
		return
	if info.hotspots.has(id) or info.markers.has(id) or info.areas.has(id):
		return
	_add(path, line, "error", "room '%s' has no object '%s'%s" % [room_id, id, _hint(id, info.hotspots.keys() + info.areas.keys())])


func _target(id: String, scope: String, path: String, line: int) -> void:
	if id == "player" or reg.characters.has(id) or scope == "":
		return
	if not _has_marker(scope, id):
		_add(path, line, "error", "room '%s' has no hotspot or marker '%s'%s" % [scope, id, _hint(id, _marker_names(scope))])


func _is_thing(id: String, scope: String) -> bool:
	if reg.items.has(id) or reg.characters.has(id):
		return true
	if scope != "":
		return rooms.get(scope, {}).get("hotspots", {}).has(id)
	for rid in rooms:
		if rooms[rid].get("hotspots", {}).has(id):
			return true
	return false


func _thing_names(scope: String) -> Array:
	var names: Array = reg.items.keys() + reg.characters.keys()
	if scope != "":
		names += rooms.get(scope, {}).get("hotspots", {}).keys()
	else:
		for rid in rooms:
			names += rooms[rid].get("hotspots", {}).keys()
	return names


func _has_marker(room_id: String, id: String) -> bool:
	var info: Dictionary = rooms.get(room_id, {})
	if info.is_empty() or info.has("error"):
		return true
	return info.markers.has(id) or info.hotspots.has(id)


func _marker_names(room_id: String) -> Array:
	var info: Dictionary = rooms.get(room_id, {})
	if info.is_empty() or info.has("error"):
		return []
	return info.markers.keys() + info.hotspots.keys()


func _has_method(name: String, scope: String) -> bool:
	if game_methods.has(name):
		return true
	if scope != "":
		return rooms.get(scope, {}).get("methods", {}).has(name)
	for rid in rooms:
		if rooms[rid].get("methods", {}).has(name):
			return true
	return false


func _pickup_item(obj: String, scope: String) -> String:
	var h: Dictionary = rooms.get(scope, {}).get("hotspots", {}).get(obj, {})
	var p: String = h.get("pickup_item", "")
	return p if p != "" else obj


func _game_file() -> String:
	var p := reg.game_dir + "/game.adv"
	return p if reg.files.has(p) else reg.game_dir


# --- scanning -----------------------------------------------------------------------------------

func _scan_rooms() -> void:
	for rid in reg.rooms:
		var info := {"hotspots": {}, "markers": {}, "areas": {}, "methods": {}}
		rooms[rid] = info
		var scene = load(reg.rooms[rid])
		if not scene is PackedScene:
			info["error"] = "cannot load room scene"
			continue
		var root: Node = scene.instantiate()
		if not root is AdvRoom:
			info["error"] = "the root node of room '%s' must be an AdvRoom" % rid
			root.free()
			continue
		var script: Script = root.get_script()
		if script:
			for m in script.get_script_method_list():
				info.methods[m.name] = true
		_scan_node(root, info)
		root.free()


func _scan_node(n: Node, info: Dictionary) -> void:
	for c in n.get_children():
		if c is AdvHotspot:
			info.hotspots[c.get_id()] = {"exit_to": c.exit_to, "exit_entry": c.exit_entry, "pickup_item": c.pickup_item,
				"is_character": c is AdvCharacter, "verb": c.get_default_verb(), "description": c.description}
		elif c is AdvWalkArea:
			info.areas[c.get_area_id()] = true
			info.areas[String(c.name)] = true
		elif c is AdvRegion:
			info.areas[c.get_region_id()] = true
			info.hotspots[c.get_region_id()] = {"exit_to": "", "exit_entry": "", "pickup_item": "", "is_character": false,
				"verb": "walk_onto", "description": "region"}
		if c is Node2D:
			info.markers[String(c.name)] = true
			info.markers[AdvHotspot.to_id(c.name)] = true
		_scan_node(c, info)


func _scan_game_script() -> void:
	var p := reg.game_dir + "/game.gd"
	if ResourceLoader.exists(p):
		var s = load(p)
		if s is Script:
			for m in s.get_script_method_list():
				game_methods[m.name] = true


## Variables that are declared or set anywhere, options enabled anywhere, items obtainable.
func _collect_sets() -> void:
	for d in reg.vars:
		set_vars[d.name] = true
	for path in reg.files:
		var f: Dictionary = reg.files[path]
		for h in f.handlers:
			_collect_block(h.body)
		for name in f.dialogs:
			_collect_block(f.dialogs[name].start)
			for o in f.dialogs[name].options:
				_collect_block(o.body)
		for name in f.functions:
			_collect_block(f.functions[name].body)


func _collect_block(body: Array) -> void:
	for st in body:
		match st.k:
			"set":
				set_vars[st.name] = true
			"option":
				if st.on:
					enabled_options[st.ref] = true
			"inventory":
				if st.op == "add":
					added_items[st.item] = true
			"if":
				for b in st.branches:
					_collect_block(b.body)
			"while", "cutscene", "bg", "random", "cycle", "sequence", "once", "do":
				_collect_block(st.body)


func _add(file: String, line: int, level: String, msg: String) -> void:
	for i in issues:
		if i.file == file and i.line == line and i.msg == msg:
			return
	issues.append({"file": file, "line": line, "level": level, "msg": msg})


static func _hint(word: String, candidates: Array) -> String:
	var best := ""
	var best_s := 0.0
	for c in candidates:
		var s := word.similarity(str(c))
		if s > best_s:
			best_s = s
			best = str(c)
	if best_s >= 0.5 and best != word:
		return " (did you mean '%s'?)" % best
	return ""
