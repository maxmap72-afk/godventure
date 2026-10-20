@icon("res://addons/avventura/icons/walk_behind.svg")
class_name AdvDarkness
extends ColorRect
## Darkness over a room (a dungeon, a cave): only a circle of light around a character (the one
## carrying the lamp) and around fixed lights is visible; the places already lit stay visible,
## dimmed, so the map draws itself as it is explored (fog of war). What has been seen is kept
## in the saved game.
##
## Put it straight under the room; it covers the whole room. `lit_by` = the character holding
## the light ("" = the player, "-" = nobody: total darkness, even over the explored parts). Fixed lights: child Marker2D
## nodes, their radius in the metadata "radius" (default [member light_radius]).

## Character carrying the light: "" = the player, "-" = nobody.
@export var lit_by := ""
## Radius of the carried light, in pixels at scale 1.
@export var light_radius := 120.0
## How dark the unexplored parts are (1 = black).
@export_range(0.0, 1.0) var darkness := 0.97
## How dark the explored parts stay.
@export_range(0.0, 1.0) var explored_darkness := 0.55
## Size in pixels of a cell of the explored-areas grid.
@export var cell := 10

const SHADER := """
shader_type canvas_item;
uniform sampler2D explored : filter_linear;
uniform vec2 room_size;
uniform vec3 lights[8];
uniform int light_count;
uniform float darkness;
uniform float explored_darkness;
varying vec2 world;
void vertex() { world = VERTEX; }
void fragment() {
	float lit = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= light_count) { break; }
		float d = distance(world, lights[i].xy);
		lit = max(lit, 1.0 - smoothstep(lights[i].z * 0.45, lights[i].z, d));
	}
	float ex = texture(explored, world / room_size).r;
	float a = darkness * min(1.0 - lit, mix(1.0, explored_darkness / darkness, ex));
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
"""

var _img: Image
var _tex: ImageTexture
var _dirty := false


func _ready() -> void:
	var room := get_parent() as AdvRoom
	var sz: Vector2 = room.get_size() if room else size
	position = Vector2.ZERO
	size = sz
	color = Color.WHITE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if z_index == 0:
		z_index = 60
	var w := int(ceil(sz.x / cell))
	var h := int(ceil(sz.y / cell))
	_img = Image.create(w, h, false, Image.FORMAT_L8)
	var saved := _saved()
	if saved.length() == w * h * 2:
		_img.set_data(w, h, false, Image.FORMAT_L8, saved.hex_decode())
	_tex = ImageTexture.create_from_image(_img)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = SHADER
	mat.set_shader_parameter("explored", _tex)
	mat.set_shader_parameter("room_size", sz)
	material = mat


func _key() -> String:
	var room := get_parent() as AdvRoom
	return "darkness:%s/%s" % [room.get_room_id() if room else "", name]


func _adv() -> Node:
	return get_node_or_null("/root/Adv")


func _saved() -> String:
	var adv := _adv()
	return str(adv.state.custom.get(_key(), "")) if adv and adv.state else ""


## Forgets what has been explored.
func reset() -> void:
	_img.fill(Color.BLACK)
	_dirty = true


func _process(_delta: float) -> void:
	var adv := _adv()
	var lights := []
	if lit_by != "-" and adv:
		var c: Node2D = adv.player if lit_by == "" else adv.get_character(lit_by)
		if c and c.is_inside_tree() and c.get_parent() and c.visible:
			var r := light_radius * absf(c.scale.y)
			var p: Vector2 = c.position + Vector2(0, -c.get("height") * 0.3 * absf(c.scale.y))
			lights.append(Vector3(p.x, p.y, r))
			_reveal(p, r * 0.75)
	for m in get_children():
		if m is Node2D and m.visible:
			var r: float = m.get_meta("radius", light_radius)
			lights.append(Vector3(m.position.x, m.position.y, r))
	var arr := PackedVector3Array()
	for l in lights.slice(0, 8):
		arr.append(l)
	while arr.size() < 8:
		arr.append(Vector3.ZERO)
	var mat := material as ShaderMaterial
	mat.set_shader_parameter("lights", arr)
	mat.set_shader_parameter("light_count", mini(lights.size(), 8))
	mat.set_shader_parameter("darkness", darkness)
	mat.set_shader_parameter("explored_darkness", darkness if lit_by == "-" else explored_darkness)
	if _dirty:
		_dirty = false
		_tex.update(_img)
		if adv and adv.state:
			adv.state.custom[_key()] = _img.get_data().hex_encode()


func _reveal(p: Vector2, r: float) -> void:
	var c0 := Vector2i(int((p.x - r) / cell), int((p.y - r) / cell))
	var c1 := Vector2i(int((p.x + r) / cell), int((p.y + r) / cell))
	for y in range(maxi(c0.y, 0), mini(c1.y + 1, _img.get_height())):
		for x in range(maxi(c0.x, 0), mini(c1.x + 1, _img.get_width())):
			if _img.get_pixel(x, y).r < 1.0 and Vector2((x + 0.5) * cell, (y + 0.5) * cell).distance_to(p) <= r:
				_img.set_pixel(x, y, Color.WHITE)
				_dirty = true
