@tool
class_name AdvParser
extends RefCounted
## Parses AdvScript (.adv) source text into plain Dictionaries and Arrays.
##
## AdvScript is indentation based, like GDScript. A file contains declarations
## (var, item, character, title, player, start) and blocks (on ..., dialog ..., function ...).
## See docs/GUIDA.md for the full reference.

## Words that start a statement, so they can never be the speaker of a dialogue line.
const STATEMENTS := ["if", "elif", "else", "while", "set", "walk", "face", "anim", "wait",
	"inventory", "pickup", "show", "hide", "enable", "disable", "state", "goto", "place",
	"control", "dialog", "end", "back", "stop", "option", "call", "cutscene", "bg", "random",
	"cycle", "sequence", "once", "do", "sound", "music", "camera", "fade", "print", "end_game", "video",
	"on", "function", "var", "item", "character"]

## Statements that take an indented block after a colon.
const BLOCK_STATEMENTS := ["cutscene", "bg", "random", "cycle", "sequence", "once", "do"]

const PREPOSITIONS := ["on", "with", "to", "in", "at"]
const DIRECTIONS := ["left", "right", "up", "down"]

var _path := ""
var _errors: Array = []
var _out: Dictionary = {}
var _dialog := ""
var _counter := 0


static func parse(text: String, path: String = "") -> Dictionary:
	var p := AdvParser.new()
	return p._parse(text, path)


## Parses a bare list of statements (used by the console `run` command).
static func parse_statements(text: String, path: String = "<console>") -> Dictionary:
	var p := AdvParser.new()
	p._path = path
	p._out = {"errors": p._errors}
	var body := p._parse_block(p._build_tree(text))
	return {"body": body, "errors": p._errors}


func _parse(text: String, path: String) -> Dictionary:
	_path = path
	_out = {"path": path, "decls": [], "handlers": [], "dialogs": {}, "functions": {}, "errors": _errors}
	for node in _build_tree(text):
		_counter = 0
		_parse_top(node)
	return _out


# --- structure ---------------------------------------------------------------------

func _build_tree(text: String) -> Array:
	if text.begins_with("﻿"):
		text = text.substr(1)
	var root := {"indent": -1, "children": []}
	var stack: Array = [root]
	var lines := text.split("\n")
	for i in lines.size():
		var raw: String = lines[i].replace("\r", "")
		var indent := 0
		var j := 0
		while j < raw.length() and (raw[j] == " " or raw[j] == "\t"):
			indent += 4 if raw[j] == "\t" else 1
			j += 1
		var content := raw.substr(j).strip_edges()
		if content == "" or content.begins_with("#"):
			continue
		var node := {"text": content, "line": i + 1, "indent": indent, "children": []}
		while indent <= stack.back().indent:
			stack.pop_back()
		stack.back().children.append(node)
		stack.append(node)
	return root.children


func _parse_top(node: Dictionary) -> void:
	var text := _strip_comment(node.text)
	var word := _first_word(text)
	match word:
		"on":
			var h := _parse_handler(node, text)
			if not h.is_empty():
				_out.handlers.append(h)
		"dialog":
			_parse_dialog(node, text)
		"function":
			_parse_function(node, text)
		"var":
			_parse_var(node, text)
		"item", "character":
			_parse_entity(node, text, word)
		"title", "player", "start":
			_parse_game_decl(node, text, word)
		_:
			if _try_say(node.text, node.line) != null:
				_err(node.line, "dialogue lines must be inside a block such as 'on look sign:'")
			else:
				_err(node.line, "unexpected '%s' here: a file contains 'on ...:', 'dialog ...:', 'function ...:', 'var', 'item', 'character', 'title', 'player' or 'start'" % word)


