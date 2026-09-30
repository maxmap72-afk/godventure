class_name AdvState
extends RefCounted
## Everything that changes while playing. It is saved as readable JSON, so it can be
## inspected (and edited) by people and tools alike.

const VERSION := 1

## Game variables set with `set` / `var`.
var vars: Dictionary = {}
## Inventory per character: {char_id: [item_id, ...]}.
var inventory: Dictionary = {}
## Current room id.
var room := ""
## Id of the character controlled by the player.
var player := ""
## Engine-managed characters: {char_id: {"room": String, "pos": Vector2 or null, "at": String, "dir": String}}.
var chars: Dictionary = {}
## Per-room object overrides: {"room/object": {"visible": bool, "enabled": bool, "state": String}}.
var objects: Dictionary = {}
## Visits per room.
var visited: Dictionary = {}
## Dialog options: {"dialog.option": {"on": bool, "used": int}}.
var options: Dictionary = {}
## Execution counters for handlers and random/cycle/sequence/once blocks.
var counters: Dictionary = {}
## Free space for GDScript extensions (saved too).
var custom: Dictionary = {}
## Seconds played.
var playtime := 0.0


func items_of(char_id: String) -> Array:
	if not inventory.has(char_id):
		inventory[char_id] = []
	return inventory[char_id]


func object(room_id: String, obj_id: String) -> Dictionary:
	return objects.get(room_id + "/" + obj_id, {})


func set_object(room_id: String, obj_id: String, key: String, value: Variant) -> void:
	var k := room_id + "/" + obj_id
	if not objects.has(k):
		objects[k] = {}
	objects[k][key] = value


func option(ref: String) -> Dictionary:
	if not options.has(ref):
		options[ref] = {}
	return options[ref]


func count(key: String) -> int:
	return int(counters.get(key, 0))


## Returns the counter value, then increments it.
func bump(key: String) -> int:
	var n := count(key)
	counters[key] = n + 1
	return n


func to_dict() -> Dictionary:
	var ch := {}
	for id in chars:
		var c: Dictionary = chars[id].duplicate()
		if c.get("pos") is Vector2:
			c.pos = [c.pos.x, c.pos.y]
		ch[id] = c
	return {
		"version": VERSION,
		"room": room,
		"player": player,
		"vars": vars.duplicate(true),
		"inventory": inventory.duplicate(true),
		"chars": ch,
		"objects": objects.duplicate(true),
		"visited": visited.duplicate(),
		"options": options.duplicate(true),
		"counters": counters.duplicate(),
		"custom": custom.duplicate(true),
		"playtime": playtime,
	}


func from_dict(d: Dictionary) -> void:
	d = _ints(d)
	room = str(d.get("room", ""))
	player = str(d.get("player", ""))
	vars = d.get("vars", {})
	inventory = d.get("inventory", {})
	objects = d.get("objects", {})
	visited = d.get("visited", {})
	options = d.get("options", {})
	counters = d.get("counters", {})
	custom = d.get("custom", {})
	playtime = float(d.get("playtime", 0.0))
	chars = {}
	var ch: Dictionary = d.get("chars", {})
	for id in ch:
		var c: Dictionary = ch[id]
		if c.get("pos") is Array and c.pos.size() == 2:
			c.pos = Vector2(c.pos[0], c.pos[1])
		chars[id] = c


func to_json() -> String:
	return JSON.stringify(to_dict(), "  ")


static func from_json(text: String) -> AdvState:
	var data = JSON.parse_string(text)
	if not data is Dictionary:
		return null
	var s := AdvState.new()
	s.from_dict(data)
	return s


## JSON turns every number into a float: bring whole numbers back to int.
static func _ints(v: Variant) -> Variant:
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return int(v)
	if v is Array:
		var a := []
		for e in v:
			a.append(_ints(e))
		return a
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _ints(v[k])
		return d
	return v
