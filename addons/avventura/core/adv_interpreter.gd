class_name AdvInterpreter
extends RefCounted
## Runs AdvScript blocks. Every statement is awaited, so a script reads top to bottom
## like a screenplay while the game keeps running (walks, speech, fades...).

## Control flow results of a statement/block.
enum { CONT, STOP, END, BACK }

const MAX_DEPTH := 64
const MAX_LOOP := 100000

## The Adv singleton.
var adv: Node


## Execution context of a running script.
class Ctx:
	extends RefCounted
	var interp
	var file := ""
	var scope := ""
	var key := ""
	var locals: Dictionary = {}
	var dialogs: Array = []
	var depth := 0
	var line := 0
	var gen := 0

	func expr_get_var(name: String) -> Variant:
		if locals.has(name):
			return locals[name]
		return interp.adv.get_var(name)

	func expr_call(name: String, args: Array) -> Variant:
		return interp.call_function(name, args, self)

	func expr_error(msg: String) -> void:
		interp.error(msg, self)

	func copy() -> Ctx:
		var c := Ctx.new()
		c.interp = interp
		c.file = file
		c.scope = scope
		c.key = key
		c.locals = locals.duplicate()
		c.dialogs = dialogs
		c.depth = depth
		c.line = line
		c.gen = gen
		return c


func _init(engine: Node) -> void:
	adv = engine


func new_ctx(file: String, scope: String, key: String) -> Ctx:
	var c := Ctx.new()
	c.interp = self
	c.file = file
	c.scope = scope
	c.key = key
	c.gen = adv.generation
	return c


## Runs an `on ...:` handler. [param locals] become variables visible in the script
## (verb, target, item). `times` and `first` tell how many times it already ran.
func run_handler(h: Dictionary, locals: Dictionary = {}) -> int:
	var scope: String = h.get("room", "")
	var key: String = (scope + ":" + h.key) if scope != "" else h.key
	var ctx := new_ctx(h.file, scope, key)
	var times: int = adv.state.bump("h:" + key)
	ctx.locals = locals.duplicate()
	ctx.locals["times"] = times
	ctx.locals["first"] = times == 0
	return await exec_block(h.body, ctx)


## Parses and runs statements typed in the console (`run ...`).
func run_source(source: String) -> Dictionary:
	var parsed := AdvParser.parse_statements(source)
	if not parsed.errors.is_empty():
		return {"error": parsed.errors[0].msg}
	var ctx := new_ctx("<console>", adv.state.room, "console")
	await exec_block(parsed.body, ctx)
	return {}


func exec_block(block: Array, ctx: Ctx) -> int:
	for st in block:
		if ctx.gen != adv.generation:
			return STOP
		var r: int = await exec(st, ctx)
		if r != CONT:
			return r
	return CONT


