class_name ScummGui
extends AdvGui
## Classic SCUMM interface (Monkey Island 2 style): nine verbs, a sentence line and the
## inventory in a panel at the bottom of the screen.
##   Left click on a verb, then on something: "Open door". Use/Give take two objects:
##   "Use key with door". Right click on a hotspot does its default verb, highlighted
##   in the panel while the mouse is over it.
## Rooms should be designed so the bottom [member panel_height] pixels don't matter
## (the camera can scroll above the panel), like the original games.

@export var panel_height := 190.0
## Verbs in the 3x3 grid, column by column like MI2 (custom verbs are fine too).
@export var verbs: Array[String] = ["give", "pick", "use", "open", "look", "push", "close", "talk", "pull"]
@export var verb_color := Color(0.35, 0.8, 0.45)
@export var verb_hot_color := Color(0.75, 1.0, 0.7)
@export var panel_bg := Color(0.03, 0.03, 0.06, 1.0)

const VERB_LABELS := {"walk": "Walk to", "give": "Give", "pick": "Pick up", "use": "Use", "open": "Open",
	"look": "Look at", "push": "Push", "close": "Close", "talk": "Talk to", "pull": "Pull"}

var verb := "walk"
## First object of "Use X with ..." / "Give X to ...".
var first_item := ""
var panel: PanelContainer
var sentence: Label
var verb_buttons: Dictionary = {}
var inv_grid: GridContainer
var inv_offset := 0
var _slots: Array = []


func _build() -> void:
	Adv.gui_bottom_margin = panel_height
	panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = panel_bg
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -panel_height
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var vb := VBoxContainer.new()
	sentence = Label.new()
	sentence.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sentence.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	sentence.add_theme_font_size_override("font_size", 22)
	vb.add_child(sentence)
	var hb := HBoxContainer.new()
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 16)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_stretch_ratio = 1.1
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 2)
	# The grid fills row by row: reorder so verbs read column by column.
	var rows := ceili(verbs.size() / 3.0)
	for r in rows:
		for c in 3:
			var i := c * rows + r
			if i >= verbs.size():
				continue
			var v: String = verbs[i]
			var b := Button.new()
			b.text = tr(VERB_LABELS.get(v, v.capitalize()))
			b.flat = true
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_font_size_override("font_size", 24)
			b.add_theme_color_override("font_color", verb_color)
			b.add_theme_color_override("font_hover_color", verb_hot_color)
			b.pressed.connect(_on_verb.bind(v))
			grid.add_child(b)
			verb_buttons[v] = b
	hb.add_child(grid)
	var arrows := VBoxContainer.new()
	arrows.alignment = BoxContainer.ALIGNMENT_CENTER
	for d in [-1, 1]:
		var a := Button.new()
		a.text = "▲" if d < 0 else "▼"
		a.custom_minimum_size = Vector2(44, 52)
		a.pressed.connect(func():
			inv_offset = clampi(inv_offset + d * 4, 0, maxi(0, ((Adv.player_items().size() - 1) / 4) * 4 - 4))
			refresh_inventory())
		arrows.add_child(a)
	hb.add_child(arrows)
	inv_grid = GridContainer.new()
	inv_grid.columns = 4
	inv_grid.add_theme_constant_override("h_separation", 6)
	inv_grid.add_theme_constant_override("v_separation", 6)
	for i in 8:
		var s := AdvItemSlot.new(66.0)
		s.clicked.connect(click_item)
		s.hovered.connect(func(it, inside): hovered_item = it if inside else "")
		inv_grid.add_child(s)
		_slots.append(s)
	hb.add_child(inv_grid)
	vb.add_child(hb)
	panel.add_child(vb)
	root.add_child(panel)
	Adv.inventory_changed.connect(func(_c): refresh_inventory())
	Adv.room_entered.connect(func(_r): refresh_inventory())
	Adv.player_changed.connect(func(_c): refresh_inventory())
	refresh_inventory()


func refresh_inventory() -> void:
	var items := Adv.player_items()
	for i in _slots.size():
		var k := inv_offset + i
		_slots[i].item = items[k] if k < items.size() else ""
		_slots[i].selected = _slots[i].item != "" and _slots[i].item == first_item


func _on_verb(v: String) -> void:
	verb = v
	first_item = ""
	refresh_inventory()


func _reset_verb() -> void:
	verb = "walk"
	first_item = ""
	refresh_inventory()


func _process(delta: float) -> void:
	super(delta)
	hover_label.visible = false
	panel.visible = Adv.room != null and not Adv.in_cutscene() and not title_mode
	sentence.text = _sentence()
	var hot := hovered_hotspot.get_default_verb() if hovered_hotspot else ""
	for v in verb_buttons:
		var b: Button = verb_buttons[v]
		var active: bool = v == verb or v == hot
		b.add_theme_color_override("font_color", verb_hot_color if active else verb_color)


func _sentence() -> String:
	var target := ""
	if hovered_hotspot:
		target = tr(hovered_hotspot.get_display_name())
	elif hovered_item != "":
		target = Adv.display_name(hovered_item)
	var v := tr(VERB_LABELS.get(verb, verb.capitalize()))
	if first_item != "":
		var prep := tr("to") if verb == "give" else tr("with")
		return "%s %s %s %s" % [v, Adv.display_name(first_item), prep, target]
	return ("%s %s" % [v, target]).strip_edges()


func click_world(world_pos: Vector2, button: int, double: bool = false) -> void:
	if not Adv.accepts_input():
		return
	var hs := Adv.hotspot_at(world_pos)
	if button == MOUSE_BUTTON_RIGHT:
		if hs:
			Adv.perform(hs.get_default_verb(), hs.get_id())
		_reset_verb()
		return
	if button != MOUSE_BUTTON_LEFT:
		return
	if hs == null:
		if first_item == "" and Adv.room:
			Adv.walk_player(Adv.room.to_local(world_pos))
		_reset_verb()
		return
	if first_item != "":
		Adv.perform(verb, hs.get_id(), first_item)
	elif verb == "walk":
		Adv.perform("walk", hs.get_id(), "", double and hs.is_exit())
	else:
		Adv.perform(verb, hs.get_id())
	_reset_verb()


func click_item(item: String, button: int) -> void:
	if not Adv.accepts_input():
		return
	if button == MOUSE_BUTTON_RIGHT:
		Adv.perform("look", item)
		_reset_verb()
		return
	if button != MOUSE_BUTTON_LEFT:
		return
	if first_item != "":
		if item != first_item:
			Adv.perform(verb, item, first_item)
		_reset_verb()
		return
	var alone := not Adv.registry.find_handler(Adv.state.room, verb, item, "", false).is_empty()
	if verb == "give" or (verb == "use" and (Adv.registry.item_has_targets("use", item) or not alone)):
		first_item = item
		refresh_inventory()
		return
	Adv.perform("look" if verb == "walk" else verb, item)
	_reset_verb()


func _on_cutscene_changed(active: bool) -> void:
	super(active)
	if active:
		_reset_verb()
