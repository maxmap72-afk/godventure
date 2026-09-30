@tool
class_name AdvScaffold
extends RefCounted
## Creates rooms, characters and items following the folder conventions.
## Used by the editor workspace and by `tools/adv.py new-room|new-character|new-item`.


static func new_room(game_dir: String, id: String, display_name: String = "") -> Dictionary:
	if not AdvExpr.is_ident(id) or "." in id:
		return {"error": "'%s' is not a valid id: use lowercase letters, digits and _" % id}
	var dir := "%s/rooms/%s" % [game_dir, id]
	var scene_path := "%s/%s.tscn" % [dir, id]
	var script_path := "%s/%s.adv" % [dir, id]
	if FileAccess.file_exists(scene_path):
		return {"error": "room '%s' already exists" % id}
	DirAccess.make_dir_recursive_absolute(dir)
	var w := float(ProjectSettings.get_setting("display/window/size/viewport_width", 1280))
	var h := float(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	var root := AdvRoom.new()
	root.name = id.to_pascal_case()
	root.display_name = display_name if display_name != "" else id.capitalize()
	root.near_y = h
	var bg := Sprite2D.new()
	bg.name = "Background"
	bg.centered = false
	bg.z_index = -100
	_add(root, bg)
	var area := AdvWalkArea.new()
	area.name = "WalkArea"
	area.color = AdvWalkArea.WALK_COLOR
	area.polygon = PackedVector2Array([Vector2(40, h * 0.66), Vector2(w - 40, h * 0.66), Vector2(w - 40, h - 20), Vector2(40, h - 20)])
	_add(root, area)
	var entry := AdvEntry.new()
	entry.name = "default"
	entry.position = Vector2(w / 2.0, h * 0.83)
	_add(root, entry)
	var room_name := root.display_name
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK:
		return {"error": "cannot pack the room scene (error %d)" % err}
	err = ResourceSaver.save(packed, scene_path)
	if err != OK:
		return {"error": "cannot save %s (error %d)" % [scene_path, err]}
	var text := (_ROOM_IT if _italian() else _ROOM_EN) % [room_name, id, room_name]
	_write(script_path, text)
	return {"files": [scene_path, script_path]}


static func new_character(game_dir: String, id: String, display_name: String = "", color: String = "", with_scene: bool = false) -> Dictionary:
	if not AdvExpr.is_ident(id) or "." in id:
		return {"error": "'%s' is not a valid id: use lowercase letters, digits and _" % id}
	var path := game_dir + "/characters.adv"
	if _declared(game_dir, "character", id):
		return {"error": "character '%s' already exists" % id}
	if color == "":
		color = Color.from_hsv(randf(), 0.55, 0.95).to_html(false)
	var text := "\ncharacter %s \"%s\":\n    color = #%s\n" % [id, display_name if display_name != "" else id.capitalize(), color.trim_prefix("#")]
	_append(path, text)
	var files := [path]
	if with_scene:
		var dir := "%s/characters/%s" % [game_dir, id]
		DirAccess.make_dir_recursive_absolute(dir)
		var root := AdvCharacter.new()
		root.name = id.to_pascal_case()
		root.hotspot_id = id
		var sprite := AnimatedSprite2D.new()
		sprite.name = "Sprite"
		sprite.centered = true
		sprite.offset = Vector2(0, -75)
		sprite.sprite_frames = SpriteFrames.new()
		for a in ["idle_down", "idle_up", "idle_side", "walk_down", "walk_up", "walk_side", "talk_down", "talk_side"]:
			sprite.sprite_frames.add_animation(a)
		_add(root, sprite)
		var packed := PackedScene.new()
		packed.pack(root)
		root.free()
		var scene_path := "%s/%s.tscn" % [dir, id]
		ResourceSaver.save(packed, scene_path)
		files.append(scene_path)
	return {"files": files}


static func new_item(game_dir: String, id: String, display_name: String = "") -> Dictionary:
	if not AdvExpr.is_ident(id) or "." in id:
		return {"error": "'%s' is not a valid id: use lowercase letters, digits and _" % id}
	if _declared(game_dir, "item", id):
		return {"error": "item '%s' already exists" % id}
	var path := game_dir + "/items.adv"
	_append(path, "item %s \"%s\"\n" % [id, display_name if display_name != "" else id.capitalize()])
	return {"files": [path]}


const _ROOM_EN := """# Room: %s
# Handlers written here only work in this room.
# Add hotspots to %s.tscn (AdvHotspot nodes), then describe what happens:
#
# on look OBJECT:
#     player: What I see.
# on use OBJECT:
#     player: What happens.

on enter:
    if first:
        player: So this is %s.
"""

const _ROOM_IT := """# Stanza: %s
# Gli script scritti qui valgono solo in questa stanza.
# Aggiungi gli hotspot a %s.tscn (nodi AdvHotspot), poi descrivi cosa succede:
#
# on look OGGETTO:
#     player: Cosa vedo.
# on use OGGETTO:
#     player: Cosa succede.

on enter:
    if first:
        player: Ecco %s.
"""


## Templates follow the game language (avventura/gui/language), then the editor/system locale.
static func _italian() -> bool:
	var lang := str(ProjectSettings.get_setting("avventura/gui/language", ""))
	if lang == "" and Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		# Looked up dynamically: this script also runs in exported games, without editor classes.
		var ei: Object = Engine.get_singleton("EditorInterface")
		lang = str(ei.get_editor_settings().get_setting("interface/editor/editor_language"))
	if lang == "":
		lang = OS.get_locale_language()
	return lang.begins_with("it")


static func _declared(game_dir: String, kind: String, id: String) -> bool:
	for f in AdvRegistry.find_files(game_dir, ["adv"]):
		var parsed := AdvParser.parse(FileAccess.get_file_as_string(f), f)
		for d in parsed.decls:
			if d.k == kind and d.id == id:
				return true
	return false


static func _add(root: Node, child: Node) -> void:
	root.add_child(child)
	child.owner = root


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()


static func _append(path: String, text: String) -> void:
	var existing := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if existing != "" and not existing.ends_with("\n"):
		existing += "\n"
	_write(path, existing + text)
