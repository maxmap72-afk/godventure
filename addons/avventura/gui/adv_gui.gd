class_name AdvGui
extends CanvasLayer
## Base class of the player interfaces: speech, dialog choices, the name of what is under
## the mouse, menus (title, pause, save/load, settings), hotspot hints (hold Tab) and the
## debug console (the key left of 1, or F12). Clicks become engine actions in
## [method click_world]; subclasses choose the interaction style:
##   TwoClickGui - left click acts, right click looks (default)
##   ScummGui    - classic nine verbs panel
## To make your own interface extend one of them and set it in
## Project Settings > avventura/gui/scene.

@export var font_size := 24
@export var speech_font_size := 28
@export var speech_max_width := 560.0
@export var accent_color := Color(1.0, 0.82, 0.4)
@export var panel_color := Color(0.06, 0.06, 0.1, 0.85)
## Optional theme replacing the built-in look.
@export var gui_theme: Theme

var root: Control
var hover_label: Label
var speech_layer: Control
var choices_panel: PanelContainer
var choices_box: VBoxContainer
var menu_layer: Control
var console: PanelContainer
var console_log: RichTextLabel
var console_input: LineEdit
var toast: Label
var skip_hint: Label
var item_cursor: Control
var hints: Control

var hovered_hotspot: AdvHotspot
var hovered_item := ""
var title_mode := false

var _speech: Dictionary = {}
var _history: Array = []
var _history_i := 0
var _menu_center: CenterContainer
var _title_bg: Control
var _title_label: Label
var _toast_tween: Tween
var _in_menu := false
var _dim: ColorRect


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	var lang := str(ProjectSettings.get_setting("avventura/gui/language", ""))
	if lang != "":
		TranslationServer.set_locale(lang)
	root = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = gui_theme if gui_theme else make_theme()
	add_child(root)
	_build()  # interface-specific widgets first, so speech and menus are drawn above them
	_build_common()
	_build_overlays()
	Adv.speech_started.connect(_on_speech_started)
	Adv.speech_finished.connect(_on_speech_finished)
	Adv.choice_requested.connect(_on_choice_requested)
	Adv.choice_made.connect(func(_i): choices_panel.visible = false)
	Adv.cutscene_changed.connect(_on_cutscene_changed)
	Adv.game_ended.connect(_on_game_ended)
	Adv.notify.connect(show_toast)
	Adv.item_selected.connect(func(_i): item_cursor.queue_redraw())
	Adv.game_started.connect(func(): _close_all_menus())


## Subclasses add their widgets here.
func _build() -> void:
	pass


func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = font_size
	var panel := StyleBoxFlat.new()
	panel.bg_color = panel_color
	panel.set_corner_radius_all(12)
	panel.set_content_margin_all(16)
	panel.border_color = Color(1, 1, 1, 0.08)
	panel.set_border_width_all(1)
	t.set_stylebox("panel", "PanelContainer", panel)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(1, 1, 1, 0.06)
	btn.set_corner_radius_all(8)
	btn.content_margin_left = 16
	btn.content_margin_right = 16
	btn.content_margin_top = 8
	btn.content_margin_bottom = 8
	var hover := btn.duplicate()
	hover.bg_color = Color(accent_color, 0.22)
	var pressed := btn.duplicate()
	pressed.bg_color = Color(accent_color, 0.35)
	var disabled := btn.duplicate()
	disabled.bg_color = Color(1, 1, 1, 0.02)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.92, 0.92, 0.95))
	t.set_color("font_hover_color", "Button", accent_color)
	t.set_color("font_pressed_color", "Button", accent_color)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.3))
	t.set_color("font_color", "Label", Color(0.95, 0.95, 0.97))
	# Toggle buttons: being "on" is shown by the switch, not by a highlighted background.
	for type in ["CheckButton", "CheckBox"]:
		t.set_stylebox("normal", type, btn)
		t.set_stylebox("pressed", type, btn)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("hover_pressed", type, hover)
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		t.set_color("font_pressed_color", type, Color(0.92, 0.92, 0.95))
		t.set_color("font_hover_pressed_color", type, accent_color)
	return t


