@tool
extends VBoxContainer
## The "Avventura" tab of the Godot editor: project tree, AdvScript editor (colors,
## completion with the names of rooms/items/characters/hotspots, error marks), wizards for
## new rooms, characters and items, and one-click check / tests / play.

const Highlighter := preload("res://addons/avventura/editor/adv_syntax_highlighter.gd")
const GUIS := {
	"two_click": "res://addons/avventura/gui/two_click_gui.tscn",
	"scumm": "res://addons/avventura/gui/scumm_gui.tscn",
}
const KEYWORDS := ["on", "dialog", "option", "function", "var", "item", "character", "title",
	"player", "start", "if", "elif", "else", "while", "set", "walk", "face", "anim", "wait",
	"inventory", "pickup", "show", "hide", "enable", "disable", "state", "goto", "place",
	"control", "end", "back", "stop", "call", "cutscene", "bg", "random", "cycle", "sequence",
	"once", "do", "sound", "music", "camera", "fade", "print", "end_game", "narrator", "and",
	"or", "not", "true", "false", "hidden", "silent", "nowait", "loop", "expect", "choose"]
const FUNCS := ["has", "visited", "visits", "room", "state", "shown", "enabled", "room_of",
	"used", "name", "is_player", "said", "ended", "random", "chance"]

const T := {
	"play": ["Play", "Gioca"],
	"play_room": ["Play from this room", "Gioca da questa stanza"],
	"lint": ["Check", "Controlla"],
	"tests": ["Run tests", "Esegui test"],
	"new_room": ["Room", "Stanza"],
	"new_char": ["Character", "Personaggio"],
	"new_item": ["Item", "Oggetto"],
	"save": ["Save", "Salva"],
	"game": ["Game", "Gioco"],
	"rooms": ["Rooms", "Stanze"],
	"characters": ["Characters", "Personaggi"],
	"items": ["Items", "Oggetti"],
	"dialogs": ["Dialogs", "Dialoghi"],
	"tests_h": ["Walkthrough tests", "Test (soluzioni)"],
	"docs": ["Guide", "Guida"],
	"scene": ["scene", "scena"],
	"script": ["script", "script"],
	"gui": ["Interface:", "Interfaccia:"],
	"two_click": ["Two-click (modern)", "Due click (moderna)"],
	"scumm": ["SCUMM verbs", "Verbi SCUMM"],
	"custom": ["Custom", "Personalizzata"],
	"id": ["Id (lowercase, no spaces)", "Id (minuscolo, senza spazi)"],
	"name": ["Name shown to the player", "Nome mostrato al giocatore"],
	"color": ["Text color", "Colore del testo"],
	"with_scene": ["Also create a scene for sprites", "Crea anche una scena per gli sprite"],
	"running": ["running...", "in esecuzione..."],
	"refresh": ["Refresh", "Aggiorna"],
	"no_room": ["Open a room script or select a room first.", "Apri lo script di una stanza o seleziona una stanza."],
	"syntax_ok": ["No syntax errors.", "Nessun errore di sintassi."],
	"welcome": ["Select a script on the left, or create a room. Ctrl+Space completes names, Ctrl+S saves.",
		"Seleziona uno script a sinistra, o crea una stanza. Ctrl+Spazio completa i nomi, Ctrl+S salva."],
	"unsaved": ["(unsaved)", "(non salvato)"],
}

var plugin: EditorPlugin
var registry := AdvRegistry.new()
var tree: Tree
var code: CodeEdit
var path_label: Label
var output: RichTextLabel
var gui_select: OptionButton
var current_path := ""
var _dirty := false
var _it := false
var _thread: Thread
var _room_names: Dictionary = {}


func _ready() -> void:
	var lang := str(EditorInterface.get_editor_settings().get_setting("interface/editor/editor_language"))
	_it = lang.begins_with("it")
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	refresh_tree()
	_log(t("welcome"))


func t(key: String) -> String:
	return T[key][1 if _it else 0]


func _game_dir() -> String:
	return str(ProjectSettings.get_setting("avventura/general/game_dir", "res://game")).trim_suffix("/")


func _icon(name: String) -> Texture2D:
	var th := EditorInterface.get_editor_theme()
	return th.get_icon(name, "EditorIcons") if th.has_icon(name, "EditorIcons") else null


# --- UI -------------------------------------------------------------------------------------

