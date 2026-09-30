class_name AdvPathfinder
extends RefCounted
## Shortest paths inside walkable polygons (with holes), using a visibility graph.
##
## Classic adventure-game approach: the shortest path between two points inside a
## polygon only bends at the polygon's concave corners, so the graph nodes are those
## corners (pushed slightly inside) and two nodes are linked when they see each other.
## Deterministic and independent from the physics/navigation servers, so it behaves
## the same in the editor, in game and in headless tests.

const EPS := 2.0

var outers: Array = []   # Array[PackedVector2Array] walkable areas
var holes: Array = []    # Array[PackedVector2Array] blocked areas
var _edges: Array = []   # [Vector2, Vector2]
var _nodes: PackedVector2Array = PackedVector2Array()
var _astar := AStar2D.new()


## [param walkable] and [param blocked] are arrays of polygons in room coordinates.
func build(walkable: Array, blocked: Array) -> void:
	outers.clear()
	holes.clear()
	_edges.clear()
	_nodes.clear()
	_astar.clear()
	# Union overlapping walkable polygons so their shared borders don't block sight.
	for poly in walkable:
		if poly.size() < 3:
			continue
		var cur: PackedVector2Array = poly
		var i := 0
		while i < outers.size():
			var merged := Geometry2D.merge_polygons(outers[i], cur)
			var outs := []
			var inner := []
			for p in merged:
				if Geometry2D.is_polygon_clockwise(p):
					inner.append(p)
				else:
					outs.append(p)
			if outs.size() == 1:
				cur = outs[0]
				holes.append_array(inner)
				outers.remove_at(i)
				i = 0
				continue
			i += 1
		outers.append(cur)
	for poly in blocked:
		if poly.size() >= 3:
			holes.append(poly)
	for poly in outers + holes:
		for j in poly.size():
			_edges.append([poly[j], poly[(j + 1) % poly.size()]])
	# Graph nodes: corners that are concave as seen from the walkable side.
	for poly in outers + holes:
		var n: int = poly.size()
		for j in n:
			var v: Vector2 = poly[j]
			var a: Vector2 = poly[(j - 1 + n) % n]
			var b: Vector2 = poly[(j + 1) % n]
			var bis := (a - v).normalized() + (b - v).normalized()
			if bis.length() < 0.001:
				continue
			bis = bis.normalized()
			if is_walkable(v + bis * EPS):
				continue  # convex corner of the free space: never on a shortest path
			var node := v - bis * EPS
			if is_walkable(node):
				_nodes.append(node)
	for k in _nodes.size():
		_astar.add_point(k, _nodes[k])
	for k in _nodes.size():
		for m in range(k + 1, _nodes.size()):
			if _sees(_nodes[k], _nodes[m]):
				_astar.connect_points(k, m)


func has_area() -> bool:
	return not outers.is_empty()


func is_walkable(p: Vector2) -> bool:
	if outers.is_empty():
		return true
	var inside := false
	for poly in outers:
		if Geometry2D.is_point_in_polygon(p, poly):
			inside = true
			break
	if not inside:
		return false
	for poly in holes:
		if Geometry2D.is_point_in_polygon(p, poly):
			return false
	return true


## The walkable point nearest to [param p].
func closest_walkable(p: Vector2) -> Vector2:
	if is_walkable(p):
		return p
	var best := p
	var best_d := INF
	for e in _edges:
		var c := Geometry2D.get_closest_point_to_segment(p, e[0], e[1])
		var d := c.distance_squared_to(p)
		if d < best_d:
			var dir: Vector2 = (e[1] - e[0]).normalized()
			var normal := Vector2(-dir.y, dir.x)
			for cand in [c + normal * EPS, c - normal * EPS, c + (c - p).normalized() * EPS]:
				if is_walkable(cand):
					best = cand
					best_d = d
					break
	return best


## Path from [param from] to [param to] (both clamped to the walkable area).
## Returns an empty array when [param to] can't be reached.
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var start := closest_walkable(from)
	var goal := closest_walkable(to)
	if _sees(start, goal):
		return PackedVector2Array([start, goal])
	var n := _nodes.size()
	var sid := n
	var gid := n + 1
	_astar.add_point(sid, start)
	_astar.add_point(gid, goal)
	for k in n:
		if _sees(start, _nodes[k]):
			_astar.connect_points(sid, k)
		if _sees(goal, _nodes[k]):
			_astar.connect_points(gid, k)
	var path := _astar.get_point_path(sid, gid)
	_astar.remove_point(sid)
	_astar.remove_point(gid)
	return path


func _sees(p: Vector2, q: Vector2) -> bool:
	if outers.is_empty():
		return true
	if p.distance_squared_to(q) < 0.0001:
		return true
	for e in _edges:
		if Geometry2D.segment_intersects_segment(p, q, e[0], e[1]) != null:
			return false
	return is_walkable((p + q) * 0.5)