func _build_common() -> void:
	hints = _full_rect_control()
	hints.draw.connect(_draw_hints)
	speech_layer = _full_rect_control()
	hover_label = _outlined_label(font_size, accent_color)
	hover_label.visible = false
	root.add_child(hover_label)
	choices_panel = PanelContainer.new()
	choices_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	choices_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	choices_panel.offset_left = 24
	choices_panel.offset_right = -24
	choices_panel.offset_bottom = -16
	choices_panel.visible = false
	choices_box = VBoxContainer.new()
	choices_box.add_theme_constant_override("separation", 2)
	choices_panel.add_child(choices_box)
	root.add_child(choices_panel)


func _build_overlays() -> void:
	skip_hint = _outlined_label(18, Color(1, 1, 1, 0.7))
	skip_hint.text = tr("Esc: skip")
	skip_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	skip_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	skip_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	skip_hint.offset_right = -16
	skip_hint.offset_bottom = -10
	skip_hint.visible = false
	root.add_child(skip_hint)
	item_cursor = Control.new()
	item_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_cursor.size = Vector2(56, 56)
	item_cursor.draw.connect(func():
		if Adv.selected_item != "":
			AdvItemSlot.draw_icon(item_cursor, Adv.selected_item, Rect2(Vector2.ZERO, item_cursor.size)))
	root.add_child(item_cursor)
	toast = _outlined_label(22, Color.WHITE)
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 16
	toast.modulate.a = 0.0
	root.add_child(toast)
	# menus
	menu_layer = Control.new()
	menu_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_layer.visible = false
	root.add_child(menu_layer)
	_title_bg = _make_title_background()
	_title_bg.visible = false
	menu_layer.add_child(_title_bg)
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_layer.add_child(_dim)
	_title_label = _outlined_label(64, Color(1, 0.92, 0.75))
	_title_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_title_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title_label.offset_top = 70
	_title_label.visible = false
	menu_layer.add_child(_title_label)
	_menu_center = CenterContainer.new()
	_menu_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_layer.add_child(_menu_center)
	_build_console()


func _full_rect_control() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(c)
	return c


func _outlined_label(size_px: int, color: Color, outline: int = 6) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font_size = size_px
	ls.font_color = color
	ls.outline_size = outline
	ls.outline_color = Color(0, 0, 0, 0.9)
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# --- per-frame updates ------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var mp := get_viewport().get_mouse_position()
	item_cursor.visible = Adv.selected_item != "" and not _in_menu
	item_cursor.position = mp + Vector2(12, 12)
	for id in _speech:
		_place_speech(id, _speech[id])
	if Input.is_key_pressed(KEY_TAB) and Adv.accepts_input() and not _in_menu:
		hints.visible = true
		hints.queue_redraw()
	elif hints.visible:
		hints.visible = false
	_update_hover(mp)


func _update_hover(mp: Vector2) -> void:
	var over_gui := false
	var hc := get_viewport().gui_get_hovered_control()
	if hc and hc != root and hc.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		over_gui = true
	if _in_menu or Adv.room == null or not Adv.accepts_input():
		hovered_hotspot = null
	elif not over_gui:
		hovered_hotspot = Adv.hotspot_at(Adv.screen_to_world(mp))
		hovered_item = ""
	else:
		hovered_hotspot = null
	var text := hover_text()
	var show := text != "" and not _in_menu and Adv.accepts_input()
	hover_label.visible = show
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if hovered_hotspot and show else Input.CURSOR_ARROW)
	if show:
		hover_label.text = text
		_place_hover_label(mp)


## Text describing what the mouse is on. Subclasses change it (verbs, "Use X with Y"...).
func hover_text() -> String:
	var target := ""
	if hovered_hotspot:
		target = tr(hovered_hotspot.get_display_name())
	elif hovered_item != "":
		target = Adv.display_name(hovered_item)
	if Adv.selected_item != "" and target != "" and hovered_item != Adv.selected_item:
		var fmt := tr("Give %s to %s") if hovered_hotspot is AdvCharacter else tr("Use %s with %s")
		return fmt % [Adv.display_name(Adv.selected_item), target]
	return target


