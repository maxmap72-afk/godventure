@tool
extends EditorExportPlugin
## Adds the AdvScript files (.adv) to exported games: they are plain text, so Godot would
## otherwise leave them out.


func _get_name() -> String:
	return "Avventura"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var game_dir := str(ProjectSettings.get_setting("avventura/general/game_dir", "res://game"))
	for f in AdvRegistry.find_files(game_dir, ["adv"]):
		add_file(f, FileAccess.get_file_as_bytes(f), false)
