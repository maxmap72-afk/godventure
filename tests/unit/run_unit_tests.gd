extends SceneTree
## Unit tests for the AdvScript language and the pathfinder.
##   godot --headless --path . --script res://tests/unit/run_unit_tests.gd

var failures := 0
var checks := 0


class Env:
	var vars := {"coins": 3, "name": "Nina", "flag": true}

	func expr_get_var(n):
		return vars.get(n, null)

	func expr_call(n, args):
		if n == "has":
			return args[0] == "key"
		return null


func _init() -> void:
	test_expressions()
	test_parser()
	test_parser_errors()
	test_parser_say_at()
	test_pathfinder()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL: " + what)


func test_expressions() -> void:
	var env := Env.new()
	var cases := {
		"coins + 1": 4, "coins == 3 and flag": true, "not missing": true, "missing == 0": true,
		"missing == false": true, "has(key)": true, "has(rope)": false, "\"a\" + coins": "a3",
		"coins > 2 or false": true, "7 / 2": 3.5, "6 / 2": 3, "coins in [1, 2, 3]": true,
		"name == \"Nina\"": true, "true == 1": true, "coins not in [4]": true, "-coins + 10": 7,
		"(1 + 2) * 3": 9, "7 % 4": 3, "\"ab\" < \"b\"": true, "null == \"\"": true,
	}
	for src in cases:
		var r := AdvExpr.parse(src)
		if r.has("error"):
			check(false, "parse %s: %s" % [src, r.error])
			continue
		var v = AdvExpr.evaluate(r.ast, env)
		check(typeof(v) == typeof(cases[src]) and v == cases[src], "%s => %s (expected %s)" % [src, v, cases[src]])
	for bad in ["x = 1", "a +", "has(", "\"open", "a b", ""]:
		check(AdvExpr.parse(bad).has("error"), "expected an error for '%s'" % bad)
	var t := AdvExpr.parse_template("Hai {coins} monete, {name}! \\{no}")
	check(AdvExpr.render_template(t.parts, env) == "Hai 3 monete, Nina! {no}", "template rendering")


func test_parser() -> void:
	var src := """
title "Test"
player nina
start beach at dock
var coins = 0
item key "Key":
    icon = res://key.png
    color = #ffaa00
character beppe "Beppe":
    color = #ffcc00

on enter:
    if first:
        nina: Hello! # comment after text is kept
    elif coins > 2:
        nina(happy): "Rich: {coins}!" # comment after quotes is dropped
    else:
        narrator: Nothing.
    walk to 400, 300 nowait
    walk beppe to barrel
    random:
        nina: A
        nina: B
    cutscene:
        dialog beppe

on use key on door:
    nina: Open.

dialog beppe:
    option "Who?" once:
        beppe: Me.
    option lh "Lighthouse" hidden if coins > 1:
        option off lh
        back

function help(n):
    stop
"""
	var p := AdvParser.parse(src, "res://t.adv")
	check(p.errors.is_empty(), "no parse errors: %s" % str(p.errors))
	check(p.handlers.size() == 2, "two handlers")
	check(p.dialogs.has("beppe") and p.dialogs.beppe.options.size() == 2, "dialog with two options")
	check(p.functions.has("help") and p.functions.help.params == ["n"], "function with a parameter")
	var decls := {}
	for d in p.decls:
		decls[d.k + ":" + str(d.get("id", d.get("name", d.get("value", d.get("room", "")))))] = d
	check(decls.has("item:key") and decls["item:key"].props.color == "#ffaa00", "hex colors are not comments")
	var body: Array = p.handlers[0].body
	check(body[0].k == "if" and body[0].branches.size() == 3, "if/elif/else chain")
	check(body[0].branches[0].body[0].text == "Hello! # comment after text is kept", "unquoted text keeps #")
	check(body[0].branches[1].body[0].text == "Rich: {coins}!" and body[0].branches[1].body[0].mood == "happy", "quoted text, mood, comment dropped")
	check(body[1].nowait and body[1].loc.pos == Vector2(400, 300), "walk to coordinates nowait")
	check(body[2].who == "beppe" and body[2].loc.id == "barrel", "walk character to target")
	check(p.dialogs.beppe.options[1].body[0].ref == "beppe.lh", "option ref resolved inside dialog")
	check(p.handlers[1].item == "key" and p.handlers[1].target == "door", "item handler")