func _parse_handler(node: Dictionary, text: String) -> Dictionary:
	if not text.ends_with(":"):
		_err(node.line, "missing ':' at the end of 'on ...'")
		return {}
	var spec := text.substr(2, text.length() - 3).strip_edges()
	var w := _split_ws(spec)
	var h := {"verb": "", "item": "", "target": "", "line": node.line, "file": _path}
	match w.size():
		1:
			h.verb = w[0]
		2:
			h.verb = w[0]
			h.target = w[1]
		4:
			if not w[2] in PREPOSITIONS:
				_err(node.line, "expected 'on VERB ITEM on|with|to TARGET:' but found '%s'" % w[2])
				return {}
			h.verb = w[0]
			h.item = w[1]
			h.target = w[3]
			h.prep = w[2]
		_:
			_err(node.line, "expected 'on EVENT:', 'on VERB TARGET:' or 'on VERB ITEM with TARGET:'")
			return {}
	for key in ["verb", "item", "target"]:
		var v: String = h[key]
		if v != "" and v != "*" and not AdvExpr.is_ident(v):
			_err(node.line, "'%s' is not a valid name (use letters, digits and _)" % v)
			return {}
	h.body = _block_of(node)
	return h


func _parse_dialog(node: Dictionary, text: String) -> void:
	var name := text.substr(6).strip_edges()
	if not name.ends_with(":"):
		_err(node.line, "missing ':' at the end of 'dialog %s'" % name)
		return
	name = name.left(-1).strip_edges()
	if not AdvExpr.is_ident(name):
		_err(node.line, "'%s' is not a valid dialog name" % name)
		return
	if _out.dialogs.has(name):
		_err(node.line, "dialog '%s' is already defined at line %d" % [name, _out.dialogs[name].line])
		return
	var d := {"name": name, "line": node.line, "file": _path, "start": [], "options": []}
	_dialog = name
	var ids := {}
	for child in node.children:
		_counter = 0
		var ct := _strip_comment(child.text)
		var w := _first_word(ct)
		if w == "on":
			if ct.substr(2).strip_edges() != "start:":
				_err(child.line, "inside a dialog only 'on start:' is allowed")
				continue
			d.start = _block_of(child)
		elif w == "option":
			var o := _parse_option(child, ct)
			if o.is_empty():
				continue
			if ids.has(o.id):
				if o.explicit_id:
					_err(child.line, "option id '%s' is used twice in dialog '%s'" % [o.id, name])
					continue
				var k := 2
				while ids.has("%s_%d" % [o.id, k]):
					k += 1
				o.id = "%s_%d" % [o.id, k]
			ids[o.id] = true
			d.options.append(o)
		else:
			_err(child.line, "inside a dialog write 'option \"text\":' or 'on start:'")
	_dialog = ""
	if node.children.is_empty():
		_err(node.line, "dialog '%s' has no options" % name)
	_out.dialogs[name] = d


func _parse_option(node: Dictionary, text: String) -> Dictionary:
	if not text.ends_with(":"):
		_err(node.line, "missing ':' at the end of the option")
		return {}
	var spec := text.substr(6, text.length() - 7).strip_edges()
	var q := _find_quote(spec)
	if q == -1:
		_err(node.line, "the option text must be in quotes: option \"Who are you?\":")
		return {}
	var id := spec.left(q).strip_edges()
	if id != "" and not AdvExpr.is_ident(id):
		_err(node.line, "'%s' is not a valid option id" % id)
		return {}
	var s := _read_quoted(spec, q)
	if s.is_empty():
		_err(node.line, "unterminated quoted text")
		return {}
	var o := {"id": id if id != "" else _slug(s.text), "explicit_id": id != "", "text": s.text,
		"once": false, "hidden": false, "silent": false, "cond": null, "line": node.line}
	var rest: String = spec.substr(s.end).strip_edges()
	var if_pos := _find_word(rest, "if")
	var flags := rest if if_pos == -1 else rest.left(if_pos)
	for f in _split_ws(flags):
		if f in ["once", "hidden", "silent"]:
			o[f] = true
		else:
			_err(node.line, "unknown option flag '%s' (use once, hidden, silent or if CONDITION)" % f)
	if if_pos != -1:
		o.cond = _expr(rest.substr(if_pos + 2), node.line)
	o.body = _parse_block(node.children)
	return o


