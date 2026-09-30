@tool
class_name AdvExpr
extends RefCounted
## Small expression language shared by AdvScript conditions, `set` values and
## `{interpolation}` inside dialogue lines.
##
## Expressions are parsed once into an AST made of Arrays and evaluated against an
## environment object implementing:
##   expr_get_var(name: String) -> Variant
##   expr_call(name: String, args: Array) -> Variant
##
## It is deliberately forgiving, because game authors are not always programmers:
## - undefined variables are `null`, and `null` equals every "empty" value (false, 0, "")
## - booleans and numbers compare and add as numbers (true == 1)
## - id functions such as has(key) take a bare identifier as the literal id "key"

## Functions whose bare-identifier arguments are literal ids: has(key) == has("key").
const ID_FUNCS := ["has", "visited", "visits", "state", "shown", "enabled", "room_of",
	"used", "name", "is_player", "near"]

const KEYWORDS := ["and", "or", "not", "in", "true", "false", "null"]

var _toks: Array = []
var _pos := 0
var _error := ""


## Parses [param src]. Returns {"ast": Array} or {"error": String}.
static func parse(src: String) -> Dictionary:
	var p := AdvExpr.new()
	return p._parse_all(src)


## Evaluates a parsed AST against [param env].
static func evaluate(ast: Array, env: Object) -> Variant:
	match ast[0]:
		"lit":
			return ast[1]
		"var":
			return env.expr_get_var(ast[1])
		"not":
			return not truthy(evaluate(ast[1], env))
		"neg":
			return -num(evaluate(ast[1], env))
		"and":
			return truthy(evaluate(ast[1], env)) and truthy(evaluate(ast[2], env))
		"or":
			return truthy(evaluate(ast[1], env)) or truthy(evaluate(ast[2], env))
		"list":
			var out := []
			for a in ast[1]:
				out.append(evaluate(a, env))
			return out
		"op":
			return binop(ast[1], evaluate(ast[2], env), evaluate(ast[3], env), env)
		"call":
			var args := []
			var id_args: bool = ast[1] in ID_FUNCS
			for a in ast[2]:
				if id_args and a[0] == "var":
					args.append(a[1])
				else:
					args.append(evaluate(a, env))
			return env.expr_call(ast[1], args)
	return null


## Parses a dialogue line with {expressions}. Returns {"parts": Array} or {"error": String}.
## Parts are plain Strings or ["expr", ast, source].
static func parse_template(text: String) -> Dictionary:
	var parts := []
	var buf := ""
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == "\\" and i + 1 < n and (text[i + 1] == "{" or text[i + 1] == "}"):
			buf += text[i + 1]
			i += 2
			continue
		if c == "{":
			var j := text.find("}", i)
			if j == -1:
				return {"error": "missing '}' in text"}
			var src := text.substr(i + 1, j - i - 1)
			var r := parse(src)
			if r.has("error"):
				return {"error": "in {%s}: %s" % [src, r.error]}
			if buf != "":
				parts.append(buf)
				buf = ""
			parts.append(["expr", r.ast, src])
			i = j + 1
			continue
		buf += c
		i += 1
	if buf != "" or parts.is_empty():
		parts.append(buf)
	return {"parts": parts}


static func render_template(parts: Array, env: Object) -> String:
	var s := ""
	for p in parts:
		if p is String:
			s += p
		else:
			s += to_text(evaluate(p[1], env))
	return s


## Collects variable names and called functions used by an AST (for the linter).
static func collect(ast: Array, vars: Dictionary, calls: Dictionary) -> void:
	match ast[0]:
		"var":
			vars[ast[1]] = true
		"not", "neg":
			collect(ast[1], vars, calls)
		"and", "or":
			collect(ast[1], vars, calls)
			collect(ast[2], vars, calls)
		"op":
			collect(ast[2], vars, calls)
			collect(ast[3], vars, calls)
		"list":
			for a in ast[1]:
				collect(a, vars, calls)
		"call":
			calls[ast[1]] = true
			var id_args: bool = ast[1] in ID_FUNCS
			for a in ast[2]:
				if not (id_args and a[0] == "var"):
					collect(a, vars, calls)


# --- value semantics -------------------------------------------------------------

static func truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v) != ""
		TYPE_ARRAY, TYPE_DICTIONARY:
			return not v.is_empty()
	return true


