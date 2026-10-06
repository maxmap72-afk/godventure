class_name AgsGui
extends AdvGui
## Interface in the style of the AGS templates, built from game/gui/ags_gui.json (written by
## tools/ags when a project is imported, editable by hand):
##   - an icon bar that pops up when the mouse touches the top of the screen
##     (inventory, save, load, game menu, quit);
##   - an inventory window with a grid of items, "select" and "look" buttons, scroll arrows
##     and a close button.
## In the rooms the mouse works like the two-click interface: left click walks or does the
## main action, right click looks; an item held from the inventory is used on what you click.

const LAYOUT := "gui/ags_gui.json"

var layout: Dictionary = {}
var iconbar: Control
var inv_window: Control
var inv_area: Control
var _blocker: ColorRect
var _mode_buttons: Dictionary = {}
var _inv_mode := "select"
var _inv_offset := 0
var _cell := Vector2(110, 110)
var _cols := 1
var _rows := 1
var _bar_open := false
var _popup_y := 16.0


func _build() -> void:
	var path: String = Adv.game_dir + "/" + LAYOUT
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			layout = data
	if not layout.has("inventory"):
		layout = _default_layout()
	if layout.has("inventory"):
		_build_inventory(layout.inventory)
	if layout.has("iconbar"):
		_build_iconbar(layout.iconbar)
	Adv.inventory_changed.connect(func(_c): refresh_inventory())
	Adv.item_selected.connect(func(_i): refresh_inventory())
	Adv.room_entered.connect(func(_r): refresh_inventory())
	Adv.player_changed.connect(func(_c): refresh_inventory())
	Adv.cutscene_changed.connect(func(on): if on: close_inventory())


# --- building ------------------------------------------------------------------------------------

## Plain layout used when the game has no gui/ags_gui.json.
func _default_layout() -> Dictionary:
	var vs := get_viewport().get_visible_rect().size
	var bw := 180.0
	var bar_buttons := []
	var labels := [["inventory", tr("Inventory")], ["save", tr("Save")], ["load", tr("Load")], ["menu", tr("Menu")]]
	for i in labels.size():
		bar_buttons.append({"x": 20 + i * (bw + 12), "y": 12, "w": bw, "h": 48, "action": labels[i][0], "text": labels[i][1],
			"text_color": "#ffe9b0"})
	var w := minf(900.0, vs.x - 80)
	var h := minf(520.0, vs.y - 120)
	return {
		"iconbar": {"x": 0, "y": 0, "w": vs.x, "h": 72, "color": "#101018e0", "popup_y": 16, "buttons": bar_buttons},
		"inventory": {"x": (vs.x - w) / 2.0, "y": (vs.y - h) / 2.0, "w": w, "h": h, "color": "#101018f0",
			"items": {"x": 30, "y": 30, "w": w - 160, "h": h - 110, "cell": 110},
			"buttons": [
				{"x": w - 110, "y": 30, "w": 80, "h": 48, "action": "up", "text": "▲"},
				{"x": w - 110, "y": h - 160, "w": 80, "h": 48, "action": "down", "text": "▼"},
				{"x": 30, "y": h - 70, "w": 160, "h": 48, "action": "select", "text": tr("Use")},
				{"x": 210, "y": h - 70, "w": 160, "h": 48, "action": "look", "text": tr("Look at")},
				{"x": w - 230, "y": h - 70, "w": 200, "h": 48, "action": "close", "text": tr("Close"), "text_color": "#ff8080"}]}}


func _rect_of(d: Dictionary) -> Rect2:
	return Rect2(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("w", 0)), float(d.get("h", 0)))


func _panel(d: Dictionary) -> Control:
	var c := Control.new()
	var r := _rect_of(d)
	c.position = r.position
	c.size = r.size
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	if str(d.get("color", "")) != "":
		var bg := ColorRect.new()
		bg.color = Color.from_string(str(d.color), Color.BLACK)
		bg.size = r.size
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(bg)
	var tex := _tex(d.get("image", ""))
	if tex:
		var img := TextureRect.new()
		img.texture = tex
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(img)
	return c


func _tex(path: Variant) -> Texture2D:
	var p := str(path)
	if p == "" or not ResourceLoader.exists(p):
		return null
	return load(p)


func _button(d: Dictionary) -> TextureButton:
	var b := TextureButton.new()
	var r := _rect_of(d)
	b.position = r.position
	b.texture_normal = _tex(d.get("image", ""))
	b.texture_hover = _tex(d.get("over", ""))
	b.texture_pressed = _tex(d.get("pressed", ""))
	if b.texture_normal:
		b.size = b.texture_normal.get_size()
	else:
		b.size = r.size
	b.tooltip_text = ""
	b.focus_mode = Control.FOCUS_NONE
	var text := str(d.get("text", ""))
	if text != "":
		var l := _outlined_label(font_size, Color.from_string(str(d.get("text_color", "#ffffff")), Color.WHITE), 4)
		l.text = tr(text)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size = r.size
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)
	return b


func _build_iconbar(d: Dictionary) -> void:
	iconbar = _panel(d)
	iconbar.visible = false
	_popup_y = maxf(16.0, float(d.get("popup_y", 16)))
	for bd in d.get("buttons", []):
		var b := _button(bd)
		b.pressed.connect(_icon_action.bind(str(bd.get("action", ""))))
		iconbar.add_child(b)
	root.add_child(iconbar)