func _parse_function(node: Dictionary, text: String) -> void:
	var t := text.substr(8).strip_edges()
	if not t.ends_with(":"):
		_err(node.line, "missing ':' at the end of 'function'")
		return
	t = t.left(-1).strip_edges()
	var name := t
	var params := []
	var p := t.find("(")
	if p != -1:
		name = t.left(p).strip_edges()
		var inner := t.substr(p + 1).strip_edges()
		if not inner.ends_with(")"):
			_err(node.line, "missing ')' in the function parameters")
			return
		for a in inner.left(-1).split(",", false):
			var an := a.strip_edges()
			if not AdvExpr.is_ident(an):
				_err(node.line, "'%s' is not a valid parameter name" % an)
				return
			params.append(an)
	if not AdvExpr.is_ident(name):
		_err(node.line, "'%s' is not a valid function name" % name)
		return
	if _out.functions.has(name):
		_err(node.line, "function '%s' is already defined at line %d" % [name, _out.functions[name].line])
		return
	_out.functions[name] = {"name": name, "params": params, "body": _block_of(node), "line": node.line, "file": _path}


func _parse_var(node: Dictionary, text: String) -> void:
	var t := text.substr(3).strip_edges()
	var eq := t.find("=")
	if eq == -1:
		_err(node.line, "expected 'var name = value'")
		return
	var name := t.left(eq).strip_edges()
	if not AdvExpr.is_ident(name):
		_err(node.line, "'%s' is not a valid variable name" % name)
		return
	var ast = _expr(t.substr(eq + 1), node.line)
	if ast == null:
		return
	_out.decls.append({"k": "var", "name": name, "expr": ast, "line": node.line, "file": _path})
	_no_children(node)


func _parse_entity(node: Dictionary, text: String, word: String) -> void:
	var t := text.substr(word.length()).strip_edges()
	var has_block := t.ends_with(":")
	if has_block:
		t = t.left(-1).strip_edges()
	var id := t
	var name := ""
	var q := _find_quote(t)
	if q != -1:
		id = t.left(q).strip_edges()
		var s := _read_quoted(t, q)
		if s.is_empty() or t.substr(s.end).strip_edges() != "":
			_err(node.line, "expected: %s id \"Display name\"" % word)
			return
		name = s.text
	if not AdvExpr.is_ident(id):
		_err(node.line, "'%s' is not a valid %s id" % [id, word])
		return
	var props := {}
	if has_block:
		for child in node.children:
			var line := _strip_comment(child.text)
			var eq := line.find("=")
			if eq == -1:
				_err(child.line, "expected 'property = value'")
				continue
			props[line.left(eq).strip_edges()] = _unquote(line.substr(eq + 1).strip_edges())
	else:
		_no_children(node)
	_out.decls.append({"k": word, "id": id, "name": name, "props": props, "line": node.line, "file": _path})


func _parse_game_decl(node: Dictionary, text: String, word: String) -> void:
	var rest := text.substr(word.length()).strip_edges()
	_no_children(node)
	match word:
		"title":
			_out.decls.append({"k": "title", "value": _unquote(rest), "line": node.line, "file": _path})
		"player":
			if not AdvExpr.is_ident(rest):
				_err(node.line, "expected: player CHARACTER_ID")
				return
			_out.decls.append({"k": "player", "value": rest, "line": node.line, "file": _path})
		"start":
			var w := _split_ws(rest)
			var d := {"k": "start", "room": "", "at": "", "line": node.line, "file": _path}
			if w.size() == 1:
				d.room = w[0]
			elif w.size() == 3 and w[1] == "at":
				d.room = w[0]
				d.at = w[2]
			else:
				_err(node.line, "expected: start ROOM [at ENTRY]")
				return
			_out.decls.append(d)


# --- statements --------------------------------------------------------------------

func _block_of(node: Dictionary) -> Array:
	if node.children.is_empty():
		_err(node.line, "empty block: indent the statements that belong here")
		return []
	return _parse_block(node.children)


