@tool
@icon("res://addons/avventura/icons/room.svg")
class_name AdvRoom
extends Node2D
## Root node of a room scene (game/rooms/<id>/<id>.tscn). Its script lives next to it
## (<id>.adv).
##
## Typical children: "Background" (Sprite2D, z_index -100), one or more AdvWalkArea,
## AdvHotspot / AdvCharacter nodes, Marker2D / AdvEntry nodes as entry points (a marker
## named like another room is where you appear when coming from that room).
## Attach a GDScript extending AdvRoom to add functions callable with `call` from AdvScript.

## Id used by scripts. Empty: the scene file name.
@export var room_id := ""
## Name shown in save slots.
@export var display_name := ""
## Room size in pixels. Zero: size of the "Background" texture (or the window).
@export var size := Vector2i.ZERO:
	set(v):
		size = v
		queue_redraw()
## Music played on enter (file name in game/audio, without extension).
@export var music := ""
## Background color drawn when there is no "Background" node (handy for prototypes).
@export var background_color := Color(0.16, 0.17, 0.24):
	set(v):
		background_color = v
		queue_redraw()

@export_group("Perspective")
## Characters are scaled from far_scale (at far_y) to near_scale (at near_y).
@export var far_y := 0.0:
	set(v):
		far_y = v
		queue_redraw()
@export var far_scale := 1.0:
	set(v):
		far_scale = v
		queue_redraw()
@export var near_y := 720.0:
	set(v):
		near_y = v
		queue_redraw()
@export var near_scale := 1.0:
	set(v):
		near_scale = v
		queue_redraw()

@export_group("Camera")
## Keep the camera on the player (for rooms wider than the screen).
@export var camera_follow := true

var pathfinder := AdvPathfinder.new()


func _ready() -> void:
	if Engine.is_editor_hint():
		queue_redraw()
		return
	if get_tree().current_scene == self:
		# Started on its own (F6 / "Play from this room"): boot the game from this room.
		Adv.args["start"] = get_room_id()
		Adv.args["from-room"] = true
		get_tree().change_scene_to_file.call_deferred(ProjectSettings.get_setting("application/run/main_scene"))
		return
	y_sort_enabled = true
	rebuild_walkable()


func get_room_id() -> String:
	if room_id != "":
		return room_id
	return scene_file_path.get_file().get_basename()


func get_display_name() -> String:
	return display_name if display_name != "" else get_room_id().capitalize()


func get_size() -> Vector2:
	if size != Vector2i.ZERO:
		return Vector2(size)
	var bg := get_node_or_null("Background")
	if bg is Sprite2D and bg.texture:
		var r: Rect2 = bg.get_rect()
		return (r.position + r.size) * bg.scale + bg.position
	if bg is TextureRect:
		return bg.size
	return Vector2(ProjectSettings.get_setting("display/window/size/viewport_width", 1280),
		ProjectSettings.get_setting("display/window/size/viewport_height", 720))


## Character scale at height [param y] (perspective).
func scale_at(y: float) -> float:
	if is_equal_approx(far_y, near_y):
		return near_scale
	var t := clampf((y - far_y) / (near_y - far_y), 0.0, 1.0)
	return lerpf(far_scale, near_scale, t)


## Recomputes paths after walk areas change (called automatically by enable/disable).
func rebuild_walkable() -> void:
	var walk := []
	var block := []
	for n in nodes_of_type(self, "AdvWalkArea"):
		var area: AdvWalkArea = n
		if not area.enabled or area.polygon.size() < 3:
			continue
		if area.blocked:
			block.append(area.polygon_in(self))
		else:
			walk.append(area.polygon_in(self))
			block.append_array(area.hole_polygons(self))
	pathfinder.build(walk, block)


func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	return pathfinder.find_path(from, to)


func closest_walkable(p: Vector2) -> Vector2:
	return pathfinder.closest_walkable(p)


func is_walkable(p: Vector2) -> bool:
	return pathfinder.is_walkable(p)


## All hotspots in the room, characters included.
func get_hotspots() -> Array:
	return nodes_of_type(self, "AdvHotspot")


func find_hotspot(id: String) -> AdvHotspot:
	for h in get_hotspots():
		if h.get_id() == id:
			return h
	return null


func find_walk_area(id: String) -> AdvWalkArea:
	for a in nodes_of_type(self, "AdvWalkArea"):
		if a.get_area_id() == id or String(a.name) == id:
			return a
	return null


## A node used as a position: an entry marker, a hotspot, any Node2D with that name.
func find_marker(id: String) -> Node2D:
	var h := find_hotspot(id)
	if h:
		return h
	var n := find_child(id, true, false)
	if n is Node2D:
		return n
	for c in nodes_of_type(self, "Node2D"):
		if AdvHotspot.to_id(c.name) == id:
			return c
	return null


## Names of all entry points (Marker2D nodes).
func get_markers() -> Array:
	var out := []
	for c in nodes_of_type(self, "Marker2D"):
		if String(c.name) != "WalkTo":
			out.append(String(c.name))
	return out


## Recursive search by class, script classes included.
static func nodes_of_type(root: Node, type_name: String) -> Array:
	var out := []
	for c in root.get_children():
		if _is_type(c, type_name):
			out.append(c)
		out.append_array(nodes_of_type(c, type_name))
	return out


static func _is_type(n: Node, type_name: String) -> bool:
	match type_name:
		"AdvHotspot":
			return n is AdvHotspot
		"AdvCharacter":
			return n is AdvCharacter
		"AdvWalkArea":
			return n is AdvWalkArea
		"Marker2D":
			return n is Marker2D
		"Node2D":
			return n is Node2D
	return n.is_class(type_name)


func _draw() -> void:
	var s := get_size()
	if get_node_or_null("Background") == null:
		draw_rect(Rect2(Vector2.ZERO, s), background_color)
	if not Engine.is_editor_hint():
		return
	draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.35), false, 2.0)
	if not is_equal_approx(far_scale, near_scale):
		var font := ThemeDB.fallback_font
		for pair in [[far_y, far_scale], [near_y, near_scale]]:
			draw_dashed_line(Vector2(0, pair[0]), Vector2(s.x, pair[0]), Color(0.4, 0.8, 1, 0.8), 2.0, 12.0)
			draw_string(font, Vector2(8, pair[0] - 6), "scale x%.2f" % pair[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.4, 0.8, 1))