func test_parser_say_at() -> void:
	var p := AdvParser.parse("on enter:\n    nina@586, 60: Over here\n    nina(sad): plain\n", "res://t.adv")
	check(p.errors.is_empty(), "say@ parses: %s" % str(p.errors))
	var b: Array = p.handlers[0].body
	check(b[0].k == "say" and b[0].who == "nina" and b[0].at == Vector2(586, 60) and b[0].text == "Over here", "say at a fixed position")
	check(b[1].at == null and b[1].mood == "sad", "plain say has no position")


func test_parser_errors() -> void:
	var bad := "on look x\n  nina: a\non use a:\n  foo bar\n  walk 1\n  if x = 1:\n    nina: b\n  else:\n    nina: c\nnina: hello\n"
	var p := AdvParser.parse(bad, "res://bad.adv")
	var lines := []
	for e in p.errors:
		lines.append(e.line)
	check(1 in lines, "missing colon reported")
	check(4 in lines, "unknown statement reported")
	check(5 in lines, "bad walk reported")
	check(6 in lines, "= in condition reported")
	check(not 8 in lines, "else after a broken if still attaches")
	check(10 in lines, "dialogue at top level reported")


func test_pathfinder() -> void:
	var pf := AdvPathfinder.new()
	var square := PackedVector2Array([Vector2(0, 0), Vector2(400, 0), Vector2(400, 400), Vector2(0, 400)])
	var hole := PackedVector2Array([Vector2(150, 100), Vector2(250, 100), Vector2(250, 400), Vector2(150, 400)])
	pf.build([square], [hole])
	var path := pf.find_path(Vector2(50, 300), Vector2(350, 300))
	check(path.size() >= 3, "path bends around the obstacle (%s)" % str(path))
	for i in range(1, path.size()):
		var mid := (path[i - 1] + path[i]) / 2.0
		check(not Geometry2D.is_point_in_polygon(mid, hole), "segment %d avoids the hole" % i)
	for p in path:
		check(p.y < 100.5 or not (p.x > 150 and p.x < 250), "path points stay out of the hole")
	# direct line when nothing is in the way
	check(pf.find_path(Vector2(50, 50), Vector2(350, 50)).size() == 2, "straight line when visible")
	# points outside are clamped inside
	var c := pf.closest_walkable(Vector2(-100, 200))
	check(pf.is_walkable(c) and c.x < 10, "closest walkable point")
	# separate areas: unreachable until joined
	var island := PackedVector2Array([Vector2(600, 0), Vector2(800, 0), Vector2(800, 200), Vector2(600, 200)])
	pf.build([square, island], [])
	check(pf.find_path(Vector2(50, 50), Vector2(700, 100)).is_empty(), "separate area is unreachable")
	var bridge := PackedVector2Array([Vector2(390, 80), Vector2(610, 80), Vector2(610, 120), Vector2(390, 120)])
	pf.build([square, island, bridge], [])
	check(not pf.find_path(Vector2(50, 300), Vector2(700, 100)).is_empty(), "bridge joins the areas")
	# U shape (concave polygon)
	var u := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 300), Vector2(300, 300), Vector2(300, 0),
		Vector2(400, 0), Vector2(400, 400), Vector2(0, 400)])
	pf.build([u], [])
	var up := pf.find_path(Vector2(50, 50), Vector2(350, 50))
	check(up.size() >= 4, "U-shaped path goes down and up (%s)" % str(up))