func exec(st: Dictionary, ctx: Ctx) -> int:
	ctx.line = st.line
	match st.k:
		"say":
			var text := AdvExpr.render_template(st.parts, ctx)
			await adv.say(st.who, text, st.mood)
		"if":
			for b in st.branches:
				if b.cond == null or AdvExpr.truthy(eval(b.cond, ctx)):
					return await exec_block(b.body, ctx)
		"while":
			var n := 0
			while AdvExpr.truthy(eval(st.cond, ctx)):
				n += 1
				if n > MAX_LOOP:
					error("'while' stopped after %d rounds: is the condition ever false?" % MAX_LOOP, ctx)
					return STOP
				var r: int = await exec_block(st.body, ctx)
				if r != CONT:
					return r
				if not adv.fast:
					await adv.get_tree().process_frame
		"set":
			var v = eval(st.expr, ctx)
			if st.op != "=":
				v = AdvExpr.binop("+" if st.op == "+=" else "-", ctx.expr_get_var(st.name), v, ctx)
			if ctx.locals.has(st.name):
				ctx.locals[st.name] = v
			else:
				adv.set_var(st.name, v)
		"walk":
			await adv.walk(st.who, _loc(st.loc), not st.nowait)
		"face":
			adv.face(st.who, st.to)
		"anim":
			await adv.anim(st.who, st.anim, not st.nowait and not st.loop, st.loop)
		"wait":
			await adv.wait(float(AdvExpr.num(eval(st.secs, ctx))))
		"inventory":
			if st.op == "add":
				adv.inventory_add(st.item, st.who)
			else:
				adv.inventory_remove(st.item, st.who)
		"pickup":
			await adv.pickup(st.obj, st.item)
		"show", "hide":
			adv.set_object_visible(st.obj, st.k == "show", st.room)
		"enable", "disable":
			adv.set_object_enabled(st.obj, st.k == "enable", st.room)
		"state":
			adv.set_object_state(st.obj, st.value, st.room)
		"goto":
			await adv.change_room(st.room, st.at)
		"place":
			adv.place(st.who, st.room, _loc(st.loc) if st.loc != null else null)
		"control":
			await adv.set_player(st.name)
		"dialog":
			return await run_dialog(st.name, ctx)
		"end":
			return END
		"back":
			return BACK
		"stop":
			return STOP
		"end_game":
			adv.end_game()
			return STOP
		"option":
			adv.set_option(st.ref, st.on)
		"call":
			return await _call_statement(st, ctx)
		"cutscene":
			adv.begin_cutscene()
			var r: int = await exec_block(st.body, ctx)
			adv.end_cutscene()
			return r
		"bg":
			var c := ctx.copy()
			c.dialogs = []
			exec_block(st.body, c)
		"do":
			return await exec_block(st.body, ctx)
		"random", "cycle", "sequence", "once":
			var n: int = st.body.size()
			if n == 0:
				return CONT
			var count: int = adv.state.bump("b:%s#%d" % [ctx.key, st.n])
			match st.k:
				"once":
					if count > 0:
						return CONT
					return await exec_block(st.body, ctx)
				"random":
					return await exec(st.body[adv.rng.randi_range(0, n - 1)], ctx)
				"cycle":
					return await exec(st.body[count % n], ctx)
				_:
					return await exec(st.body[mini(count, n - 1)], ctx)
		"sound":
			adv.play_sound(st.name)
		"music":
			if st.name == "stop":
				adv.stop_music()
			else:
				adv.play_music(st.name)
		"camera":
			match st.op:
				"follow":
					adv.camera_follow(st.who)
				"to":
					await adv.camera_to(_loc(st.loc), st.secs)
				"shake":
					adv.camera_shake(st.secs)
		"fade":
			await adv.fade(st.out, st.secs)
		"print":
			adv.log_line("[print] " + AdvExpr.render_template(st.parts, ctx))
		_:
			error("unknown statement '%s'" % st.k, ctx)
	return CONT


# --- dialogs -----------------------------------------------------------------------------

func run_dialog(name: String, ctx: Ctx) -> int:
	var d: Dictionary = adv.registry.dialogs.get(name, {})
	if d.is_empty():
		error("unknown dialog '%s'" % name, ctx)
		return CONT
	if ctx.dialogs.size() >= 16:
		error("too many nested dialogs (is a dialog calling itself?)", ctx)
		return STOP
	ctx.dialogs.push_back(name)
	var saved_key := ctx.key
	var r := CONT
	if not d.start.is_empty():
		ctx.key = "d:%s:start" % name
		r = await exec_block(d.start, ctx)
	while r == CONT and ctx.gen == adv.generation:
		var avail := []
		for o in d.options:
			if option_available(name, o, ctx):
				avail.append(o)
		if avail.is_empty():
			break
		var texts := []
		for o in avail:
			texts.append(option_text(o, ctx))
		var idx: int = await adv.request_choice(texts)
		if idx < 0 or idx >= avail.size():
			r = STOP
			break
		var o: Dictionary = avail[idx]
		var ref: String = name + "." + o.id
		var ost: Dictionary = adv.state.option(ref)
		ost.used = int(ost.get("used", 0)) + 1
		if not o.silent and adv.player_says_options:
			await adv.say(adv.state.player, texts[idx])
		ctx.key = "d:" + ref
		r = await exec_block(o.body, ctx)
	ctx.dialogs.pop_back()
	ctx.key = saved_key
	if r == END and not ctx.dialogs.is_empty():
		return END
	if r == STOP:
		return STOP
	return CONT


func option_available(dialog: String, o: Dictionary, ctx: Ctx) -> bool:
	var st: Dictionary = adv.state.options.get(dialog + "." + o.id, {})
	if not st.get("on", not o.hidden):
		return false
	if o.once and int(st.get("used", 0)) > 0:
		return false
	if o.cond != null and not AdvExpr.truthy(eval(o.cond, ctx)):
		return false
	return true


