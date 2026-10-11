@tool
@icon("res://addons/avventura/icons/walk_behind.svg")
class_name AdvWalkBehind
extends Polygon2D
## A piece of the room background drawn over the characters standing behind it, like the
## walk-behind areas of AGS: a column, a railing, a seat back.
##
## The piece is the polygon (draw it with the polygon tools, over the background) or the
## opaque pixels of [member mask] (an image as big as the background, transparent
## elsewhere: for thin or ragged shapes like ropes), or the mask clipped by the polygon.
## Characters whose feet are above [member baseline] walk behind it, the others in front.
## Put it straight under the room (the room is y-sorted). `show` / `hide NAME` switch it on and off.

## Room y of the baseline. 0 = the lowest point of the polygon (or of the mask).
@export var baseline := 0.0:
	set(v):
		baseline = v
		queue_redraw()
## Optional mask, the same size as the background: its opaque pixels are the walk-behind.
@export var mask: Texture2D:
	set(v):
		mask = v
		queue_redraw()
## The Sprite2D to cut from. Empty = the room's "Background" node.
@export var source: NodePath

const EDIT_COLOR := Color(0.95, 0.6, 0.2, 0.35)

var _built := false


func _ready() -> void:
	if Engine.is_editor_hint():
		if color == Color(1, 1, 1, 1):
			color = EDIT_COLOR
		return
	build()


## The background sprite the piece is cut from.
func get_source() -> Sprite2D:
	if not source.is_empty():
		return get_node_or_null(source) as Sprite2D
	var p := get_parent()
	while p:
		var bg := p.get_node_or_null("Background") as Sprite2D
		if bg:
			return bg
		p = p.get_parent()
	return null


## The baseline in this node's local coordinates (before [method build] moves it).
func _local_baseline(points: PackedVector2Array) -> float:
	if baseline != 0.0:
		return (baseline - position.y) / scale.y
	var low := -INF
	for p in points:
		low = maxf(low, p.y)
	return low


## Background texture pixel -> this node's local coordinates, and back.
func _px_to_local(bg: Sprite2D) -> Transform2D:
	var origin := bg.offset
	if bg.centered and bg.texture:
		origin -= bg.texture.get_size() / 2.0
	return global_transform.affine_inverse() * bg.global_transform * Transform2D(0.0, origin)


## Cuts the piece out of the background and moves the node to its baseline (once).
func build() -> void:
	if _built:
		return
	_built = true
	var bg := get_source()
	if bg == null or bg.texture == null:
		push_warning("AdvWalkBehind %s: no background to cut from" % name)
		visible = false
		return
	var to_local := _px_to_local(bg)
	var tex: Texture2D = bg.texture
	var pts := polygon
	if mask:
		var img := tex.get_image()
		var m := mask.get_image()
		if img == null or m == null:
			push_warning("AdvWalkBehind %s: can't read the background or the mask" % name)
			visible = false
			return
		for i in [img, m]:
			if i.is_compressed():
				i.decompress()
			i.convert(Image.FORMAT_RGBA8)
		if m.get_size() != img.get_size():
			m.resize(img.get_width(), img.get_height(), Image.INTERPOLATE_NEAREST)
		var cut := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		cut.blit_rect_mask(img, m, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
		tex = ImageTexture.create_from_image(cut)
		if pts.size() < 3:
			var r := Rect2(m.get_used_rect())
			pts = PackedVector2Array([to_local * r.position, to_local * Vector2(r.end.x, r.position.y),
				to_local * r.end, to_local * Vector2(r.position.x, r.end.y)])
	if pts.size() < 3:
		visible = false
		return
	var to_px := to_local.affine_inverse()
	var uvs := PackedVector2Array()
	for p in pts:
		uvs.append(to_px * p)
	# The room is y-sorted on the node's position: move the node to the baseline and the
	# polygon back up by the same amount, so the picture stays where it was.
	var shift := _local_baseline(pts)
	var moved := PackedVector2Array()
	for p in pts:
		moved.append(p - Vector2(0, shift))
	position += transform.basis_xform(Vector2(0, shift))
	polygon = moved
	uv = uvs
	texture = tex
	texture_offset = Vector2.ZERO
	texture_scale = Vector2.ONE
	texture_rotation = 0.0
	texture_filter = bg.texture_filter
	color = Color.WHITE
	z_index = 0


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var bg := get_source()
	if mask and bg:
		draw_set_transform_matrix(_px_to_local(bg))
		draw_texture(mask, Vector2.ZERO, EDIT_COLOR)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	# the baseline, dashed, across the piece
	var pts := polygon
	if pts.size() < 3 and mask and bg:
		var r := Rect2(mask.get_image().get_used_rect())
		var xf := _px_to_local(bg)
		pts = PackedVector2Array([xf * r.position, xf * r.end])
	if pts.is_empty():
		return
	var x0 := INF
	var x1 := -INF
	for p in pts:
		x0 = minf(x0, p.x)
		x1 = maxf(x1, p.x)
	var y := _local_baseline(pts)
	draw_dashed_line(Vector2(x0 - 10, y), Vector2(x1 + 10, y), Color(1, 0.55, 0.1), 2.0, 8.0)
