@tool
class_name AdvRegistry
extends RefCounted
## Loads every .adv file of a game and indexes handlers, dialogs, functions and
## declarations. Also discovers rooms and characters by folder convention:
##   <game_dir>/rooms/<id>/<id>.tscn        (room scene, script: <id>.adv next to it)
##   <game_dir>/characters/<id>/<id>.tscn   (optional character scene)

const STANDARD_VERBS := ["walk", "look", "use", "talk", "pick", "open", "close", "push", "pull", "give"]

var game_dir := "res://game"
## path -> parsed file
var files: Dictionary = {}
## key "verb|item|target" -> handler
var global_handlers: Dictionary = {}
## room_id -> {key -> handler}
var room_handlers: Dictionary = {}
var dialogs: Dictionary = {}
var functions: Dictionary = {}
## id -> {id, name, props, line, file}
var items: Dictionary = {}
## id -> {id, name, props, line, file, scene}
var characters: Dictionary = {}
## [{name, expr, line, file}]
var vars: Array = []
var game: Dictionary = {"title": "", "player": "", "start": "", "start_at": ""}
## room_id -> scene path
var rooms: Dictionary = {}
## Full-screen overlays (game/overlays/<id>.tscn), shown with `show ID` (like AGS GUIs).
var overlays: Dictionary = {}
## Verbs used anywhere (handlers + standard ones).
var verbs: Dictionary = {}
## [{file, line, level, msg}]
var issues: Array = []


func load_game(dir: String) -> void:
	game_dir = dir.trim_suffix("/")
	files.clear()
	global_handlers.clear()
	room_handlers.clear()
	dialogs.clear()
	functions.clear()
	items.clear()
	characters.clear()
	vars.clear()
	rooms.clear()
	overlays.clear()
	verbs.clear()
	issues.clear()
	game = {"title": "", "player": "", "start": "", "start_at": ""}
	for v in STANDARD_VERBS:
		verbs[v] = true
	_discover_rooms()
	_discover_characters()
	_discover_overlays()
	var paths := find_files(game_dir, ["adv"])
	paths.sort()
	for path in paths:
		load_file(path)


func load_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text == "" and FileAccess.get_open_error() != OK:
		issue(path, 0, "error", "cannot read file")
		return
	var parsed := AdvParser.parse(text, path)
	files[path] = parsed
	for e in parsed.errors:
		issue(path, e.line, "error", e.msg)
	var room := room_of_path(path)
	var table: Dictionary = global_handlers
	if room != "":
		if not room_handlers.has(room):
			room_handlers[room] = {}
		table = room_handlers[room]
	for h in parsed.handlers:
		h.room = room
		h.key = handler_key(h.verb, h.item, h.target)
		if table.has(h.key):
			var other: Dictionary = table[h.key]
			issue(path, h.line, "error", "'on %s' is already defined in %s:%d" % [describe(h), other.file, other.line])
			continue
		table[h.key] = h
		if h.target != "" and h.verb != "*":
			verbs[h.verb] = true
	for name in parsed.dialogs:
		if dialogs.has(name):
			issue(path, parsed.dialogs[name].line, "error", "dialog '%s' is already defined in %s" % [name, dialogs[name].file])
			continue
		dialogs[name] = parsed.dialogs[name]
	for name in parsed.functions:
		if functions.has(name):
			issue(path, parsed.functions[name].line, "error", "function '%s' is already defined in %s" % [name, functions[name].file])
			continue
		functions[name] = parsed.functions[name]
	for d in parsed.decls:
		match d.k:
			"var":
				vars.append(d)
			"item":
				if items.has(d.id):
					issue(path, d.line, "error", "item '%s' is already declared in %s:%d" % [d.id, items[d.id].file, items[d.id].line])
				else:
					items[d.id] = d
			"character":
				var prev: Dictionary = characters.get(d.id, {})
				if prev.has("line"):
					issue(path, d.line, "error", "character '%s' is already declared in %s:%d" % [d.id, prev.file, prev.line])
				else:
					d.scene = prev.get("scene", "")
					characters[d.id] = d
			"title":
				game.title = d.value
			"player":
				game.player = d.value
			"start":
				game.start = d.room
				game.start_at = d.at