func _place_hover_label(mp: Vector2) -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := hover_label.get_minimum_size()
	var p := mp + Vector2(-s.x / 2.0, -s.y - 18)
	hover_label.position = Vector2(clampf(p.x, 8, vs.x - s.x - 8), clampf(p.y, 8, vs.y - s.y - 8))
	hover_label.size = s


# --- input -------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if _in_menu:
		return
	if (Adv.is_speaking() or Adv.is_playing_video()) and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		Adv.skip_line()
		get_viewport().set_input_as_handled()
		return
	if not Adv.accepts_input():
		return
	click_world(Adv.screen_to_world(event.position), event.button_index, event.double_click)
	get_viewport().set_input_as_handled()


func _on_key(event: InputEventKey) -> void:
	if console.visible:
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_QUOTELEFT or event.keycode == KEY_F12:
			toggle_console()
			get_viewport().set_input_as_handled()
		return
	match event.keycode:
		KEY_ESCAPE:
			_on_escape()
		KEY_PERIOD, KEY_SPACE:
			if Adv.is_speaking():
				Adv.skip_line()
		KEY_F5:
			if not _in_menu:
				quick_save()
		KEY_F9:
			if not _in_menu and FileAccess.file_exists(Adv.save_path("quicksave")):
				Adv.load_game("quicksave")
		KEY_F12:
			toggle_console()
		_:
			if event.physical_keycode == KEY_QUOTELEFT:
				toggle_console()
			elif Adv.mode == Adv.Mode.CHOICE and event.keycode >= KEY_1 and event.keycode <= KEY_9:
				Adv.choose(event.keycode - KEY_1)
			else:
				return
	get_viewport().set_input_as_handled()


func _on_escape() -> void:
	if _in_menu:
		if not title_mode:
			_close_all_menus()
		return
	if Adv.is_playing_video():
		Adv.skip_line()
	elif Adv.in_cutscene():
		Adv.skip_cutscene()
	elif Adv.selected_item != "":
		Adv.select_item("")
	elif Adv.room:
		show_pause()


## Handles a click at a world position. Default: two-click style.
func click_world(world_pos: Vector2, button: int, double: bool = false) -> void:
	if not Adv.accepts_input():
		return
	var hs := Adv.hotspot_at(world_pos)
	if button == MOUSE_BUTTON_RIGHT:
		if Adv.selected_item != "":
			Adv.select_item("")
		elif hs:
			Adv.perform("look", hs.get_id())
		return
	if button != MOUSE_BUTTON_LEFT:
		return
	if Adv.selected_item != "":
		var item := Adv.selected_item
		Adv.select_item("")
		if hs:
			Adv.perform("use", hs.get_id(), item)
		return
	if hs:
		Adv.perform(hs.get_default_verb(), hs.get_id(), "", double and hs.is_exit())
	elif Adv.room:
		Adv.walk_player(Adv.room.to_local(world_pos))


## Click on an inventory item (two-click rules: select, combine, look).
func click_item(item: String, button: int) -> void:
	if not Adv.accepts_input():
		return
	if button == MOUSE_BUTTON_RIGHT:
		Adv.select_item("")
		Adv.perform("look", item)
	elif button == MOUSE_BUTTON_LEFT:
		if Adv.selected_item == "":
			Adv.select_item(item)
		elif Adv.selected_item == item:
			Adv.select_item("")
		else:
			var first := Adv.selected_item
			Adv.select_item("")
			Adv.perform("use", item, first)


# --- speech ------------------------------------------------------------------------------------

