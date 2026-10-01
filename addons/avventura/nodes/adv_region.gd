@tool
@icon("res://addons/avventura/icons/region.svg")
class_name AdvRegion
extends Polygon2D
## An area of the floor that runs scripts when the player walks onto it or off it
## (AGS regions):
##   on walk_onto REGION_ID:
##   on walk_off REGION_ID:
## Draw it with the polygon editor; it is invisible while playing.
## Script: `enable ID` / `disable ID`.

@export var region_id := ""
@export var enabled := true

const REGION_COLOR := Color(0.3, 0.6, 1.0, 0.25)


func _ready() -> void:
	if Engine.is_editor_hint():
		if color == Color(1, 1, 1, 1):
			color = REGION_COLOR
	else:
		visible = ProjectSettings.get_setting("avventura/debug/show_walk_areas", false)


func get_region_id() -> String:
	return region_id if region_id != "" else AdvHotspot.to_id(name)


## Is [param room_point] (room coordinates) inside the region?
func contains(room_point: Vector2, room: Node2D) -> bool:
	var local := (room.global_transform.affine_inverse() * global_transform).affine_inverse() * room_point - offset
	return Geometry2D.is_point_in_polygon(local, polygon)