func _build() -> void:
	var bar := HBoxContainer.new()
	_button(bar, t("play"), "MainPlay", func(): EditorInterface.play_main_scene())
	_button(bar, t("play_room"), "PlayScene", _on_play_room)
	bar.add_child(VSeparator.new())
	_button(bar, t("lint"), "StatusSuccess", func(): _run_tool(["--adv-lint"], t("lint")))
	_button(bar, t("tests"), "DebugContinue", func(): _run_tool(["--adv-test"], t("tests")))
	bar.add_child(VSeparator.new())
	_button(bar, t("new_room"), "Add", _new_room)
	_button(bar, t("new_char"), "Add", _new_character)
	_button(bar, t("new_item"), "Add", _new_item)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var gl := Label.new()
	gl.text = t("gui")
	bar.add_child(gl)
	gui_select = OptionButton.new()
	gui_select.add_item(t("two_click"), 0)
	gui_select.add_item(t("scumm"), 1)
	gui_select.add_item(t("custom"), 2)
	gui_select.item_selected.connect(_on_gui_selected)
	bar.add_child(gui_select)
	_sync_gui_select()
	_button(bar, t("refresh"), "Reload", refresh_tree)
	_button(bar, t("docs"), "Help", func(): open_file("res://docs/GUIDA.md"))
	add_child(bar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree = Tree.new()
	tree.custom_minimum_size.x = 250 * EditorInterface.get_editor_scale()
	tree.hide_root = true
	tree.item_selected.connect(_on_tree_selected)
	tree.item_activated.connect(_on_tree_activated)
	split.add_child(tree)

	var right := VSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var editor_box := VBoxContainer.new()
	editor_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var file_bar := HBoxContainer.new()
	path_label = Label.new()
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_bar.add_child(path_label)
	_button(file_bar, t("save"), "Save", save_file)
	editor_box.add_child(file_bar)
	code = CodeEdit.new()
	code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code.gutters_draw_line_numbers = true
	code.indent_automatic = true
	code.indent_use_spaces = true
	code.indent_size = 4
	code.auto_brace_completion_enabled = true
	code.code_completion_enabled = true
	code.highlight_current_line = true
	code.draw_tabs = true
	code.minimap_draw = true
	code.caret_blink = true
	var font := EditorInterface.get_editor_theme().get_font("source", "EditorFonts")
	if font:
		code.add_theme_font_override("font", font)
	code.add_theme_font_size_override("font_size", int(15 * EditorInterface.get_editor_scale()))
	code.text_changed.connect(_on_text_changed)
	code.code_completion_requested.connect(_on_completion)
	code.gui_input.connect(_on_code_input)
	editor_box.add_child(code)
	right.add_child(editor_box)
	output = RichTextLabel.new()
	output.bbcode_enabled = true
	output.selection_enabled = true
	output.scroll_following = true
	output.custom_minimum_size.y = 150 * EditorInterface.get_editor_scale()
	output.meta_clicked.connect(_on_meta)
	right.add_child(output)
	split.add_child(right)
	add_child(split)


func _button(parent: Control, text: String, icon: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = _icon(icon)
	b.flat = true
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# --- project tree ---------------------------------------------------------------------------

func refresh_tree() -> void:
	registry.load_game(_game_dir())
	_room_names.clear()
	tree.clear()
	var root := tree.create_item()
	var gd := _game_dir()
	var game := _section(root, t("game"), "Node")
	for f in AdvRegistry.find_files(gd, ["adv"]):
		if registry.room_of_path(f) == "":
			_leaf(game, f.trim_prefix(gd + "/"), "TextFile", {"file": f})
	var rooms := _section(root, t("rooms"), "Node2D")
	var ids := registry.rooms.keys()
	ids.sort()
	for id in ids:
		var scene: String = registry.rooms[id]
		var r := _leaf(rooms, id, "Node2D", {"scene": scene, "room": id})
		_leaf(r, t("scene"), "PackedScene", {"scene": scene, "room": id})
		var script := scene.get_basename() + ".adv"
		if FileAccess.file_exists(script):
			_leaf(r, t("script"), "TextFile", {"file": script, "room": id})
		r.collapsed = true
	var chars := _section(root, t("characters"), "CharacterBody2D")
	for id in _sorted(registry.characters):
		var c: Dictionary = registry.characters[id]
		var label: String = id + ("  \"%s\"" % c.name if c.get("name", "") != "" else "")
		_leaf(chars, label, "CharacterBody2D", {"file": c.get("file", ""), "line": c.get("line", 0), "scene": c.get("scene", "")})
	var items := _section(root, t("items"), "Key")
	for id in _sorted(registry.items):
		var it: Dictionary = registry.items[id]
		_leaf(items, "%s  \"%s\"" % [id, it.name], "Key", {"file": it.file, "line": it.line})
	var dialogs := _section(root, t("dialogs"), "AnimationTrackList")
	for id in _sorted(registry.dialogs):
		var d: Dictionary = registry.dialogs[id]
		_leaf(dialogs, id, "AnimationTrackList", {"file": d.file, "line": d.line})
	var tests := _section(root, t("tests_h"), "DebugContinue")
	for f in AdvRegistry.find_files(gd, ["advtest"]):
		_leaf(tests, f.get_file(), "TextFile", {"file": f})
	_update_errors_from_registry()


func _sorted(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


func _section(parent: TreeItem, text: String, icon: String) -> TreeItem:
	var it := tree.create_item(parent)
	it.set_text(0, text)
	it.set_icon(0, _icon(icon))
	it.set_selectable(0, false)
	it.set_custom_color(0, Color(1, 0.82, 0.4))
	return it


func _leaf(parent: TreeItem, text: String, icon: String, meta: Dictionary) -> TreeItem:
	var it := tree.create_item(parent)
	it.set_text(0, text)
	it.set_icon(0, _icon(icon))
	it.set_metadata(0, meta)
	return it


func _on_tree_selected() -> void:
	var it := tree.get_selected()
	if it == null:
		return
	var meta = it.get_metadata(0)
	if meta is Dictionary and meta.get("file", "") != "":
		open_file(meta.file, int(meta.get("line", 0)))


func _on_tree_activated() -> void:
	var it := tree.get_selected()
	if it == null:
		return
	var meta = it.get_metadata(0)
	if meta is Dictionary and meta.get("scene", "") != "":
		EditorInterface.open_scene_from_path(meta.scene)
		EditorInterface.set_main_screen_editor("2D")


# --- code editor ------------------------------------------------------------------------------

func open_file(path: String, line: int = 0) -> void:
	if not FileAccess.file_exists(path):
		_log("[color=#ff8080]%s not found[/color]" % path)
		return
	if _dirty and current_path != "" and path != current_path:
		save_file()
	if path != current_path:
		code.text = FileAccess.get_file_as_string(path)
		code.clear_undo_history()
		current_path = path
		_dirty = false
		code.syntax_highlighter = Highlighter.new() if path.get_extension() in ["adv", "advtest"] else null
		_refresh_room_names()
	_update_title()
	if line > 0:
		code.set_caret_line(line - 1)
		code.set_caret_column(0)
		code.center_viewport_to_caret()
	code.grab_focus()
	_check_current()


func save_file() -> void:
	if current_path == "":
		return
	var f := FileAccess.open(current_path, FileAccess.WRITE)
	if f == null:
		_log("[color=#ff8080]Cannot write %s[/color]" % current_path)
		return
	f.store_string(code.text)
	f.close()
	_dirty = false
	_update_title()
	EditorInterface.get_resource_filesystem().update_file(current_path)
	refresh_tree()
	_check_current()


func _update_title() -> void:
	path_label.text = current_path + ("  " + t("unsaved") if _dirty else "")


func _on_text_changed() -> void:
	if not _dirty:
		_dirty = true
		_update_title()
	var line := code.get_line(code.get_caret_line())
	var col := code.get_caret_column()
	if col >= 2 and AdvExpr.is_ident_char(line[col - 1]) and AdvExpr.is_ident_char(line[col - 2]):
		code.request_code_completion()


func _on_code_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_S and (event.ctrl_pressed or event.meta_pressed):
		save_file()
		code.accept_event()


## Marks lines with syntax errors (instant, no need to save).
func _check_current() -> void:
	for i in code.get_line_count():
		code.set_line_background_color(i, Color(0, 0, 0, 0))
	if current_path.get_extension() != "adv":
		return
	var parsed := AdvParser.parse(code.text, current_path)
	for e in parsed.errors:
		if e.line > 0 and e.line <= code.get_line_count():
			code.set_line_background_color(e.line - 1, Color(0.9, 0.2, 0.2, 0.2))
	if parsed.errors.is_empty():
		_log("[color=#8eef97]%s[/color] %s" % [current_path.get_file(), t("syntax_ok")])
	else:
		var lines := []
		for e in parsed.errors:
			lines.append({"file": current_path, "line": e.line, "level": "error", "msg": e.msg})
		_show_issues(lines)


func _update_errors_from_registry() -> void:
	if not registry.issues.is_empty():
		_show_issues(registry.issues)


func _show_issues(list: Array) -> void:
	for i in list:
		var color := "#ff8080" if i.level == "error" else "#ffd166"
		_log("[url=%s]%s:%d[/url] [color=%s]%s[/color]: %s" % [
			JSON.stringify({"f": i.file, "l": i.line}), i.file.get_file(), i.line, color, i.level, _esc(i.msg)])


func _on_meta(meta: Variant) -> void:
	var d = JSON.parse_string(str(meta))
	if d is Dictionary and d.has("f"):
		open_file(str(d.f), int(d.get("l", 0)))


func _log(bbcode: String) -> void:
	output.append_text(bbcode + "\n")


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


# --- completion ---------------------------------------------------------------------------------

func _on_completion() -> void:
	var line := code.get_line(code.get_caret_line())
	var col := code.get_caret_column()
	var start := col
	while start > 0 and AdvExpr.is_ident_char(line[start - 1]):
		start -= 1
	var prefix := line.substr(start, col - start)
	var groups := [
		[KEYWORDS, CodeEdit.KIND_PLAIN_TEXT],
		[FUNCS, CodeEdit.KIND_FUNCTION],
		[registry.rooms.keys(), CodeEdit.KIND_CLASS],
		[registry.items.keys(), CodeEdit.KIND_CONSTANT],
		[registry.characters.keys() + ["player"], CodeEdit.KIND_MEMBER],
		[registry.dialogs.keys(), CodeEdit.KIND_SIGNAL],
		[registry.functions.keys(), CodeEdit.KIND_FUNCTION],
		[registry.verbs.keys(), CodeEdit.KIND_ENUM],
		[_room_names.keys(), CodeEdit.KIND_NODE_PATH],
		[_var_names(), CodeEdit.KIND_VARIABLE],
	]
	var seen := {}
	for g in groups:
		for w in g[0]:
			var word := str(w)
			if seen.has(word) or word == prefix or not word.begins_with(prefix):
				continue
			seen[word] = true
			code.add_code_completion_option(g[1], word, word)
	code.update_code_completion_options(true)


func _var_names() -> Array:
	var out := []
	for v in registry.vars:
		out.append(v.name)
	return out


## Hotspots and markers of the room whose script is open, for completion.
func _refresh_room_names() -> void:
	_room_names.clear()
	var room := registry.room_of_path(current_path)
	if room == "" or not registry.rooms.has(room):
		return
	var scene = load(registry.rooms[room])
	if not scene is PackedScene:
		return
	var inst: Node = scene.instantiate()
	for n in AdvRoom.nodes_of_type(inst, "Node2D"):
		if n is AdvHotspot:
			_room_names[n.get_id()] = true
		elif n is Marker2D and String(n.name) != "WalkTo":
			_room_names[String(n.name)] = true
		elif n is AdvWalkArea or (n is CanvasItem and n.get_parent() == inst):
			_room_names[AdvHotspot.to_id(n.name)] = true
	inst.free()


# --- actions ------------------------------------------------------------------------------------

func _on_play_room() -> void:
	var room := registry.room_of_path(current_path)
	if room == "":
		var it := tree.get_selected()
		if it and it.get_metadata(0) is Dictionary:
			room = str(it.get_metadata(0).get("room", ""))
	if room == "" or not registry.rooms.has(room):
		var edited := EditorInterface.get_edited_scene_root()
		if edited is AdvRoom:
			room = edited.get_room_id()
	if not registry.rooms.has(room):
		_log("[color=#ffd166]%s[/color]" % t("no_room"))
		return
	if _dirty:
		save_file()
	EditorInterface.play_custom_scene(registry.rooms[room])


func _run_tool(args: Array, title: String) -> void:
	if _thread and _thread.is_alive():
		return
	if _dirty:
		save_file()
	output.clear()
	_log("[b]%s[/b] %s" % [title, t("running")])
	var exe := OS.get_executable_path()
	var cmd := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--"] + args
	_thread = Thread.new()
	_thread.start(func():
		var out := []
		var code_ := OS.execute(exe, cmd, out, true)
		_tool_done.call_deferred(code_, "\n".join(out)))


func _tool_done(exit_code: int, text: String) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	var re := RegEx.create_from_string("^(res://[^:]+):(\\d+): (error|warning): (.*)$")
	for raw in text.split("\n"):
		var line := raw.strip_edges(false, true)
		if line == "" or line.begins_with("Godot Engine") or line.contains("ObjectDB instances") or line.contains("resources still in use") or line.strip_edges().begins_with("at:"):
			continue
		var m := re.search(line.strip_edges())
		if m:
			_show_issues([{"file": m.get_string(1), "line": int(m.get_string(2)), "level": m.get_string(3), "msg": m.get_string(4)}])
		elif line.begins_with("PASS"):
			_log("[color=#8eef97]%s[/color]" % _esc(line))
		elif line.begins_with("FAIL") or line.contains("FAILED"):
			_log("[color=#ff8080]%s[/color]" % _esc(line))
		else:
			_log(_esc(line))
	_log("[color=%s]exit code %d[/color]" % ["#8eef97" if exit_code == 0 else "#ff8080", exit_code])


func _sync_gui_select() -> void:
	var cur := str(ProjectSettings.get_setting("avventura/gui/scene", GUIS.two_click))
	gui_select.set_item_disabled(2, true)
	if cur == GUIS.two_click:
		gui_select.select(0)
	elif cur == GUIS.scumm:
		gui_select.select(1)
	else:
		gui_select.set_item_disabled(2, false)
		gui_select.select(2)


func _on_gui_selected(index: int) -> void:
	if index == 2:
		return
	ProjectSettings.set_setting("avventura/gui/scene", GUIS.two_click if index == 0 else GUIS.scumm)
	ProjectSettings.save()


# --- wizards --------------------------------------------------------------------------------------

func _form(title: String, fields: Array, on_ok: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	var grid := GridContainer.new()
	grid.columns = 2
	var inputs := {}
	for f in fields:
		var l := Label.new()
		l.text = f[1]
		grid.add_child(l)
		var ctrl: Control
		match f[2]:
			"color":
				var cp := ColorPickerButton.new()
				cp.color = Color.from_hsv(randf(), 0.55, 0.95)
				cp.custom_minimum_size = Vector2(120, 0)
				ctrl = cp
			"check":
				ctrl = CheckBox.new()
			_:
				var le := LineEdit.new()
				le.custom_minimum_size = Vector2(260, 0)
				ctrl = le
		inputs[f[0]] = ctrl
		grid.add_child(ctrl)
	dlg.add_child(grid)
	dlg.confirmed.connect(func():
		var values := {}
		for k in inputs:
			var c: Control = inputs[k]
			if c is LineEdit:
				values[k] = c.text.strip_edges()
			elif c is ColorPickerButton:
				values[k] = c.color.to_html(false)
			elif c is CheckBox:
				values[k] = c.button_pressed
		on_ok.call(values)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	EditorInterface.popup_dialog_centered(dlg)
	var first = inputs.values()[0]
	if first is LineEdit:
		first.grab_focus()


func _new_room() -> void:
	_form("+ " + t("new_room"), [["id", t("id"), "text"], ["name", t("name"), "text"]], func(v):
		var r := AdvScaffold.new_room(_game_dir(), v.id, v.name)
		if _report(r):
			EditorInterface.get_resource_filesystem().scan()
			refresh_tree()
			open_file(r.files[1])
			EditorInterface.open_scene_from_path.call_deferred(r.files[0]))


func _new_character() -> void:
	_form("+ " + t("new_char"), [["id", t("id"), "text"], ["name", t("name"), "text"],
		["color", t("color"), "color"], ["scene", t("with_scene"), "check"]], func(v):
		var r := AdvScaffold.new_character(_game_dir(), v.id, v.name, v.color, v.scene)
		if _report(r):
			EditorInterface.get_resource_filesystem().scan()
			refresh_tree()
			open_file(r.files[0], 0))


func _new_item() -> void:
	_form("+ " + t("new_item"), [["id", t("id"), "text"], ["name", t("name"), "text"]], func(v):
		var r := AdvScaffold.new_item(_game_dir(), v.id, v.name)
		if _report(r):
			refresh_tree()
			open_file(r.files[0]))


func _report(r: Dictionary) -> bool:
	if r.has("error"):
		_log("[color=#ff8080]%s[/color]" % _esc(r.error))
		return false
	for f in r.files:
		_log("[color=#8eef97]+[/color] %s" % f)
	return true