func _on_speech_started(char_id: String, text: String) -> void:
	_on_speech_finished(char_id)
	var node: Control
	var anchor = Adv.speech_anchor(char_id)
	if char_id == "narrator" or anchor == null:
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := _outlined_label(speech_font_size, Adv.text_color(char_id) if char_id != "narrator" else Color(1, 0.97, 0.9), 4)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.text = text if char_id == "narrator" else "%s: %s" % [Adv.display_name(char_id), text]
		l.custom_minimum_size.x = minf(_text_width(text, speech_font_size) + 20, 900)
		panel.add_child(l)
		node = panel
	else:
		var l := _outlined_label(speech_font_size, Adv.text_color(char_id), 8)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.text = text
		var w := minf(_text_width(text, speech_font_size) + 24, speech_max_width)
		l.custom_minimum_size.x = w
		l.size = Vector2(w, 0)
		node = l
	speech_layer.add_child(node)
	_speech[char_id] = node
	_place_speech(char_id, node)


func _on_speech_finished(char_id: String) -> void:
	if _speech.has(char_id):
		_speech[char_id].queue_free()
		_speech.erase(char_id)


func _text_width(text: String, size_px: int) -> float:
	var font := ThemeDB.fallback_font
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x


func _place_speech(char_id: String, node: Control) -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := node.get_combined_minimum_size()
	node.size = s
	var anchor = Adv.speech_anchor(char_id) if char_id != "narrator" else null
	var p: Vector2
	if anchor == null:
		p = Vector2((vs.x - s.x) / 2.0, vs.y * 0.12)
	else:
		p = anchor - Vector2(s.x / 2.0, s.y)
	var bottom := vs.y - Adv.gui_bottom_margin
	node.position = Vector2(clampf(p.x, 10, vs.x - s.x - 10), clampf(p.y, 10, maxf(10, bottom - s.y - 10)))


# --- dialog choices -----------------------------------------------------------------------------

func _on_choice_requested(options: Array) -> void:
	for c in choices_box.get_children():
		c.queue_free()
	for i in options.size():
		var b := Button.new()
		b.text = "%d. %s" % [i + 1, options[i]]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.flat = true
		b.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
		b.add_theme_color_override("font_hover_color", accent_color)
		b.add_theme_font_size_override("font_size", font_size)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.pressed.connect(Adv.choose.bind(i))
		choices_box.add_child(b)
	choices_panel.visible = true


func _on_cutscene_changed(active: bool) -> void:
	skip_hint.visible = active


func _on_game_ended() -> void:
	await get_tree().create_timer(2.5).timeout
	if Adv.game_over:
		await Adv.fade(false, 0.6)
		show_title()


# --- hints (hold Tab) --------------------------------------------------------------------------

func _draw_hints() -> void:
	if Adv.room == null:
		return
	var font := ThemeDB.fallback_font
	for h in Adv.room.get_hotspots():
		if h == Adv.player or not h.interactive or not h.is_visible_in_tree():
			continue
		var b: Rect2 = h.get_global_bounds()
		var p := Adv.world_to_screen(b.get_center() if not h is AdvCharacter else h.get_speech_anchor())
		var text := tr(h.get_display_name())
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var r := Rect2(p - Vector2(w / 2.0 + 8, 14), Vector2(w + 16, 26))
		hints.draw_rect(r, Color(0, 0, 0, 0.6))
		hints.draw_string(font, r.position + Vector2(8, 19), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, accent_color)


# --- menus -------------------------------------------------------------------------------------

## entries: [[label, Callable or null], ...]
func open_menu(title: String, entries: Array) -> VBoxContainer:
	_in_menu = true
	menu_layer.visible = true
	_dim.color.a = 0.12 if title_mode else 0.55
	_menu_center.offset_top = 170.0 if title_mode else 0.0
	for c in _menu_center.get_children():
		c.queue_free()
	var panel := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	if title != "":
		var tl := Label.new()
		tl.text = title
		tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tl.add_theme_font_size_override("font_size", font_size + 6)
		tl.add_theme_color_override("font_color", accent_color)
		vb.add_child(tl)
	for e in entries:
		var b := Button.new()
		b.text = e[0]
		b.custom_minimum_size = Vector2(360, 0)
		if e[1] == null:
			b.disabled = true
		else:
			b.pressed.connect(e[1])
		vb.add_child(b)
	_menu_center.add_child(panel)
	var first := vb.get_children().filter(func(c): return c is Button and not c.disabled)
	if not first.is_empty():
		first[0].grab_focus.call_deferred()
	return vb