static func num(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL:
			return 0
		TYPE_BOOL:
			return 1 if v else 0
		TYPE_INT, TYPE_FLOAT:
			return v
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v)
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return s.to_float()
	return 0


static func equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		if a == null and b == null:
			return true
		return not truthy(b if a == null else a)
	if _numlike(a) and _numlike(b):
		return is_equal_approx(float(num(a)), float(num(b)))
	if _stringlike(a) and _stringlike(b):
		return str(a) == str(b)
	if typeof(a) == typeof(b):
		return a == b
	return false


static func binop(op: String, a: Variant, b: Variant, env: Object = null) -> Variant:
	match op:
		"==":
			return equal(a, b)
		"!=":
			return not equal(a, b)
		"<", ">", "<=", ">=":
			if _stringlike(a) and _stringlike(b):
				var sa := str(a)
				var sb := str(b)
				match op:
					"<": return sa < sb
					">": return sa > sb
					"<=": return sa <= sb
					_: return sa >= sb
			var x = num(a)
			var y = num(b)
			match op:
				"<": return x < y
				">": return x > y
				"<=": return x <= y
				_: return x >= y
		"+":
			if _stringlike(a) or _stringlike(b):
				return to_text(a) + to_text(b)
			if a is Array and b is Array:
				return a + b
			return num(a) + num(b)
		"-":
			return num(a) - num(b)
		"*":
			return num(a) * num(b)
		"/", "%":
			var x = num(a)
			var y = num(b)
			if y == 0:
				if env and env.has_method("expr_error"):
					env.expr_error("division by zero")
				return 0
			if op == "%":
				if x is int and y is int:
					return x % y
				return fmod(float(x), float(y))
			if x is int and y is int and x % y == 0:
				return x / y
			return float(x) / float(y)
		"in":
			if b is Array:
				for e in b:
					if equal(a, e):
						return true
				return false
			if b is Dictionary:
				return b.has(a)
			if _stringlike(b):
				return to_text(a) in str(b)
			return false
	return null


static func to_text(v: Variant) -> String:
	if v == null:
		return ""
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return str(int(v))
	return str(v)


static func _numlike(v: Variant) -> bool:
	var t := typeof(v)
	return t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT


static func _stringlike(v: Variant) -> bool:
	var t := typeof(v)
	return t == TYPE_STRING or t == TYPE_STRING_NAME


# --- tokenizer -------------------------------------------------------------------

static func tokenize(src: String) -> Array:
	var toks: Array = []
	var i := 0
	var n := src.length()
	while i < n:
		var c := src[i]
		if c == " " or c == "\t":
			i += 1
			continue
		var start := i
		if is_digit(c):
			while i < n and (is_digit(src[i]) or (src[i] == "." and i + 1 < n and is_digit(src[i + 1]))):
				i += 1
			var s := src.substr(start, i - start)
			toks.append({"t": "num", "v": s.to_float() if s.contains(".") else s.to_int(), "p": start})
			continue
		if c == "\"" or c == "'":
			var q := c
			var buf := ""
			var closed := false
			i += 1
			while i < n:
				var d := src[i]
				if d == "\\" and i + 1 < n:
					var e := src[i + 1]
					buf += "\n" if e == "n" else e
					i += 2
					continue
				if d == q:
					closed = true
					i += 1
					break
				buf += d
				i += 1
			if not closed:
				return [{"t": "err", "v": "unterminated string", "p": start}]
			toks.append({"t": "str", "v": buf, "p": start})
			continue
		if is_ident_start(c):
			while i < n and is_ident_char(src[i]):
				i += 1
			var word := src.substr(start, i - start)
			while word.ends_with("."):
				word = word.left(-1)
				i -= 1
			toks.append({"t": "id", "v": word, "p": start})
			continue
		var two := src.substr(i, 2)
		if two in ["==", "!=", "<=", ">=", "&&", "||", "+=", "-="]:
			toks.append({"t": "op", "v": two, "p": start})
			i += 2
			continue
		if c in "+-*/%<>()[],=!:":
			toks.append({"t": "op", "v": c, "p": start})
			i += 1
			continue
		return [{"t": "err", "v": "unexpected character '%s'" % c, "p": start}]
	return toks


static func is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


static func is_ident_start(c: String) -> bool:
	return c == "_" or c.to_lower() != c.to_upper()