func option_text(o: Dictionary, ctx: Ctx) -> String:
	var text: String = adv.tr(o.text)
	if not "{" in text:
		return text
	var tpl := AdvExpr.parse_template(text)
	return text if tpl.has("error") else AdvExpr.render_template(tpl.parts, ctx)


# --- functions ---------------------------------------------------------------------------

func _call_statement(st: Dictionary, ctx: Ctx) -> int:
	var args := []
	for a in st.args:
		args.append(eval(a, ctx))
	var f: Dictionary = adv.registry.functions.get(st.name, {})
	if not f.is_empty():
		if ctx.depth >= MAX_DEPTH:
			error("too many nested calls (is '%s' calling itself forever?)" % st.name, ctx)
			return STOP
		var c := new_ctx(f.file, ctx.scope, "f:" + st.name)
		c.dialogs = ctx.dialogs
		c.depth = ctx.depth + 1
		c.gen = ctx.gen
		for i in f.params.size():
			c.locals[f.params[i]] = args[i] if i < args.size() else null
		var r: int = await exec_block(f.body, c)
		return CONT if r == STOP else r
	var target: Object = adv.find_script_method(st.name)
	if target:
		await target.callv(st.name, args)
		return CONT
	error("unknown function '%s' (define it with 'function %s:' or in a GDScript)" % [st.name, st.name], ctx)
	return CONT


## Built-in functions available in expressions.
func call_function(name: String, args: Array, ctx: Ctx) -> Variant:
	var a0 = args[0] if args.size() > 0 else null
	var a1 = args[1] if args.size() > 1 else null
	match name:
		"has":
			return adv.has_item(str(a0), str(a1) if a1 != null else "")
		"visited":
			return int(adv.state.visited.get(str(a0), 0)) > 0
		"visits":
			return int(adv.state.visited.get(str(a0), 0))
		"room":
			return adv.state.room
		"player":
			return adv.state.player
		"state":
			return adv.get_object_state(str(a0), str(a1) if a1 != null else "")
		"shown":
			return adv.is_object_visible(str(a0), str(a1) if a1 != null else "")
		"enabled":
			return adv.is_object_enabled(str(a0), str(a1) if a1 != null else "")
		"room_of":
			return adv.character_room(str(a0))
		"used":
			return int(adv.state.options.get(str(a0), {}).get("used", 0))
		"name":
			return adv.display_name(str(a0))
		"is_player":
			return str(a0) == adv.state.player
		"near":
			var ch: AdvCharacter = adv.get_character(str(a0))
			if ch == null or a1 == null:
				return false
			var p = adv.position_of(str(a1), ch)
			var dist := float(AdvExpr.num(args[2])) if args.size() > 2 else 40.0
			return p != null and ch.room_position().distance_to(p) <= dist
		"said":
			return adv.recently_said(str(a0))
		"ended":
			return adv.game_over
		"random":
			if args.size() < 2:
				return adv.rng.randi_range(0, int(AdvExpr.num(a0)))
			return adv.rng.randi_range(int(AdvExpr.num(a0)), int(AdvExpr.num(a1)))
		"chance":
			return adv.rng.randf() * 100.0 < float(AdvExpr.num(a0))
		"str":
			return AdvExpr.to_text(a0)
		"int":
			return int(AdvExpr.num(a0))
		"float":
			return float(AdvExpr.num(a0))
		"len":
			if a0 is String or a0 is Array or a0 is Dictionary:
				return a0.size() if not a0 is String else a0.length()
			return 0
		"min":
			return min(AdvExpr.num(a0), AdvExpr.num(a1))
		"max":
			return max(AdvExpr.num(a0), AdvExpr.num(a1))
		"abs":
			return absf(float(AdvExpr.num(a0)))
	var target: Object = adv.find_script_method(name)
	if target:
		return target.callv(name, args)
	error("unknown function '%s()'" % name, ctx)
	return null


# --- helpers -----------------------------------------------------------------------------

func eval(ast: Variant, ctx: Ctx) -> Variant:
	if ast == null:
		return null
	return AdvExpr.evaluate(ast, ctx)


func _loc(loc: Variant) -> Variant:
	if loc is Dictionary:
		if loc.has("pos"):
			return loc.pos
		return loc.get("id", "")
	return loc


func error(msg: String, ctx: Ctx = null) -> void:
	if ctx:
		adv.script_error(msg, ctx.file, ctx.line)
	else:
		adv.script_error(msg, "", 0)
