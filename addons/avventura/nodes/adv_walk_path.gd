@tool
@icon("res://addons/avventura/icons/walk_area.svg")
class_name AdvWalkPath
extends Line2D
## Trails characters walk along (a map's paths, Monkey Island style): instead of an area,
## the walkable space is a network of lines. Lines that cross, or whose vertices touch
## another line, are joined; clicks snap to the nearest point of the network.
##
## When a room has any enabled AdvWalkPath, its AdvWalkArea polygons are ignored.
## Script: `enable NAME` / `disable NAME` switch a trail on and off.

## Disabled trails are ignored (a bridge that collapses, a passage that opens...).
@export var enabled := true

const PATH_COLOR := Color(0.2, 0.9, 0.4, 0.6)


func _ready() -> void:
	if Engine.is_editor_hint():
		if default_color == Color(1, 1, 1, 1):
			default_color = PATH_COLOR
	else:
		visible = ProjectSettings.get_setting("avventura/debug/show_walk_areas", false)


func get_area_id() -> String:
	return AdvHotspot.to_id(name)


## The line in the coordinates of [param room].
func points_in(room: Node2D) -> PackedVector2Array:
	var xf := room.global_transform.affine_inverse() * global_transform
	var out := PackedVector2Array()
	for p in points:
		out.append(xf * p)
	return out
