@tool
@icon("res://addons/avventura/icons/character.svg")
class_name AdvCharacter
extends AdvHotspot
## A character: the player or an NPC. It walks on the room's walk areas, talks and plays
## animations. It is also a hotspot, so the player can look at it, talk to it, give it items.
##
## Graphics: add a child AnimatedSprite2D with animations named
##   idle_down, idle_up, idle_side (or idle_left/idle_right), walk_*, talk_*
## ("side" animations face right unless [member side_faces_left]). Custom animations are
## played by `anim NAME`. Without sprites a drawn placeholder puppet is used, so you can
## prototype a whole game before drawing anything.

signal movement_finished(reached: bool)

## Color of the character's speech text.
@export var text_color := Color(1, 1, 1)
## Pixels per second at scale 1.
@export var walk_speed := 220.0
## Height in pixels at scale 1: size of the placeholder, clickable area, speech position.
@export var height := 150.0
@export_enum("down", "up", "left", "right") var direction := "down":
	set(v):
		direction = v
		queue_redraw()
## Set when the "side" animations face left.
@export var side_faces_left := false

@export_group("Placeholder look")
@export var body_color := Color(0.25, 0.55, 0.85):
	set(v):
		body_color = v
		queue_redraw()
@export var skin_color := Color(1.0, 0.82, 0.66)
@export var hair_color := Color(0.3, 0.18, 0.1)

var is_walking := false
var is_talking := false
var _path := PackedVector2Array()
var _path_i := 0
var _t := 0.0
var _custom_anim := ""
var _sprite: AnimatedSprite2D
var _base_scale := Vector2.ONE


func _ready() -> void:
	super()
	_base_scale = scale
	for c in get_children():
		if c is AnimatedSprite2D:
			_sprite = c
			break
	if not Engine.is_editor_hint():
		_update_scale()
		_update_anim()


func get_default_verb() -> String:
	return "talk" if default_verb == "use" else default_verb


func get_walk_point(from: Vector2 = Vector2.ZERO) -> Vector2:
	var marker := get_node_or_null("WalkTo")
	if marker is Node2D:
		return marker.global_position
	if walk_to != Vector2.ZERO:
		return global_position + walk_to
	var side := -1.0 if from.x < global_position.x else 1.0
	return global_position + Vector2(side * maxf(70.0, height * 0.5) * absf(scale.x), 0)


## Global position above the head, where speech is shown.
func get_speech_anchor() -> Vector2:
	var top := -height
	if _sprite:
		var r := AdvHotspot.sprite_rect(_sprite)
		if r.size != Vector2.ZERO:
			top = (_sprite.position + r.position * _sprite.scale).y
	return to_global(Vector2(0, top - 14))


func has_visuals() -> bool:
	for c in get_children():
		if c is Sprite2D or c is AnimatedSprite2D:
			return true
	return false


func _fallback_rect() -> Rect2:
	var w := height * 0.34
	return Rect2(-w / 2.0 - 6.0, -height - 4.0, w + 12.0, height + 6.0)


# --- movement ------------------------------------------------------------------------

## Position in the coordinates of the room.
func room_position() -> Vector2:
	var room := _room()
	return room.to_local(global_position) if room else position


func set_room_position(p: Vector2) -> void:
	var room := _room()
	if room:
		global_position = room.to_global(p)
	else:
		position = p
	_update_scale()


## Walks to [param target] (room coordinates). Returns true when it gets there,
## false when it can't reach it or it's interrupted by another walk.
## With [param anywhere] the walk areas are ignored (AGS eAnywhere).
func move_to(target: Vector2, anywhere: bool = false) -> bool:
	if is_walking:
		_finish(false)
	var room := _room()
	var from := room_position()
	var path := room.find_path(from, target) if room and not anywhere else PackedVector2Array([from, target])
	if path.is_empty():
		return false
	if path.size() < 2 or from.distance_to(path[path.size() - 1]) < 1.0:
		return true
	_path = path
	_path_i = 1
	_custom_anim = ""
	is_walking = true
	var reached: bool = await movement_finished
	return reached


func stop() -> void:
	if is_walking:
		_finish(false)


## Moves instantly (clamped to the walkable area).
func teleport(p: Vector2) -> void:
	stop()
	var room := _room()
	set_room_position(room.closest_walkable(p) if room else p)


func face_towards(global_point: Vector2) -> void:
	var v := global_point - global_position
	if v.length() < 1.0:
		return
	direction = dir_of(v)
	_update_anim()


func face_dir(dir: String) -> void:
	if dir in ["left", "right", "up", "down"]:
		direction = dir
		_update_anim()


static func dir_of(v: Vector2) -> String:
	if absf(v.x) >= absf(v.y) * 0.9:
		return "right" if v.x > 0 else "left"
	return "down" if v.y > 0 else "up"


func _finish(reached: bool) -> void:
	is_walking = false
	_path = PackedVector2Array()
	_update_anim()
	movement_finished.emit(reached)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_t += delta
	if is_walking:
		_advance(delta)
	_update_scale()
	_update_anim()
	if not has_visuals():
		queue_redraw()


