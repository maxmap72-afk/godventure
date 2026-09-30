@tool
@icon("res://addons/avventura/icons/walk_area.svg")
class_name AdvWalkArea
extends Polygon2D
## Area where characters can walk. Draw it with the polygon editor (select the node,
## then use the polygon tools in the 2D toolbar).
##
## Child Polygon2D nodes are obstacles (holes). Set [member blocked] to turn this node
## itself into an obstacle. Script: `enable NAME` / `disable NAME` switch it on and off.

## When true this polygon blocks movement instead of allowing it.
@export var blocked := false:
	set(v):
		blocked = v
		_update_look()
## Disabled areas are ignored (for bridges that appear, doors that open...).
@export var enabled := true

const WALK_COLOR := Color(0.2, 0.9, 0.4, 0.25)
const BLOCK_COLOR := Color(0.95, 0.25, 0.2, 0.3)


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_look()
	else:
		visible = ProjectSettings.get_setting("avventura/debug/show_walk_areas", false)


func _update_look() -> void:
	if Engine.is_editor_hint() and (color == Color(1, 1, 1, 1) or color == WALK_COLOR or color == BLOCK_COLOR):
		color = BLOCK_COLOR if blocked else WALK_COLOR


func get_area_id() -> String:
	return AdvHotspot.to_id(name)


## This polygon in the coordinates of [param room].
func polygon_in(room: Node2D) -> PackedVector2Array:
	return to_room(room, self)


## Obstacles defined as child polygons, in the coordinates of [param room].
func hole_polygons(room: Node2D) -> Array:
	var out := []
	for c in get_children():
		if c is Polygon2D and not c is AdvWalkArea and c.polygon.size() >= 3:
			out.append(to_room(room, c))
	return out


static func to_room(room: Node2D, node: Polygon2D) -> PackedVector2Array:
	var xf := room.global_transform.affine_inverse() * node.global_transform
	var out := PackedVector2Array()
	for p in node.polygon:
		out.append(xf * (p + node.offset))
	return out
