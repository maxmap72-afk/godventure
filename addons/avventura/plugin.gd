@tool
extends EditorPlugin
## Avventura editor plugin: registers the `Adv` autoload and the project settings, adds the
## "Avventura" workspace tab, the AdvScript syntax highlighter and the export plugin.

const Workspace := preload("res://addons/avventura/editor/workspace.gd")
const Highlighter := preload("res://addons/avventura/editor/adv_syntax_highlighter.gd")
const ExportPlugin := preload("res://addons/avventura/editor/export_plugin.gd")
const TRANSLATIONS := ["res://addons/avventura/i18n/avventura.en.translation", "res://addons/avventura/i18n/avventura.it.translation"]

## [name, default, type, hint, hint_string]
const SETTINGS := [
	["avventura/general/game_dir", "res://game", TYPE_STRING, PROPERTY_HINT_DIR, ""],
	["avventura/gui/scene", "res://addons/avventura/gui/two_click_gui.tscn", TYPE_STRING, PROPERTY_HINT_FILE, "*.tscn"],
	["avventura/gui/show_title_menu", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["avventura/gui/language", "", TYPE_STRING, PROPERTY_HINT_ENUM_SUGGESTION, "en,it"],
	["avventura/text/seconds_per_character", 0.05, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.01,0.2,0.005"],
	["avventura/text/min_seconds", 1.5, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.5,5,0.1"],
	["avventura/interaction/walk_before_look", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["avventura/dialog/player_says_options", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["avventura/debug/remote_control", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["avventura/debug/remote_port", 7777, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535"],
	["avventura/debug/console", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["avventura/debug/show_walk_areas", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
]

var workspace: Control
var export_plugin: EditorExportPlugin
var highlighter: EditorSyntaxHighlighter


func _enable_plugin() -> void:
	add_autoload_singleton("Adv", "res://addons/avventura/core/adv.gd")
	_ensure_settings()
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton("Adv")


func _enter_tree() -> void:
	_ensure_settings()
	_ensure_text_extensions()
	export_plugin = ExportPlugin.new()
	add_export_plugin(export_plugin)
	highlighter = Highlighter.new()
	EditorInterface.get_script_editor().register_syntax_highlighter(highlighter)
	workspace = Workspace.new()
	workspace.name = "Avventura"
	workspace.plugin = self
	EditorInterface.get_editor_main_screen().add_child(workspace)
	_make_visible(false)
	var shot := OS.get_environment("AVVENTURA_EDITOR_SCREENSHOT")
	if shot != "":
		_screenshot_and_quit.call_deferred(shot)


## Test hook: opens the workspace, saves a screenshot of the editor and quits.
func _screenshot_and_quit(path: String) -> void:
	await get_tree().create_timer(4.0).timeout
	EditorInterface.set_main_screen_editor("Avventura")
	workspace.open_file(str(ProjectSettings.get_setting("avventura/general/game_dir", "res://game")) + "/characters.adv", 30)
	if OS.get_environment("AVVENTURA_EDITOR_RUN") != "":
		workspace._run_tool([OS.get_environment("AVVENTURA_EDITOR_RUN")], "Test")
		await get_tree().create_timer(12.0).timeout
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[avventura] editor screenshot: ", path)
	get_tree().quit()


func _exit_tree() -> void:
	if export_plugin:
		remove_export_plugin(export_plugin)
	if highlighter:
		EditorInterface.get_script_editor().unregister_syntax_highlighter(highlighter)
	if workspace:
		workspace.queue_free()


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if workspace:
		workspace.visible = visible
		if visible:
			workspace.refresh_tree()


func _get_plugin_name() -> String:
	return "Avventura"


func _get_plugin_icon() -> Texture2D:
	return preload("res://addons/avventura/icons/avventura.svg")


func _ensure_settings() -> void:
	for s in SETTINGS:
		if not ProjectSettings.has_setting(s[0]):
			ProjectSettings.set_setting(s[0], s[1])
		ProjectSettings.set_initial_value(s[0], s[1])
		ProjectSettings.add_property_info({"name": s[0], "type": s[2], "hint": s[3], "hint_string": s[4]})
		ProjectSettings.set_as_basic(s[0], true)
	var tr: PackedStringArray = ProjectSettings.get_setting("internationalization/locale/translations", PackedStringArray())
	var changed := false
	for t in TRANSLATIONS:
		if not t in tr and FileAccess.file_exists(t):
			tr.append(t)
			changed = true
	if changed:
		ProjectSettings.set_setting("internationalization/locale/translations", tr)


## Lets Godot's script editor open .adv and .advtest files.
func _ensure_text_extensions() -> void:
	var es := EditorInterface.get_editor_settings()
	var key := "docks/filesystem/textfile_extensions"
	if not es.has_setting(key):
		return
	var exts := str(es.get_setting(key))
	var list := exts.split(",", false)
	var changed := false
	for e in ["adv", "advtest"]:
		if not e in list:
			list.append(e)
			changed = true
	if changed:
		es.set_setting(key, ",".join(list))