func _parse_block(nodes: Array) -> Array:
	var out := []
	for node in nodes:
		var st = _parse_stmt(node)
		if st == null:
			continue
		if st.k == "elif" or st.k == "else":
			var last = out.back() if not out.is_empty() else null
			if last == null or last.k != "if" or last.branches.back().cond == null:
				_err(node.line, "'%s' without a matching 'if'" % st.k)
				continue
			last.branches.append({"cond": st.get("cond"), "body": st.body})
			continue
		out.append(st)
	return out


func _parse_stmt(node: Dictionary) -> Variant:
	var say = _try_say(node.text, node.line)
	if say != null:
		if not node.children.is_empty():
			_err(node.line, "a dialogue line can't be followed by an indented block")
		return say
	var text := _strip_comment(node.text)
	var word := _first_word(text)
	var rest := text.substr(word.length()).strip_edges()
	var line: int = node.line
	var st := {"k": word, "line": line}

	if word in ["if", "elif", "while"]:
		if not rest.ends_with(":"):
			_err(line, "missing ':' at the end of '%s'" % word)
			return null
		var cond = _expr(rest.left(-1), line)
		if cond == null:
			cond = ["lit", false]  # keep the structure so a following else/elif still attaches
		var body := _block_of(node)
		if word == "if":
			st.branches = [{"cond": cond, "body": body}]
		else:
			st.cond = cond
			st.body = body
		return st
	if word == "else":
		if rest != ":":
			_err(line, "write 'else:'")
			return null
		st.body = _block_of(node)
		return st
	if word in BLOCK_STATEMENTS:
		if rest != ":":
			_err(line, "'%s' must be followed by ':' and an indented block" % word)
			return null
		st.body = _block_of(node)
		if word in ["random", "cycle", "sequence", "once"]:
			_counter += 1
			st.n = _counter
		return st
	if not node.children.is_empty():
		_err(line, "unexpected indented block after '%s'" % word)

	var w := _split_ws(rest)
	match word:
		"set":
			return _p_set(st, rest)
		"walk":
			st.nowait = _pop_flag(w, "nowait")
			st.anywhere = _pop_flag(w, "anywhere")
			if not st.nowait:
				st.nowait = _pop_flag(w, "nowait")
			var to := w.find("to")
			var by := w.find("by")
			if (to == 0 or to == 1) and by == -1:
				st.who = "player" if to == 0 else w[0]
				st.loc = _loc(" ".join(w.slice(to + 1)), line)
			elif (by == 0 or by == 1) and to == -1:
				# relative move: walk ray by 100, -20
				st.who = "player" if by == 0 else w[0]
				st.loc = _loc(" ".join(w.slice(by + 1)), line)
				if st.loc != null and not st.loc.has("pos"):
					return _bad(line, "write 'walk CHARACTER by DX, DY'")
				if st.loc != null:
					st.loc = {"by": st.loc.pos}
			else:
				return _bad(line, "write 'walk to TARGET', 'walk CHARACTER to TARGET' or 'walk CHARACTER by DX, DY' (optionally nowait / anywhere)")
			return st if st.loc != null else null
		"face":
			if w.size() == 1:
				st.who = "player"
				st.to = w[0]
			elif w.size() == 2:
				st.who = w[0]
				st.to = w[1]
			else:
				return _bad(line, "write 'face TARGET' or 'face CHARACTER left|right|up|down|TARGET'")
			return st
		"anim":
			st.nowait = _pop_flag(w, "nowait")
			st.loop = _pop_flag(w, "loop")
			if w.size() == 1:
				st.who = "player"
				st.anim = w[0]
			elif w.size() == 2:
				st.who = w[0]
				st.anim = w[1]
			else:
				return _bad(line, "write 'anim NAME' or 'anim CHARACTER NAME' (optionally followed by nowait/loop)")
			return st
		"wait":
			st.secs = _expr(rest, line)
			return st if st.secs != null else null
		"inventory":
			if w.size() < 2 or not w[0] in ["add", "remove"]:
				return _bad(line, "write 'inventory add ITEM' or 'inventory remove ITEM'")
			st.op = w[0]
			st.item = w[1]
			st.who = "player"
			if w.size() == 4 and w[2] in ["to", "from"]:
				st.who = w[3]
			elif w.size() != 2:
				return _bad(line, "write 'inventory add ITEM [to CHARACTER]'")
			return st
		"pickup":
			if w.size() == 1:
				st.obj = w[0]
				st.item = ""
			elif w.size() == 3 and w[1] == "as":
				st.obj = w[0]
				st.item = w[2]
			else:
				return _bad(line, "write 'pickup OBJECT' or 'pickup OBJECT as ITEM'")
			return st
		"show", "hide", "enable", "disable":
			# show OBJ fade 2: dissolve in 2 seconds
			st.fade = 0.0
			if word in ["show", "hide"] and w.size() >= 3 and w[w.size() - 2] == "fade" and w[w.size() - 1].is_valid_float():
				st.fade = w[w.size() - 1].to_float()
				w = w.slice(0, w.size() - 2)
			if w.size() == 1:
				st.obj = w[0]
				st.room = ""
			elif w.size() == 3 and w[1] == "in":
				st.obj = w[0]
				st.room = w[2]
			else:
				return _bad(line, "write '%s OBJECT' or '%s OBJECT in ROOM' (show/hide: optional 'fade SECONDS')" % [word, word])
			return st
		"state":
			if w.size() == 2:
				st.obj = w[0]
				st.value = _unquote(w[1])
				st.room = ""
			elif w.size() == 4 and w[2] == "in":
				st.obj = w[0]
				st.value = _unquote(w[1])
				st.room = w[3]
			else:
				return _bad(line, "write 'state OBJECT STATE' or 'state OBJECT STATE in ROOM'")
			return st
		"goto":
			if w.size() == 1:
				st.room = w[0]
				st.at = ""
			elif w.size() >= 3 and w[1] == "at":
				st.room = w[0]
				var loc = _loc(" ".join(w.slice(2)), line)
				if loc == null:
					return null
				st.at = loc.get("id", "")
				if loc.has("pos"):
					st.pos = loc.pos
			else:
				return _bad(line, "write 'goto ROOM', 'goto ROOM at ENTRY' or 'goto ROOM at X, Y'")
			return st
		"place":
			if w.size() >= 3 and w[1] == "at":
				st.who = w[0]
				st.room = ""
				st.loc = _loc(" ".join(w.slice(2)), line)
				return st if st.loc != null else null
			if w.size() == 3 and w[1] == "in":
				st.who = w[0]
				st.room = w[2]
				st.loc = null
				return st
			if w.size() >= 5 and w[1] == "in" and w[3] == "at":
				st.who = w[0]
				st.room = w[2]
				st.loc = _loc(" ".join(w.slice(4)), line)
				return st if st.loc != null else null
			return _bad(line, "write 'place CHARACTER at TARGET' or 'place CHARACTER in ROOM [at ENTRY]'")
		"control", "dialog", "sound", "video":
			if w.size() != 1:
				return _bad(line, "write '%s NAME'" % word)
			st.name = w[0]
			return st
		"music":
			if w.size() != 1:
				return _bad(line, "write 'music NAME' or 'music stop'")
			st.name = w[0]
			return st
		"end", "back", "stop", "end_game":
			if rest != "":
				return _bad(line, "'%s' takes no arguments" % word)
			return st
		"option":
			if w.size() != 2 or not w[0] in ["on", "off"]:
				return _bad(line, "write 'option on DIALOG.OPTION' or 'option off DIALOG.OPTION'")
			st.on = w[0] == "on"
			st.ref = w[1]
			if not "." in st.ref:
				if _dialog == "":
					return _bad(line, "write the dialog name too: 'option %s DIALOG.%s'" % [w[0], w[1]])
				st.ref = _dialog + "." + st.ref
			return st
		"call":
			var ast = _expr(rest, line)
			if ast == null:
				return null
			if ast[0] == "var":
				st.name = ast[1]
				st.args = []
			elif ast[0] == "call":
				st.name = ast[1]
				st.args = ast[2]
			else:
				return _bad(line, "write 'call NAME' or 'call NAME(arguments)'")
			return st
		"camera":
			if w.size() >= 1 and w[0] == "follow" and w.size() <= 2:
				st.op = "follow"
				st.who = w[1] if w.size() == 2 else "player"
				return st
			if w.size() >= 2 and w[0] == "to":
				st.op = "to"
				var secs := 0.0
				if w.size() >= 3 and w.back().is_valid_float() and not w[w.size() - 2].ends_with(","):
					secs = w.back().to_float()
					w.pop_back()
				st.secs = secs
				st.loc = _loc(" ".join(w.slice(1)), line)
				return st if st.loc != null else null
			if w.size() >= 1 and w[0] == "shake":
				st.op = "shake"
				st.secs = w[1].to_float() if w.size() > 1 else 0.5
				return st
			return _bad(line, "write 'camera follow [CHARACTER]', 'camera to TARGET [SECONDS]' or 'camera shake [SECONDS]'")
		"fade":
			if w.is_empty() or not w[0] in ["in", "out"] or w.size() > 2:
				return _bad(line, "write 'fade out [SECONDS]' or 'fade in [SECONDS]'")
			st.out = w[0] == "out"
			st.secs = w[1].to_float() if w.size() == 2 else 0.5
			return st
		"print":
			var tpl := AdvExpr.parse_template(_unquote(rest))
			if tpl.has("error"):
				return _bad(line, tpl.error)
			st.parts = tpl.parts
			return st
	if w.size() >= 1 and AdvExpr.is_ident(word) and not word in STATEMENTS:
		return _bad(line, "unknown statement '%s' (for a dialogue line write '%s: text')" % [word, word])
	return _bad(line, "unknown statement '%s'" % word)


