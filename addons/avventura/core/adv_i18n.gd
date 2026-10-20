@tool
class_name AdvI18n
extends RefCounted
## Game translations, like AGS translation files: <game_dir>/lang/<locale>.po (gettext format,
## editable with any PO editor). The msgid is the game's own text, in its source language
## (setting avventura/general/source_language), the msgstr its translation; an empty msgstr
## leaves the original text. `python3 tools/adv.py i18n LOCALE` creates and updates the file.

## Native names for the language menu (others fall back to Godot's English name).
const NATIVE_NAMES := {"it": "Italiano", "en": "English", "fr": "Français", "de": "Deutsch",
	"es": "Español", "pt": "Português", "nl": "Nederlands", "pl": "Polski"}


## Parses a .po file into {msgid: msgstr}, skipping the header and untranslated entries.
static func parse_po(text: String) -> Dictionary:
	var out := {}
	var id := ""
	var str_ := ""
	var field := ""
	var fuzzy := false
	for raw in (text + "\n\n").split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("msgid "):
			if field == "msgstr" and id != "" and str_ != "" and not fuzzy:
				out[id] = str_
			if field == "msgstr":
				id = ""
				str_ = ""
				field = ""
				fuzzy = false
		if line == "":
			continue
		if line.begins_with("#,") and "fuzzy" in line:
			fuzzy = true
		elif line.begins_with("#"):
			continue
		elif line.begins_with("msgid "):
			field = "msgid"
			id = _unquote(line.substr(6))
		elif line.begins_with("msgstr "):
			field = "msgstr"
			str_ = _unquote(line.substr(7))
		elif line.begins_with("\""):
			if field == "msgid":
				id += _unquote(line)
			elif field == "msgstr":
				str_ += _unquote(line)
	return out


static func _unquote(s: String) -> String:
	s = s.strip_edges()
	if s.length() < 2 or not s.begins_with("\"") or not s.ends_with("\""):
		return ""
	return s.substr(1, s.length() - 2).c_unescape()


## Loads every <dir>/lang/*.po as a Translation for its locale (the file name).
static func load_translations(dir: String) -> Array[Translation]:
	var out: Array[Translation] = []
	var lang_dir := dir.trim_suffix("/") + "/lang"
	if not DirAccess.dir_exists_absolute(lang_dir):
		return out
	for f in DirAccess.get_files_at(lang_dir):
		if f.get_extension() != "po":
			continue
		var t := Translation.new()
		t.locale = f.get_basename()
		var msgs := parse_po(FileAccess.get_file_as_string(lang_dir + "/" + f))
		for k in msgs:
			t.add_message(k, msgs[k])
		out.append(t)
	return out


static func language_name(code: String) -> String:
	return NATIVE_NAMES.get(code, TranslationServer.get_language_name(code))


## Every translatable text of the scripts: [{text, who, file, line}] in file order. Speech lines
## keep their {expressions}: the translation must contain the same ones.
static func collect(registry: AdvRegistry) -> Array:
	var out := []
	var paths: Array = registry.files.keys()
	paths.sort()
	for path in paths:
		var parsed: Dictionary = registry.files[path]
		var rel := str(path).trim_prefix(registry.game_dir + "/")
		for d in parsed.decls:
			if d.k == "title":
				out.append({"text": d.value, "who": "title", "file": rel, "line": d.line})
			elif d.k in ["item", "character"]:
				if str(d.name) != "":
					out.append({"text": d.name, "who": d.k, "file": rel, "line": d.line})
				if str(d.props.get("description", "")) != "":
					out.append({"text": str(d.props.description), "who": "look", "file": rel, "line": d.line})
		var blocks := []
		for h in parsed.handlers:
			blocks.append(h)
		for name in parsed.functions:
			blocks.append(parsed.functions[name])
		for name in parsed.dialogs:
			blocks.append(parsed.dialogs[name])
		blocks.sort_custom(func(a, b): return a.line < b.line)
		for b in blocks:
			_walk(b, rel, out)
	return out


static func _walk(node: Variant, rel: String, out: Array) -> void:
	if node is Dictionary:
		if node.get("k") == "say":
			out.append({"text": node.text, "who": node.who, "file": rel, "line": node.line})
			return
		if node.has("explicit_id") and node.has("text"):   # a dialog option
			out.append({"text": node.text, "who": "option", "file": rel, "line": node.get("line", 0)})
		for k in node:
			if k in ["cond", "expr", "parts"]:
				continue
			_walk(node[k], rel, out)
	elif node is Array:
		for v in node:
			_walk(v, rel, out)