func _close_all_menus() -> void:
	_in_menu = false
	title_mode = false
	menu_layer.visible = false
	_title_bg.visible = false
	_title_label.visible = false
	get_tree().paused = false


func show_title() -> void:
	title_mode = true
	_title_bg.visible = true
	_title_label.visible = true
	_title_label.text = Adv.registry.game.title if Adv.registry.game.title != "" else str(ProjectSettings.get_setting("application/config/name"))
	get_tree().paused = false
	Adv.fade(false, 0.0)
	var saves := Adv.list_saves()
	var entries := [[tr("New game"), func():
		_close_all_menus()
		Adv.new_game()]]
	if not saves.is_empty():
		entries.append([tr("Continue"), func():
			_close_all_menus()
			Adv.load_game(saves[0].slot)])
		entries.append([tr("Load"), show_load_menu])
	entries.append([tr("Settings"), show_settings])
	if not OS.has_feature("web"):
		entries.append([tr("Quit"), func(): get_tree().quit()])
	open_menu("", entries)


func show_pause() -> void:
	title_mode = false
	_title_bg.visible = false
	_title_label.visible = false
	get_tree().paused = true
	var entries := [[tr("Resume"), _close_all_menus],
		[tr("Save"), show_save_menu if Adv.can_save() else null],
		[tr("Load"), show_load_menu],
		[tr("Settings"), show_settings],
		[tr("Main menu"), show_title]]
	if not OS.has_feature("web"):
		entries.append([tr("Quit"), func(): get_tree().quit()])
	open_menu(tr("Pause"), entries)


func _back() -> void:
	if title_mode:
		show_title()
	else:
		show_pause()


func show_save_menu() -> void:
	var existing := {}
	for s in Adv.list_saves():
		existing[s.slot] = s.meta
	var entries := []
	for i in range(1, 7):
		var slot := "slot%d" % i
		entries.append([_slot_label(i, existing.get(slot)), func():
			if Adv.save_game(slot):
				show_toast(tr("Game saved"))
			_close_all_menus()])
	entries.append([tr("Back"), _back])
	open_menu(tr("Save"), entries)


func show_load_menu() -> void:
	var entries := []
	for s in Adv.list_saves():
		var slot: String = s.slot
		var label := _slot_label(int(slot.trim_prefix("slot")) if slot.begins_with("slot") else 0, s.meta, slot)
		entries.append([label, func():
			_close_all_menus()
			Adv.load_game(slot)])
	if entries.is_empty():
		entries.append([tr("No saved games"), null])
	entries.append([tr("Back"), _back])
	open_menu(tr("Load"), entries)


func _slot_label(i: int, meta: Variant, slot: String = "") -> String:
	var name := tr("Slot %d") % i if i > 0 else slot.capitalize()
	if meta == null:
		return "%s  -  %s" % [name, tr("empty")]
	return "%s  -  %s  (%s)" % [name, meta.get("room_name", "?"), str(meta.get("time", "")).replace("T", " ").left(16)]


func show_settings() -> void:
	var vb := open_menu(tr("Settings"), [])
	vb.add_child(_slider(tr("Text speed"), "text_speed", 0.5, 2.0))
	vb.add_child(_check(tr("Auto-advance text"), "auto_advance"))
	vb.add_child(_slider(tr("Music volume"), "music_volume", 0.0, 1.0))
	vb.add_child(_slider(tr("Effects volume"), "sfx_volume", 0.0, 1.0))
	if not OS.has_feature("web") and not OS.has_feature("mobile"):
		vb.add_child(_check(tr("Fullscreen"), "fullscreen"))
	var back := Button.new()
	back.text = tr("Back")
	back.pressed.connect(_back)
	vb.add_child(back)