func _p_set(st: Dictionary, rest: String) -> Variant:
	var i := 0
	while i < rest.length() and AdvExpr.is_ident_char(rest[i]):
		i += 1
	var name := rest.left(i)
	var tail := rest.substr(i).strip_edges()
	var op := ""
	for o in ["+=", "-=", "="]:
		if tail.begins_with(o):
			op = o
			break
	if not AdvExpr.is_ident(name) or op == "" or tail.begins_with("=="):
		return _bad(st.line, "write 'set NAME = VALUE' (or += / -=)")
	st.name = name
	st.op = op
	st.expr = _expr(tail.substr(op.length()), st.line)
	return st if st.expr != null else null


func _try_say(text: String, line: int) -> Variant:
	var colon := text.find(":")
	if colon <= 0:
		return null
	var head := text.left(colon).strip_edges()
	var body := text.substr(colon + 1).strip_edges()
	if body == "":
		return null
	# who@X,Y: text  -> speech shown at a fixed screen position (AGS SayAt)
	var at = null
	var a := head.find("@")
	if a != -1:
		var xy := head.substr(a + 1).split(",")
		if xy.size() != 2 or not xy[0].strip_edges().is_valid_float() or not xy[1].strip_edges().is_valid_float():
			return null
		at = Vector2(xy[0].strip_edges().to_float(), xy[1].strip_edges().to_float())
		head = head.left(a).strip_edges()
	var who := head
	var mood := ""
	var p := head.find("(")
	if p != -1:
		if not head.ends_with(")"):
			return null
		who = head.left(p).strip_edges()
		mood = head.substr(p + 1, head.length() - p - 2).strip_edges()
		if not AdvExpr.is_ident(mood):
			return null
	if not AdvExpr.is_ident(who) or who in STATEMENTS:
		return null
	var txt := body
	if body.length() >= 2 and (body[0] == "\"" or body[0] == "'"):
		# Quoted text may be followed by a comment: nina: "Hello" # greeting
		var s := _read_quoted(body, 0)
		if not s.is_empty():
			var tail := body.substr(s.end).strip_edges()
			if tail == "" or tail.begins_with("#"):
				txt = s.text
	var tpl := AdvExpr.parse_template(txt)
	if tpl.has("error"):
		_err(line, tpl.error)
		tpl = {"parts": [txt]}
	return {"k": "say", "who": who, "mood": mood, "at": at, "parts": tpl.parts, "text": txt, "line": line}


