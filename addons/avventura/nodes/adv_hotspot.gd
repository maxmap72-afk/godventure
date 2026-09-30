@tool
@icon("res://addons/avventura/icons/hotspot.svg")
class_name AdvHotspot
extends Area2D
## Something the player can interact with: a background area, an object with a sprite,
## an exit. Characters are hotspots too.
##
## Clickable shape: a child CollisionPolygon2D / CollisionShape2D, otherwise the rect of
## a child Sprite2D / AnimatedSprite2D. Where the player stands: a child node named
## "WalkTo", otherwise [member walk_to] (relative), otherwise the nearest walkable point.
##
## Without writing any script: set [member description] (right click / look),
## [member pickup_item] (it becomes an item you can pick up) or [member exit_to].

signal state_changed(state: String)

## Id used by scripts (`on look ID:`). Empty: derived from the node name ("OldSign" -> "old_sign").
@export var hotspot_id := ""
## Name shown when the mouse is over it.
@export var display_name := ""
## Said by the player on `look` when no script handles it.
@export_multiline var description := ""
## Action for the main click (two-click interface) or right click (SCUMM interface).
@export var default_verb := "use"
## Relative position where the player stands to interact (used when there is no "WalkTo" child).
@export var walk_to := Vector2.ZERO
## Direction the player faces after reaching it.
@export_enum("auto", "left", "right", "up", "down") var face := "auto"
## Whether the player walks here before interacting.
@export var walk_before := true
## Interactive or not (also `enable`/`disable` in scripts).
@export var interactive := true

@export_group("Shortcuts")
## When set, picking this up hides it and adds this item to the inventory (no script needed).
@export var pickup_item := ""
## Room reached through this hotspot (it becomes an exit).
@export var exit_to := ""
## Entry point in the destination room. Empty: a marker named like the current room.
@export var exit_entry := ""

@export_group("Advanced")
## Higher wins when hotspots overlap.
@export var click_priority := 0
## Use the sprite's opaque pixels as the clickable shape.
@export var pixel_perfect := false

var state := ""


func _ready() -> void:
	input_pickable = false
	monitoring = false
	monitorable = false
	if Engine.is_editor_hint():
		set_notify_transform(true)


func get_id() -> String:
	return hotspot_id if hotspot_id != "" else to_id(name)


func get_display_name() -> String:
	return display_name if display_name != "" else get_id().capitalize()


func get_default_verb() -> String:
	if exit_to != "":
		return "walk"
	if pickup_item != "" and default_verb == "use":
		return "pick"
	return default_verb


func is_exit() -> bool:
	return exit_to != ""


## Point where the player should stand to interact, in global coordinates.
func get_walk_point(_from: Vector2 = Vector2.ZERO) -> Vector2:
	var marker := get_node_or_null("WalkTo")
	if marker is Node2D:
		return marker.global_position
	return global_position + walk_to


## Bounding box of the clickable shape, in global coordinates.
func get_global_bounds() -> Rect2:
	var rect := Rect2()
	var first := true
	for c in get_children():
		var pts := PackedVector2Array()
		if c is CollisionPolygon2D:
			for p in c.polygon:
				pts.append(c.to_global(p))
		elif c is CollisionShape2D and c.shape:
			var r: Rect2 = c.shape.get_rect()
			for p in [r.position, r.end, Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y)]:
				pts.append(c.to_global(p))
		elif (c is Sprite2D or c is AnimatedSprite2D) and c.visible:
			var r := sprite_rect(c)
			if r.size != Vector2.ZERO:
				for p in [r.position, r.end]:
					pts.append(c.to_global(p))
		for p in pts:
			if first:
				rect = Rect2(p, Vector2.ZERO)
				first = false
			else:
				rect = rect.expand(p)
	if first:
		var fr := _fallback_rect()
		return Rect2(to_global(fr.position), fr.size * global_scale.abs()) if fr.size != Vector2.ZERO else Rect2(global_position, Vector2.ZERO)
	return rect