func _advance(delta: float) -> void:
	var room := _room()
	var s := room.scale_at(room_position().y) if room else 1.0
	var budget := walk_speed * s * delta
	var pos := room_position()
	while budget > 0.0 and _path_i < _path.size():
		var target := _path[_path_i]
		var to := target - pos
		var dist := to.length()
		if dist > 0.5:
			direction = dir_of(to)
		if dist <= budget:
			pos = target
			budget -= dist
			_path_i += 1
		else:
			pos += to / dist * budget
			budget = 0.0
	set_room_position(pos)
	if _path_i >= _path.size():
		_finish(true)


func _update_scale() -> void:
	var room := _room()
	if room:
		var s := room.scale_at(room_position().y)
		scale = _base_scale * s


func _room() -> AdvRoom:
	var n := get_parent()
	while n:
		if n is AdvRoom:
			return n
		n = n.get_parent()
	return null


# --- talking and animations -----------------------------------------------------------

func start_talking(mood: String = "") -> void:
	is_talking = true
	if mood != "" and _sprite and _sprite.sprite_frames.has_animation("talk_" + mood):
		_custom_anim = "talk_" + mood
		_sprite.play(_custom_anim)
	_update_anim()


func stop_talking() -> void:
	is_talking = false
	if _custom_anim.begins_with("talk_"):
		_custom_anim = ""
	_update_anim()


func has_anim(anim: String) -> bool:
	if _sprite and _sprite.sprite_frames and _resolve_anim(anim) != "":
		return true
	var player := _anim_player()
	return player != null and player.has_animation(anim)


## Plays a custom animation. With [param wait] it returns when a non-looping animation ends.
func play_anim(anim: String, wait: bool = true, loop: bool = false) -> void:
	if anim in ["idle", "stop"]:
		_custom_anim = ""
		_update_anim()
		return
	var player := _anim_player()
	var sprite_anim := _resolve_anim(anim) if _sprite and _sprite.sprite_frames else ""
	if sprite_anim != "":
		_custom_anim = anim
		_sprite.play(sprite_anim)
		if wait and not loop and not _sprite.sprite_frames.get_animation_loop(sprite_anim):
			await _sprite.animation_finished
			if _custom_anim == anim:
				_custom_anim = ""
	elif player and player.has_animation(anim):
		_custom_anim = anim
		player.play(anim)
		if wait and not loop:
			await player.animation_finished
			if _custom_anim == anim:
				_custom_anim = ""
	else:
		# Placeholder gesture, so scripts work before the art exists.
		_custom_anim = anim
		if loop:
			return
		if wait:
			await get_tree().create_timer(0.6).timeout
			if _custom_anim == anim:
				_custom_anim = ""
		else:
			get_tree().create_timer(0.6).timeout.connect(func(): if _custom_anim == anim: _custom_anim = "")


## Name of the sprite animation for [param anim]: the animation itself, or its variant for the
## current direction (NAME_left, NAME_side...), flipping the sprite when needed.
func _resolve_anim(anim: String) -> String:
	var frames := _sprite.sprite_frames
	if frames.has_animation(anim):
		_sprite.flip_h = false
		return anim
	var flip_side := not side_faces_left
	var candidates: Array
	match direction:
		"left":
			candidates = [[anim + "_left", false], [anim + "_side", flip_side], [anim + "_right", true]]
		"right":
			candidates = [[anim + "_right", false], [anim + "_side", not flip_side], [anim + "_left", true]]
		"up":
			candidates = [[anim + "_up", false]]
		_:
			candidates = [[anim + "_down", false]]
	candidates.append([anim + "_down", false])
	for c in candidates:
		if frames.has_animation(c[0]):
			_sprite.flip_h = c[1]
			return c[0]
	return ""


func _anim_player() -> AnimationPlayer:
	for c in get_children():
		if c is AnimationPlayer:
			return c
	return null


func _update_anim() -> void:
	if _sprite == null or _sprite.sprite_frames == null or _custom_anim != "":
		return
	var base := "walk" if is_walking else ("talk" if is_talking else "idle")
	if not _play_dir(base) and base != "idle":
		_play_dir("idle")


func _play_dir(base: String) -> bool:
	var frames := _sprite.sprite_frames
	var side_flip_for_left := not side_faces_left
	var candidates: Array
	match direction:
		"left":
			candidates = [[base + "_left", false], [base + "_side", side_flip_for_left], [base + "_right", true], [base + "_down", false], [base, false]]
		"right":
			candidates = [[base + "_right", false], [base + "_side", not side_flip_for_left], [base + "_left", true], [base + "_down", false], [base, false]]
		"up":
			candidates = [[base + "_up", false], [base, false], [base + "_down", false]]
		_:
			candidates = [[base + "_down", false], [base, false]]
	for c in candidates:
		if frames.has_animation(c[0]):
			if _sprite.animation != c[0] or not _sprite.is_playing():
				_sprite.play(c[0])
			_sprite.flip_h = c[1]
			return true
	return false


# --- placeholder puppet ------------------------------------------------------------------