# --- helpers -----------------------------------------------------------------------

func _expr(src: String, line: int) -> Variant:
	var r := AdvExpr.parse(src.strip_edges())
	if r.has("error"):
		_err(line, "%s in '%s'" % [r.error, src.strip_edges()])
		return null
	return r.ast


func _loc(s: String, line: int) -> Variant:
	s = s.strip_edges()
	var parts := s.split(",")
	if parts.size() == 2 and parts[0].strip_edges().is_valid_float() and parts[1].strip_edges().is_valid_float():
		return {"pos": Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())}
	if AdvExpr.is_ident(s):
		return {"id": s}
	_err(line, "expected a target name or coordinates like 400, 300 (found '%s')" % s)
	return null


func _pop_flag(w: Array, flag: String) -> bool:
	if not w.is_empty() and w.back() == flag:
		w.pop_back()
		return true
	return false


func _bad(line: int, msg: String) -> Variant:
	_err(line, msg)
	return null


func _no_children(node: Dictionary) -> void:
	if not node.children.is_empty():
		_err(node.line, "unexpected indented block")


func _err(line: int, msg: String) -> void:
	_errors.append({"line": line, "msg": msg})


static func _first_word(text: String) -> String:
	var i := 0
	while i < text.length() and not text[i] in " \t:(":
		i += 1
	return text.left(i)