## Does the clickable shape contain [param global_point]?
func contains_point(global_point: Vector2) -> bool:
	var has_shape := false
	for c in get_children():
		if c is CollisionPolygon2D:
			has_shape = true
			if not c.disabled and Geometry2D.is_point_in_polygon(c.to_local(global_point), c.polygon):
				return true
		elif c is CollisionShape2D and c.shape:
			has_shape = true
			if not c.disabled and _shape_has_point(c.shape, c.to_local(global_point)):
				return true
	if has_shape:
		return false
	for c in get_children():
		if (c is Sprite2D or c is AnimatedSprite2D) and c.visible:
			var lp: Vector2 = c.to_local(global_point)
			var rect := sprite_rect(c)
			if rect.has_point(lp):
				if not pixel_perfect or not c is Sprite2D:
					return true
				if c.is_pixel_opaque(lp):
					return true
	return _fallback_rect().has_point(to_local(global_point))


## Area used when there is no shape and no sprite (overridden by characters).
func _fallback_rect() -> Rect2:
	return Rect2()


static func sprite_rect(s: Node2D) -> Rect2:
	var tex: Texture2D = null
	if s is Sprite2D:
		return s.get_rect()
	if s is AnimatedSprite2D and s.sprite_frames and s.sprite_frames.has_animation(s.animation):
		if s.sprite_frames.get_frame_count(s.animation) > 0:
			tex = s.sprite_frames.get_frame_texture(s.animation, s.frame)
	if tex == null:
		return Rect2()
	var size := tex.get_size()
	var pos: Vector2 = s.offset - (size / 2.0 if s.centered else Vector2.ZERO)
	return Rect2(pos, size)


static func _shape_has_point(shape: Shape2D, p: Vector2) -> bool:
	if shape is RectangleShape2D:
		return Rect2(-shape.size / 2.0, shape.size).has_point(p)
	if shape is CircleShape2D:
		return p.length() <= shape.radius
	if shape is CapsuleShape2D:
		var half: float = maxf(shape.height / 2.0 - shape.radius, 0.0)
		var q := Vector2(p.x, clampf(p.y, -half, half))
		return p.distance_to(q) <= shape.radius
	if shape is ConvexPolygonShape2D:
		return Geometry2D.is_point_in_polygon(p, shape.points)
	return false


## Applies a visual state: plays the animation with that name on a child
## AnimatedSprite2D or AnimationPlayer, and shows children named "state_<name>".
func set_state(value: String) -> void:
	state = value
	for c in get_children():
		if c is AnimatedSprite2D and c.sprite_frames and c.sprite_frames.has_animation(value):
			c.play(value)
		elif c is AnimationPlayer and c.has_animation(value):
			c.play(value)
		elif c is CanvasItem and String(c.name).begins_with("state_"):
			c.visible = String(c.name).substr(6) == value
	state_changed.emit(value)


## "OldSign" -> "old_sign", "Porta 2" -> "porta_2".
static func to_id(node_name: String) -> String:
	return node_name.to_snake_case().replace(" ", "_").replace("-", "_")


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		queue_redraw()


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	# Editor helpers: name tag and walk-to point.
	var font := ThemeDB.fallback_font
	var label := get_display_name()
	if exit_to != "":
		label += "  → " + exit_to
	draw_string(font, Vector2(-40, -8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.9, 0.3))
	if get_node_or_null("WalkTo") == null and walk_to != Vector2.ZERO:
		var p := walk_to
		draw_line(p + Vector2(-6, -6), p + Vector2(6, 6), Color(0.3, 1, 0.5), 2)
		draw_line(p + Vector2(-6, 6), p + Vector2(6, -6), Color(0.3, 1, 0.5), 2)
		draw_line(Vector2.ZERO, p, Color(0.3, 1, 0.5, 0.4), 1)