static func is_ident_char(c: String) -> bool:
	return is_ident_start(c) or is_digit(c) or c == "."


## True for names like `door`, `beppe.met`, `key_2` (dots allow namespacing).
static func is_ident(s: String) -> bool:
	if s == "" or not is_ident_start(s[0]) or s.ends_with("."):
		return false
	for c in s:
		if not is_ident_char(c):
			return false
	return not s in KEYWORDS


# --- recursive descent parser ----------------------------------------------------

func _parse_all(src: String) -> Dictionary:
	_toks = tokenize(src)
	if not _toks.is_empty() and _toks[0].t == "err":
		return {"error": _toks[0].v}
	if _toks.is_empty():
		return {"error": "empty expression"}
	_toks.append({"t": "eof", "v": "", "p": src.length()})
	_pos = 0
	_error = ""
	var ast: Array = _p_or()
	if _error == "" and _peek().t != "eof":
		if _peek().v == "=":
			_fail("use '==' to compare values ('=' is only for 'set')")
		else:
			_fail("unexpected '%s'" % _peek().v)
	if _error != "":
		return {"error": _error}
	return {"ast": ast}


func _peek() -> Dictionary:
	return _toks[_pos]


func _next() -> Dictionary:
	var t: Dictionary = _toks[_pos]
	if _pos < _toks.size() - 1:
		_pos += 1
	return t


func _is(v: String) -> bool:
	var t: Dictionary = _toks[_pos]
	return (t.t == "op" or t.t == "id") and t.v == v


func _fail(msg: String) -> void:
	if _error == "":
		_error = msg


func _p_or() -> Array:
	var a := _p_and()
	while _is("or") or _is("||"):
		_next()
		a = ["or", a, _p_and()]
	return a


func _p_and() -> Array:
	var a := _p_not()
	while _is("and") or _is("&&"):
		_next()
		a = ["and", a, _p_not()]
	return a


func _p_not() -> Array:
	if _is("not") or _is("!"):
		_next()
		return ["not", _p_not()]
	return _p_cmp()


func _p_cmp() -> Array:
	var a := _p_sum()
	for op in ["==", "!=", "<=", ">=", "<", ">"]:
		if _is(op):
			_next()
			return ["op", op, a, _p_sum()]
	if _is("in"):
		_next()
		return ["op", "in", a, _p_sum()]
	if _is("not") and _pos + 1 < _toks.size() and _toks[_pos + 1].t == "id" and _toks[_pos + 1].v == "in":
		_next()
		_next()
		return ["not", ["op", "in", a, _p_sum()]]
	return a


func _p_sum() -> Array:
	var a := _p_term()
	while _is("+") or _is("-"):
		var op: String = _next().v
		a = ["op", op, a, _p_term()]
	return a


func _p_term() -> Array:
	var a := _p_unary()
	while _is("*") or _is("/") or _is("%"):
		var op: String = _next().v
		a = ["op", op, a, _p_unary()]
	return a


func _p_unary() -> Array:
	if _is("-"):
		_next()
		return ["neg", _p_unary()]
	return _p_primary()


func _p_primary() -> Array:
	var t := _next()
	match t.t:
		"num", "str":
			return ["lit", t.v]
		"id":
			match t.v:
				"true":
					return ["lit", true]
				"false":
					return ["lit", false]
				"null":
					return ["lit", null]
				"and", "or", "not", "in":
					_fail("unexpected '%s'" % t.v)
					return ["lit", null]
			if _is("("):
				_next()
				var args := []
				if not _is(")"):
					while true:
						args.append(_p_or())
						if _is(","):
							_next()
							continue
						break
				if _is(")"):
					_next()
				else:
					_fail("expected ')' after the arguments of %s(...)" % t.v)
				return ["call", t.v, args]
			return ["var", t.v]
		"op":
			if t.v == "(":
				var e := _p_or()
				if _is(")"):
					_next()
				else:
					_fail("expected ')'")
				return e
			if t.v == "[":
				var items := []
				if not _is("]"):
					while true:
						items.append(_p_or())
						if _is(","):
							_next()
							continue
						break
				if _is("]"):
					_next()
				else:
					_fail("expected ']'")
				return ["list", items]
		"eof":
			_fail("incomplete expression")
			return ["lit", null]
	_fail("unexpected '%s'" % t.v)
	return ["lit", null]