static func _split_ws(s: String) -> Array:
	var out := []
	for part in s.replace("\t", " ").split(" ", false):
		out.append(part)
	return out


## Removes a trailing `# comment` that is outside quotes. The # must be followed by a
## space, so colors like #ffcc00 are not comments.
static func _strip_comment(text: String) -> String:
	var quote := ""
	for i in text.length():
		var c := text[i]
		if quote != "":
			if c == "\\":
				continue
			if c == quote and (i == 0 or text[i - 1] != "\\"):
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#" and (i == 0 or text[i - 1] == " " or text[i - 1] == "\t") \
				and (i + 1 >= text.length() or text[i + 1] == " " or text[i + 1] == "\t" or text[i + 1] == "#"):
			return text.left(i).strip_edges()
	return text


static func _find_quote(s: String) -> int:
	for i in s.length():
		if s[i] == "\"" or s[i] == "'":
			return i
	return -1


## Reads a quoted string starting at [param start]. Returns {text, end} or {} if unterminated.
static func _read_quoted(s: String, start: int) -> Dictionary:
	var q := s[start]
	var buf := ""
	var i := start + 1
	while i < s.length():
		var c := s[i]
		if c == "\\" and i + 1 < s.length():
			var e := s[i + 1]
			buf += "\n" if e == "n" else e
			i += 2
			continue
		if c == q:
			return {"text": buf, "end": i + 1}
		buf += c
		i += 1
	return {}


static func _unquote(s: String) -> String:
	s = s.strip_edges()
	if s.length() >= 2 and (s[0] == "\"" or s[0] == "'"):
		var r := _read_quoted(s, 0)
		if not r.is_empty() and r.end == s.length():
			return r.text
	return s


static func _find_word(s: String, word: String) -> int:
	var from := 0
	while true:
		var i := s.find(word, from)
		if i == -1:
			return -1
		var before_ok := i == 0 or s[i - 1] == " " or s[i - 1] == "\t"
		var after := i + word.length()
		var after_ok := after >= s.length() or s[after] == " " or s[after] == "\t" or s[after] == "("
		if before_ok and after_ok:
			return i
		from = i + 1
	return -1


static func _slug(text: String) -> String:
	var out := ""
	for c in text.to_lower():
		if AdvExpr.is_ident_start(c) or AdvExpr.is_digit(c):
			out += c
		elif not out.ends_with("_") and out != "":
			out += "_"
		if out.length() >= 24:
			break
	out = out.trim_suffix("_")
	return out if out != "" and not AdvExpr.is_digit(out[0]) else "opt_" + out