func _draw() -> void:
	if has_visuals():
		super()
		return
	var h := height
	var w := h * 0.3
	var step := sin(_t * 11.0) if is_walking else 0.0
	var bob := absf(step) * h * 0.02
	var outline := body_color.darkened(0.55)
	var side := direction in ["left", "right"]
	var gesture := _custom_anim != ""
	var crouch := h * 0.08 if gesture and _custom_anim.begins_with("pick") else 0.0
	# shadow
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.28))
	draw_circle(Vector2.ZERO, w * 0.75, Color(0, 0, 0, 0.25))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# legs
	var leg_h := h * 0.3 - crouch
	var hip_y := -leg_h - bob
	var lx := w * 0.2
	var swing := step * w * 0.35 if side else 0.0
	var leg_col := body_color.darkened(0.35)
	draw_line(Vector2(-lx, hip_y), Vector2(-lx + swing, 0), outline, w * 0.26)
	draw_line(Vector2(lx, hip_y), Vector2(lx - swing, 0), outline, w * 0.26)
	draw_line(Vector2(-lx, hip_y), Vector2(-lx + swing, -1), leg_col, w * 0.18)
	draw_line(Vector2(lx, hip_y), Vector2(lx - swing, -1), leg_col, w * 0.18)
	# body
	var top := hip_y - h * 0.4
	var body := PackedVector2Array([
		Vector2(-w * 0.42, hip_y), Vector2(-w * 0.5, top + w * 0.25), Vector2(-w * 0.3, top),
		Vector2(w * 0.3, top), Vector2(w * 0.5, top + w * 0.25), Vector2(w * 0.42, hip_y)])
	draw_colored_polygon(body, body_color)
	draw_polyline(body + PackedVector2Array([body[0]]), outline, 2.0)
	# arms
	var shoulder_y := top + w * 0.3
	var arm_swing := -step * w * 0.4 if side else 0.0
	var hand_l := Vector2(-w * 0.62 + arm_swing, hip_y - h * 0.02)
	var hand_r := Vector2(w * 0.62 - arm_swing, hip_y - h * 0.02)
	if gesture and not _custom_anim.begins_with("pick"):
		hand_r = Vector2(w * 0.8, top - h * 0.12 + sin(_t * 9.0) * 4.0)
	if crouch > 0.0:
		hand_l = Vector2(-w * 0.5, -h * 0.06)
		hand_r = Vector2(w * 0.5, -h * 0.06)
	draw_line(Vector2(-w * 0.45, shoulder_y), hand_l, outline, w * 0.2)
	draw_line(Vector2(w * 0.45, shoulder_y), hand_r, outline, w * 0.2)
	draw_line(Vector2(-w * 0.45, shoulder_y), hand_l, body_color.lightened(0.1), w * 0.12)
	draw_line(Vector2(w * 0.45, shoulder_y), hand_r, body_color.lightened(0.1), w * 0.12)
	draw_circle(hand_l, w * 0.09, skin_color)
	draw_circle(hand_r, w * 0.09, skin_color)
	# head
	var r := h * 0.13
	var head := Vector2(0, top - r * 0.85)
	draw_circle(head, r + 2.0, outline)
	draw_circle(head, r, skin_color)
	# hair
	var hair := PackedVector2Array()
	var from_a := PI if direction != "up" else PI * 0.85
	var to_a := TAU if direction != "up" else TAU + PI * 0.15
	for i in 13:
		var a := lerpf(from_a, to_a, i / 12.0)
		hair.append(head + Vector2(cos(a), sin(a)) * (r + 1.0))
	if direction == "up":
		hair.append(head + Vector2(r * 0.7, r * 0.3))
		hair.append(head + Vector2(-r * 0.7, r * 0.3))
	else:
		hair.append(head + Vector2(r * 0.9, -r * 0.2))
		hair.append(head + Vector2(-r * 0.9, -r * 0.2))
	draw_colored_polygon(hair, hair_color)
	# face
	var eye := Color(0.1, 0.1, 0.15)
	match direction:
		"down":
			draw_circle(head + Vector2(-r * 0.35, r * 0.05), r * 0.12, eye)
			draw_circle(head + Vector2(r * 0.35, r * 0.05), r * 0.12, eye)
		"left":
			draw_circle(head + Vector2(-r * 0.5, r * 0.05), r * 0.12, eye)
		"right":
			draw_circle(head + Vector2(r * 0.5, r * 0.05), r * 0.12, eye)
	if direction != "up":
		var mx := 0.0
		if direction == "left":
			mx = -r * 0.45
		elif direction == "right":
			mx = r * 0.45
		var open := is_talking and fmod(_t * 8.0, 2.0) < 1.0
		var mouth := head + Vector2(mx, r * 0.5)
		if open:
			draw_set_transform(mouth, 0.0, Vector2(1.0, 0.7))
			draw_circle(Vector2.ZERO, r * 0.2, Color(0.45, 0.1, 0.1))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			draw_line(mouth - Vector2(r * 0.18, 0), mouth + Vector2(r * 0.18, 0), Color(0.45, 0.15, 0.1), 2.0)
	if Engine.is_editor_hint():
		super()
