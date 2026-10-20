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
# Trail network (AdvWalkPath): when set, walking follows these segments instead of areas.
const SNAP := 4.0        # vertices closer than this are the same junction
const TRAIL_WIDTH := 8.0 # how far from a trail still counts as on it
var _segs: Array = []    # [Vector2 a, Vector2 b, int id_a, int id_b]
var _seg_group := PackedInt32Array()   # connected part of the network of each segment


## [param walkable] and [param blocked] are arrays of polygons in room coordinates.
func build(walkable: Array, blocked: Array) -> void:
	outers.clear()
	holes.clear()
	_edges.clear()
	_nodes.clear()
	_astar.clear()
	_segs.clear()
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


## Builds a trail network from polylines ([param lines], room coordinates): lines are split
## where they cross or where a vertex of one touches another, and joined there.
func build_network(lines: Array) -> void:
	build([], [])
	var raw := []
	for line in lines:
		for j in range(line.size() - 1):
			if line[j].distance_to(line[j + 1]) > 0.01:
				raw.append([line[j], line[j + 1]])
	var ids := {}   # Vector2i cell -> Array of point ids, to merge close vertices
	for k in raw.size():
		var a: Vector2 = raw[k][0]
		var b: Vector2 = raw[k][1]
		var ts := [0.0, 1.0]
		for m in raw.size():
			if m == k:
				continue
			var c: Vector2 = raw[m][0]
			var d: Vector2 = raw[m][1]
			var x = Geometry2D.segment_intersects_segment(a, b, c, d)
			if x != null:
				ts.append(_param(a, b, x))
			for q in [c, d]:
				var on := Geometry2D.get_closest_point_to_segment(q, a, b)
				if on.distance_to(q) <= SNAP:
					ts.append(_param(a, b, on))
		ts.sort()
		var prev := _point_id(a, ids)
		var last_t := 0.0
		for t in ts:
			if t - last_t < 0.0001 and t < 1.0:
				continue
			var id := _point_id(a.lerp(b, t), ids)
			if id != prev:
				_segs.append([_astar.get_point_position(prev), _astar.get_point_position(id), prev, id])
				_astar.connect_points(prev, id)
			prev = id
			last_t = t
	# connected parts, so an unreachable click walks to the nearest reachable point
	var group := {}
	_seg_group.resize(_segs.size())
	var g := 0
	for k in _segs.size():
		var root: int = _segs[k][2]
		if group.has(root):
			continue
		var todo := [root]
		group[root] = g
		while not todo.is_empty():
			var id: int = todo.pop_back()
			for nb in _astar.get_point_connections(id):
				if not group.has(nb):
					group[nb] = g
					todo.append(nb)
		g += 1
	for k in _segs.size():
		_seg_group[k] = group[_segs[k][2]]


func _param(a: Vector2, b: Vector2, p: Vector2) -> float:
	var d := b - a
	return clampf((p - a).dot(d) / d.length_squared(), 0.0, 1.0)


func _point_id(p: Vector2, ids: Dictionary) -> int:
	var cell := Vector2i(floori(p.x / SNAP), floori(p.y / SNAP))
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for id in ids.get(cell + Vector2i(dx, dy), []):
				if _astar.get_point_position(id).distance_to(p) <= SNAP:
					return id
	var id := _astar.get_available_point_id()
	_astar.add_point(id, p)
	if not ids.has(cell):
		ids[cell] = []
	ids[cell].append(id)
	return id


## The trail segment nearest to [param p]: [index, closest point].
func _nearest_seg(p: Vector2, only_group := -1) -> Array:
	var best := -1
	var best_p := p
	var best_d := INF
	for k in _segs.size():
		if only_group >= 0 and _seg_group[k] != only_group:
			continue
		var c := Geometry2D.get_closest_point_to_segment(p, _segs[k][0], _segs[k][1])
		var d := c.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = k
			best_p = c
	return [best, best_p]


func has_area() -> bool:
	return not outers.is_empty() or not _segs.is_empty()


func is_walkable(p: Vector2) -> bool:
	if not _segs.is_empty():
		return _nearest_seg(p)[1].distance_to(p) <= TRAIL_WIDTH
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
	if not _segs.is_empty():
		return _nearest_seg(p)[1]
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
	if not _segs.is_empty():
		return _find_trail_path(from, to)
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


func _find_trail_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var s := _nearest_seg(from)
	# a goal in another part of the network: get as close as possible (a maze's dead end)
	var g := _nearest_seg(to, _seg_group[s[0]])
	var start: Vector2 = s[1]
	var goal: Vector2 = g[1]
	if s[0] == g[0]:
		return PackedVector2Array([start, goal])
	var sid := _astar.get_available_point_id()
	_astar.add_point(sid, start)
	var gid := _astar.get_available_point_id()
	_astar.add_point(gid, goal)
	for pair in [[sid, _segs[s[0]]], [gid, _segs[g[0]]]]:
		_astar.connect_points(pair[0], pair[1][2])
		_astar.connect_points(pair[0], pair[1][3])
	var path := _astar.get_point_path(sid, gid)
	_astar.remove_point(sid)
	_astar.remove_point(gid)
	return path