func _slider(label: String, key: String, lo: float, hi: float) -> Control:
	var hb := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 220
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.05
	s.value = float(Adv.prefs[key])
	s.custom_minimum_size.x = 200
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(func(v):
		Adv.prefs[key] = v
		Adv.save_prefs())
	hb.add_child(l)
	hb.add_child(s)
	return hb


func _check(label: String, key: String) -> Control:
	var c := CheckButton.new()
	c.text = label
	c.button_pressed = bool(Adv.prefs[key])
	c.toggled.connect(func(v):
		Adv.prefs[key] = v
		Adv.save_prefs())
	return c


func quick_save() -> void:
	if Adv.can_save() and Adv.save_game("quicksave"):
		show_toast(tr("Game saved"))
	else:
		show_toast(tr("You can't save now"))


func show_toast(text: String) -> void:
	toast.text = text
	if _toast_tween:
		_toast_tween.kill()
	toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.6)
	_toast_tween.tween_property(toast, "modulate:a", 0.0, 0.6)


func _make_title_background() -> Control:
	var gd: String = Adv.game_dir
	for ext in ["png", "jpg", "webp", "svg"]:
		var p := "%s/title.%s" % [gd, ext]
		if ResourceLoader.exists(p):
			var tr_ := TextureRect.new()
			tr_.texture = load(p)
			tr_.set_anchors_preset(Control.PRESET_FULL_RECT)
			tr_.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr_.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tr_.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return tr_
	var g := Gradient.new()
	g.set_color(0, Color(0.12, 0.13, 0.3))
	g.set_color(1, Color(0.55, 0.3, 0.45))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	var bg := TextureRect.new()
	bg.texture = gt
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bg


# --- debug console ------------------------------------------------------------------------------

func _build_console() -> void:
	console = PanelContainer.new()
	console.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	console.offset_bottom = 300
	console.visible = false
	var vb := VBoxContainer.new()
	console_log = RichTextLabel.new()
	console_log.scroll_following = true
	console_log.selection_enabled = true
	console_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	console_log.add_theme_font_size_override("normal_font_size", 16)
	console_log.add_theme_font_size_override("bold_font_size", 16)
	console_input = LineEdit.new()
	console_input.placeholder_text = tr("Command (help for the list)")
	console_input.add_theme_font_size_override("font_size", 16)
	console_input.text_submitted.connect(_on_console_submit)
	console_input.gui_input.connect(_on_console_key)
	vb.add_child(console_log)
	vb.add_child(console_input)
	console.add_child(vb)
	root.add_child(console)


func toggle_console() -> void:
	if not OS.is_debug_build() or not ProjectSettings.get_setting("avventura/debug/console", true):
		return
	console.visible = not console.visible
	if console.visible:
		console_input.grab_focus()
		if console_log.get_parsed_text() == "":
			console_log.append_text("[color=#ffd166]Avventura console[/color] - type [b]help[/b]. Same commands as tests and remote control.\n")
	else:
		console_input.release_focus()


func _on_console_submit(text: String) -> void:
	console_input.clear()
	if text.strip_edges() == "":
		return
	_history.append(text)
	_history_i = _history.size()
	console_log.append_text("[color=#8fd8ff]> %s[/color]\n" % text.replace("[", "[lb]"))
	var r: Dictionary = await Adv.controller.execute(text)
	var out: String = r.output.replace("[", "[lb]")
	if out != "":
		console_log.append_text(("[color=#ff8080]%s[/color]\n" if not r.ok else "%s\n") % out)


func _on_console_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed) or _history.is_empty():
		return
	if event.keycode == KEY_UP:
		_history_i = maxi(0, _history_i - 1)
	elif event.keycode == KEY_DOWN:
		_history_i = mini(_history.size(), _history_i + 1)
	else:
		return
	console_input.text = _history[_history_i] if _history_i < _history.size() else ""
	console_input.caret_column = console_input.text.length()
	console_input.accept_event()
