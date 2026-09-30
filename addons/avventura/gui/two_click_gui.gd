class_name TwoClickGui
extends AdvGui
## Modern two-click interface (the default).
##   Left click:  walk, or do the main action of a hotspot (talk, pick up, use, exit...)
##   Right click: look at it
##   Inventory:   slides up from the bottom edge. Left click an item to hold it, then
##                click on something to use it; right click an item to look at it.
##   Double click on an exit: leave immediately.

## Keep the inventory bar always on screen.
@export var always_show_inventory := false
@export var slot_size := 76.0

var inv_panel: PanelContainer
var inv_box: HBoxContainer
var inv_handle: Button
var _slide := 0.0
var _pinned_until := 0


func _build() -> void:
	inv_panel = PanelContainer.new()
	inv_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, slot_size + 6)
	inv_box = HBoxContainer.new()
	inv_box.add_theme_constant_override("separation", 8)
	scroll.add_child(inv_box)
	inv_panel.add_child(scroll)
	root.add_child(inv_panel)
	inv_handle = Button.new()
	inv_handle.text = "▲ " + tr("Inventory")
	inv_handle.add_theme_font_size_override("font_size", 16)
	inv_handle.pressed.connect(func(): always_show_inventory = not always_show_inventory)
	root.add_child(inv_handle)
	Adv.inventory_changed.connect(func(_c):
		refresh_inventory()
		_pinned_until = Time.get_ticks_msec() + 1800)
	Adv.item_selected.connect(func(_i): refresh_inventory())
	Adv.room_entered.connect(func(_r): refresh_inventory())
	Adv.player_changed.connect(func(_c): refresh_inventory())
	refresh_inventory()


func refresh_inventory() -> void:
	for c in inv_box.get_children():
		c.queue_free()
	var items := Adv.player_items()
	if items.is_empty():
		var l := Label.new()
		l.text = tr("Inventory is empty")
		l.modulate = Color(1, 1, 1, 0.6)
		l.custom_minimum_size = Vector2(300, slot_size)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		inv_box.add_child(l)
	for item in items:
		var s := AdvItemSlot.new(slot_size)
		s.item = item
		s.selected = item == Adv.selected_item
		s.clicked.connect(click_item)
		s.hovered.connect(func(i, inside): hovered_item = i if inside else "")
		inv_box.add_child(s)


func _process(delta: float) -> void:
	super(delta)
	var vs := get_viewport().get_visible_rect().size
	var mp := get_viewport().get_mouse_position()
	var h := slot_size + 6 + 32
	var count := maxi(1, Adv.player_items().size())
	var w := clampf(count * (slot_size + 8) + 40, 380, vs.x - 160)
	var usable := Adv.room != null and not _in_menu and Adv.mode != Adv.Mode.CHOICE and not Adv.in_cutscene()
	var near_bottom := mp.y > vs.y - (h + 20) * (0.35 + _slide * 0.65) and absf(mp.x - vs.x / 2.0) < w / 2.0 + 60
	var want := usable and (always_show_inventory or Adv.selected_item != "" or near_bottom or Time.get_ticks_msec() < _pinned_until)
	_slide = move_toward(_slide, 1.0 if want else 0.0, delta * 7.0)
	inv_panel.visible = _slide > 0.01
	inv_panel.size = Vector2(w, h)
	inv_panel.position = Vector2((vs.x - w) / 2.0, vs.y - (h + 12) * _slide)
	inv_handle.visible = usable and _slide < 0.5
	inv_handle.position = Vector2((vs.x - inv_handle.size.x) / 2.0, vs.y - inv_handle.size.y)
	inv_handle.modulate.a = 0.55 if not inv_handle.is_hovered() else 1.0