func _build_inventory(d: Dictionary) -> void:
	_blocker = ColorRect.new()
	_blocker.color = Color(0, 0, 0, 0.25)
	_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocker.visible = false
	_blocker.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close_inventory())
	root.add_child(_blocker)
	inv_window = _panel(d)
	inv_window.visible = false
	var area: Dictionary = d.get("items", {})
	inv_area = Control.new()
	var ar := _rect_of(area)
	inv_area.position = ar.position
	inv_area.size = ar.size
	inv_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inv_window.add_child(inv_area)
	var cell := float(area.get("cell", 110))
	_cols = maxi(1, int(ar.size.x / cell))
	_rows = maxi(1, int(ar.size.y / cell))
	_cell = Vector2(ar.size.x / _cols, ar.size.y / _rows)
	for bd in d.get("buttons", []):
		var b := _button(bd)
		var action := str(bd.get("action", ""))
		b.pressed.connect(_inv_action.bind(action))
		if action in ["select", "look"]:
			_mode_buttons[action] = b
		inv_window.add_child(b)
	root.add_child(inv_window)
	_update_mode_buttons()


# --- inventory window ----------------------------------------------------------------------------

func open_inventory() -> void:
	if inv_window == null:
		return
	_inv_mode = "select"
	_update_mode_buttons()
	inv_window.visible = true
	_blocker.visible = true
	_close_bar()
	refresh_inventory()


func close_inventory() -> void:
	if inv_window == null or not inv_window.visible:
		return
	inv_window.visible = false
	_blocker.visible = false
	hovered_item = ""


func is_inventory_open() -> bool:
	return inv_window != null and inv_window.visible


func refresh_inventory() -> void:
	if inv_area == null:
		return
	for c in inv_area.get_children():
		c.queue_free()
	var items := Adv.player_items()
	var per_page := _cols * _rows
	_inv_offset = clampi(_inv_offset, 0, maxi(0, (ceili(items.size() / float(_cols)) - _rows) * _cols))
	for i in range(_inv_offset, mini(items.size(), _inv_offset + per_page)):
		var k := i - _inv_offset
		var s := AdvItemSlot.new(minf(_cell.x, _cell.y) - 8)
		s.slot_color = Color(0, 0, 0, 0)
		s.item = items[i]
		s.selected = items[i] == Adv.selected_item
		s.position = Vector2((k % _cols) * _cell.x, (k / _cols) * _cell.y) + Vector2(4, 4)
		s.clicked.connect(_on_inv_item)
		s.hovered.connect(func(it, inside): hovered_item = it if inside else "")
		inv_area.add_child(s)


func _on_inv_item(item: String, button: int) -> void:
	if button == MOUSE_BUTTON_RIGHT or _inv_mode == "look":
		click_item(item, MOUSE_BUTTON_RIGHT)
	else:
		click_item(item, MOUSE_BUTTON_LEFT)


func _inv_action(action: String) -> void:
	match action:
		"select", "look":
			_inv_mode = action
			_update_mode_buttons()
		"up":
			_inv_offset = maxi(0, _inv_offset - _cols)
			refresh_inventory()
		"down":
			_inv_offset += _cols
			refresh_inventory()
		"close":
			close_inventory()


func _update_mode_buttons() -> void:
	for m in _mode_buttons:
		_mode_buttons[m].modulate = Color(1.25, 1.15, 0.7) if m == _inv_mode else Color(1, 1, 1, 0.75)


# --- icon bar ------------------------------------------------------------------------------------

func _icon_action(action: String) -> void:
	_close_bar()
	match action:
		"inventory":
			open_inventory()
		"save":
			show_save_menu()
		"load":
			show_load_menu()
		"settings":
			show_settings()
		"quit":
			show_pause()
		_:
			show_pause()


## Shows the icon bar as if the mouse touched the top of the screen (console: gui open_iconbar).
func open_iconbar() -> void:
	if iconbar == null:
		return
	get_viewport().warp_mouse(iconbar.position + Vector2(iconbar.size.x / 2.0, 4))
	_bar_open = true


func _close_bar() -> void:
	_bar_open = false
	if iconbar:
		iconbar.visible = false


func _process(delta: float) -> void:
	super(delta)
	if iconbar == null:
		return
	var mp := get_viewport().get_mouse_position()
	var usable := Adv.room != null and not _in_menu and not is_inventory_open() and Adv.mode != Adv.Mode.CHOICE \
		and not Adv.in_cutscene() and Adv.selected_item == ""
	if not usable:
		_close_bar()
		return
	if mp.y <= _popup_y:
		_bar_open = true
	elif _bar_open and not Rect2(iconbar.position, iconbar.size).has_point(mp):
		_bar_open = false
	iconbar.visible = _bar_open


func _on_escape() -> void:
	if is_inventory_open():
		close_inventory()
		return
	super()


func _on_key(event: InputEventKey) -> void:
	if event.keycode == KEY_I and not _in_menu and Adv.accepts_input() and inv_window:
		if is_inventory_open():
			close_inventory()
		else:
			open_inventory()
		get_viewport().set_input_as_handled()
		return
	super(event)