static func handler_key(verb: String, item: String, target: String) -> String:
	return "%s|%s|%s" % [verb, item, target]


static func describe(h: Dictionary) -> String:
	if h.item != "":
		return "%s %s %s %s" % [h.verb, h.item, h.get("prep", "on"), h.target]
	if h.target != "":
		return "%s %s" % [h.verb, h.target]
	return h.verb


## Finds the handler for an action. Room handlers win over global ones at every step;
## specific handlers win over wildcards (`*`).
func find_handler(room: String, verb: String, target: String, item: String = "", wildcards: bool = true) -> Dictionary:
	var keys: Array = []
	if item != "":
		keys.append([verb, item, target])
		keys.append([verb, target, item])
		if wildcards:
			keys.append([verb, "*", target])
			keys.append([verb, item, "*"])
			keys.append([verb, "*", "*"])
			keys.append(["*", "", "*"])
	else:
		keys.append([verb, "", target])
		if wildcards:
			keys.append(["*", "", target])
			keys.append([verb, "", "*"])
			keys.append(["*", "", "*"])
	var local: Dictionary = room_handlers.get(room, {})
	for k in keys:
		var key := handler_key(k[0], k[1], k[2])
		if local.has(key):
			return local[key]
		if global_handlers.has(key):
			return global_handlers[key]
	return {}


## True when some handler uses [param item] together with a second object
## (`on use key on door`), so a verb interface should wait for "use key with ...".
func item_has_targets(verb: String, item: String) -> bool:
	var prefix := "%s|%s|" % [verb, item]
	for table in [global_handlers] + room_handlers.values():
		for key in table:
			if key.begins_with(prefix) and key.length() > prefix.length():
				return true
	return false


## Room events (enter, exit, setup) come from the room script, game events (start) from global scripts.
func find_event(room: String, event: String) -> Dictionary:
	var key := handler_key(event, "", "")
	if room != "":
		return room_handlers.get(room, {}).get(key, {})
	return global_handlers.get(key, {})


func room_of_path(path: String) -> String:
	var prefix := game_dir + "/rooms/"
	if not path.begins_with(prefix):
		return ""
	var rel := path.substr(prefix.length())
	var slash := rel.find("/")
	return rel.left(slash) if slash != -1 else ""


func item_name(id: String) -> String:
	if items.has(id) and items[id].name != "":
		return items[id].name
	return id.capitalize()


func issue(file: String, line: int, level: String, msg: String) -> void:
	issues.append({"file": file, "line": line, "level": level, "msg": msg})


func error_count() -> int:
	var n := 0
	for i in issues:
		if i.level == "error":
			n += 1
	return n


func _discover_rooms() -> void:
	var dir := game_dir + "/rooms"
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		for ext in ["tscn", "scn"]:
			var p := "%s/%s/%s.%s" % [dir, sub, sub, ext]
			if ResourceLoader.exists(p):
				rooms[sub] = p
				break


func _discover_overlays() -> void:
	var dir := game_dir + "/overlays"
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		var file := f.trim_suffix(".remap")
		if file.get_extension() in ["tscn", "scn"]:
			overlays[file.get_basename()] = dir + "/" + file


func _discover_characters() -> void:
	var dir := game_dir + "/characters"
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		for ext in ["tscn", "scn"]:
			var p := "%s/%s/%s.%s" % [dir, sub, sub, ext]
			if ResourceLoader.exists(p):
				characters[sub] = {"id": sub, "name": "", "props": {}, "scene": p}
				break
	for f in DirAccess.get_files_at(dir):
		var file := f.trim_suffix(".remap")
		if file.get_extension() in ["tscn", "scn"]:
			var id := file.get_basename()
			if not characters.has(id):
				characters[id] = {"id": id, "name": "", "props": {}, "scene": dir + "/" + file}


## Recursively lists files with the given extensions (skips hidden folders).
static func find_files(dir: String, exts: Array) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		var file := f.trim_suffix(".remap")
		if file.get_extension() in exts:
			out.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			out.append_array(find_files(dir.path_join(sub), exts))
	return out
