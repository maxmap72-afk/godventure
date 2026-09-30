@tool
extends EditorSyntaxHighlighter
## Syntax colors for AdvScript (.adv / .advtest), used by the Avventura workspace and
## selectable in Godot's script editor (Edit > Syntax Highlighter > AdvScript).

const BLOCK_WORDS := ["on", "dialog", "function", "option", "if", "elif", "else", "while",
	"cutscene", "bg", "random", "cycle", "sequence", "once", "do"]
const DECL_WORDS := ["var", "item", "character", "title", "player", "start"]
const STMT_WORDS := ["set", "walk", "face", "anim", "wait", "inventory", "pickup", "show", "hide",
	"enable", "disable", "state", "goto", "place", "control", "end", "back", "stop", "call",
	"sound", "music", "camera", "fade", "print", "end_game", "expect", "choose", "skip", "scene"]
const OPERATOR_WORDS := ["and", "or", "not", "in", "true", "false", "null", "to", "at", "with",
	"as", "from", "add", "remove", "nowait", "loop", "once", "hidden", "silent", "follow", "out"]

var c_text := Color(0.87, 0.88, 0.9)
var c_comment := Color(0.5, 0.53, 0.58)
var c_block := Color(1.0, 0.44, 0.52)
var c_decl := Color(0.66, 0.55, 1.0)
var c_stmt := Color(0.35, 0.78, 1.0)
var c_op := Color(0.9, 0.62, 0.95)
var c_string := Color(1.0, 0.93, 0.63)
var c_number := Color(0.63, 1.0, 0.88)
var c_speaker := Color(1.0, 0.72, 0.4)
var c_dialogue := Color(0.95, 0.95, 0.85)
var c_interp := Color(0.55, 0.95, 0.6)


func _get_name() -> String:
	return "AdvScript"


func _get_supported_languages() -> PackedStringArray:
	return PackedStringArray(["adv", "advtest"])


func _get_line_syntax_highlighting(line_no: int) -> Dictionary:
	var text: String = get_text_edit().get_line(line_no)
	var out := {}
	var i := 0
	var n := text.length()
	while i < n and (text[i] == " " or text[i] == "\t"):
		i += 1
	if i >= n:
		return out
	if text[i] == "#":
		out[i] = {"color": c_comment}
		return out
	# Dialogue line: speaker(mood): text
	var colon := text.find(":", i)
	if colon > i:
		var head := text.substr(i, colon - i).strip_edges()
		var who := head.get_slice("(", 0).strip_edges()
		if AdvExpr.is_ident(who) and not who in AdvParser.STATEMENTS and text.substr(colon + 1).strip_edges() != "" \
				and (head == who or (head.ends_with(")") and "(" in head)):
			out[i] = {"color": c_speaker}
			out[colon] = {"color": c_text}
			_dialogue(text, colon + 1, out)
			return out
	var word_start := -1
	while i < n:
		var c := text[i]
		if c == "#" and (i == 0 or text[i - 1] == " ") and (i + 1 >= n or text[i + 1] == " "):
			out[i] = {"color": c_comment}
			return out
		if c == "\"" or c == "'":
			var j := i + 1
			while j < n and text[j] != c:
				j += 2 if text[j] == "\\" else 1
			out[i] = {"color": c_string}
			i = mini(j + 1, n)
			if i < n:
				out[i] = {"color": c_text}
			continue
		if AdvExpr.is_ident_start(c):
			word_start = i
			while i < n and (AdvExpr.is_ident_char(text[i])):
				i += 1
			var w := text.substr(word_start, i - word_start)
			var col := c_text
			if w in BLOCK_WORDS:
				col = c_block
			elif w in DECL_WORDS and word_start == text.length() - text.strip_edges(true, false).length():
				col = c_decl
			elif w in STMT_WORDS:
				col = c_stmt
			elif w in OPERATOR_WORDS:
				col = c_op
			out[word_start] = {"color": col}
			if i < n:
				out[i] = {"color": c_text}
			continue
		if AdvExpr.is_digit(c):
			out[i] = {"color": c_number}
			while i < n and (AdvExpr.is_digit(text[i]) or text[i] == "."):
				i += 1
			if i < n:
				out[i] = {"color": c_text}
			continue
		i += 1
	return out


func _dialogue(text: String, from: int, out: Dictionary) -> void:
	out[from] = {"color": c_dialogue}
	var i := from
	while i < text.length():
		if text[i] == "{":
			var j := text.find("}", i)
			if j == -1:
				return
			out[i] = {"color": c_interp}
			if j + 1 < text.length():
				out[j + 1] = {"color": c_dialogue}
			i = j + 1
			continue
		i += 1
