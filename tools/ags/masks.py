"""Turns AGS 8-bit area masks (walkable areas, hotspots, regions, walk-behinds) into polygons.

Each area index becomes a list of outlines traced along pixel borders, simplified with
Ramer-Douglas-Peucker. Outer outlines have positive area, holes negative.
"""


def outlines(mask, value, scale=1, epsilon=1.5, min_area=40):
    """Polygons for pixels == value: [{"outer": [(x, y)...], "holes": [[...]]}, ...]."""
    w, h, px = mask.width, mask.height, mask.pixels
    edges = {}  # start vertex -> list of end vertices (directed, region on the right in screen space)

    def add(a, b):
        edges.setdefault(a, []).append(b)

    for y in range(h):
        row = y * w
        for x in range(w):
            if px[row + x] != value:
                continue
            if y == 0 or px[row - w + x] != value:
                add((x, y), (x + 1, y))
            if x == w - 1 or px[row + x + 1] != value:
                add((x + 1, y), (x + 1, y + 1))
            if y == h - 1 or px[row + w + x] != value:
                add((x + 1, y + 1), (x, y + 1))
            if x == 0 or px[row + x - 1] != value:
                add((x, y + 1), (x, y))
    loops = []
    while edges:
        start = next(iter(edges))
        loop = [start]
        cur = start
        prev_dir = None
        while True:
            outs = edges.get(cur)
            if not outs:
                break
            nxt = outs[0]
            if len(outs) > 1 and prev_dir is not None:
                # at a pinch point keep turning the same way (right turn first)
                for cand in outs:
                    d = (cand[0] - cur[0], cand[1] - cur[1])
                    if d == (-prev_dir[1], prev_dir[0]):
                        nxt = cand
                        break
            outs.remove(nxt)
            if not outs:
                del edges[cur]
            prev_dir = (nxt[0] - cur[0], nxt[1] - cur[1])
            cur = nxt
            if cur == start:
                break
            loop.append(cur)
        if len(loop) >= 4:
            loops.append(loop)
    polys = []
    holes = []
    for loop in loops:
        pts = _collinear(loop)
        a = _area(pts)
        if abs(a) < min_area:
            continue
        pts = rdp_closed(pts, epsilon)
        if len(pts) < 3:
            continue
        pts = [(x * scale, y * scale) for x, y in pts]
        if a > 0:
            polys.append({"outer": pts, "holes": []})
        else:
            holes.append(pts)
    for hole in holes:
        for p in polys:
            if point_in_poly(hole[0], p["outer"]):
                p["holes"].append(hole)
                break
    return polys


def bbox(mask, value):
    xs = ys = None
    w = mask.width
    minx = miny = 10 ** 9
    maxx = maxy = -1
    px = mask.pixels
    for y in range(mask.height):
        row = px[y * w:(y + 1) * w]
        if value not in row:
            continue
        x0 = row.index(value)
        x1 = w - 1 - row[::-1].index(value)
        minx, maxx = min(minx, x0), max(maxx, x1)
        miny, maxy = min(miny, y), max(maxy, y)
    if maxx < 0:
        return None
    return minx, miny, maxx + 1, maxy + 1


def _area(pts):
    s = 0
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        s += x1 * y2 - x2 * y1
    return s / 2.0


def _collinear(pts):
    out = []
    n = len(pts)
    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        if (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) != 0:
            out.append(b)
    return out


def _dist(p, a, b):
    if a == b:
        return ((p[0] - a[0]) ** 2 + (p[1] - a[1]) ** 2) ** 0.5
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / float(dx * dx + dy * dy)))
    qx, qy = a[0] + t * dx, a[1] + t * dy
    return ((p[0] - qx) ** 2 + (p[1] - qy) ** 2) ** 0.5


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    stack = [(0, len(pts) - 1)]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    while stack:
        i, j = stack.pop()
        best, idx = 0.0, -1
        for k in range(i + 1, j):
            d = _dist(pts[k], pts[i], pts[j])
            if d > best:
                best, idx = d, k
        if best > eps and idx != -1:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))
    return [p for p, k in zip(pts, keep) if k]


def rdp_closed(pts, eps):
    if len(pts) < 4:
        return pts
    # split at the point farthest from the first one
    far = max(range(len(pts)), key=lambda k: (pts[k][0] - pts[0][0]) ** 2 + (pts[k][1] - pts[0][1]) ** 2)
    a = rdp(pts[:far + 1], eps)
    b = rdp(pts[far:] + [pts[0]], eps)
    return a[:-1] + b[:-1]


def point_in_poly(p, poly):
    x, y = p
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / float(y2 - y1) + x1:
            inside = not inside
    return inside
