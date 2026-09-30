class_name AdvItemSlot
extends Control
## One inventory slot: draws the item icon (or a colored placeholder with its initial).

signal clicked(item: String, button: int)
signal hovered(item: String, inside: bool)

var item := "":
	set(v):
		item = v
		tooltip_text = ""
		queue_redraw()
var selected := false:
	set(v):
		selected = v
		queue_redraw()
var slot_color := Color(0, 0, 0, 0.35)
var hover_color := Color(1, 0.85, 0.4, 0.35)
var _hover := false


func _init(size_px: float = 72.0) -> void:
	custom_minimum_size = Vector2(size_px, size_px)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func():
		_hover = true
		queue_redraw()
		hovered.emit(item, true))
	mouse_exited.connect(func():
		_hover = false
		queue_redraw()
		hovered.emit(item, false))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and item != "":
		clicked.emit(item, event.button_index)
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_style_box(_box(hover_color if _hover and item != "" else slot_color), r)
	if selected:
		draw_rect(r.grow(-2), Color(1, 0.85, 0.3), false, 3.0)
	if item != "":
		draw_icon(self, item, r.grow(-8))


## Draws an item icon (or its placeholder) into [param rect] of [param canvas].
static func draw_icon(canvas: CanvasItem, item_id: String, rect: Rect2) -> void:
	var tex: Texture2D = Adv.item_icon(item_id)
	if tex:
		var ts := tex.get_size()
		var k := minf(rect.size.x / ts.x, rect.size.y / ts.y)
		var s := ts * k
		canvas.draw_texture_rect(tex, Rect2(rect.position + (rect.size - s) / 2.0, s), false)
		return
	var c: Color = Adv.item_color(item_id)
	var inner := rect.grow(-rect.size.x * 0.1)
	canvas.draw_style_box(_box(c, 10), inner)
	var font := ThemeDB.fallback_font
	var fs := int(inner.size.y * 0.55)
	var letter: String = Adv.display_name(item_id).left(1).to_upper()
	var ls := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	canvas.draw_string(font, inner.position + Vector2((inner.size.x - ls.x) / 2.0, inner.size.y / 2.0 + fs * 0.35),
		letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))


static func _box(color: Color, radius: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	return sb
