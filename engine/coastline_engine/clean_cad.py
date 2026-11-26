"""Clean CAD from a simulated heightfield (K12 export): a B-rep solid with real planes, arcs and
NURBS surfaces instead of a voxel mesh.

1. Levels: the flat depths the cuts left (floors, faces, the stock top), from the cells whose
   neighbours are at the same height, clustered within `flat_tol`.
2. Every cell goes to its level when it's within `flat_tol` of one (micron cusps and steps are
   cleaned away); what's left is sloped (3D finishing). Small sloped patches snap to a level too.
3. For each level below the top: the outline of everything cut at least that deep, traced
   along the cell edges, smoothed through the edge midpoints, simplified and fitted with lines
   and arcs (least-squares arcs, `fit_outline`), and cut out of the stock block as a prism from that level up.
4. Each sloped patch: a B-spline surface fitted to its heights, swept up to a solid and limited
   to the patch's outline, cut out the same way.
5. One boolean cut, then coplanar faces merged.
"""
from __future__ import annotations

import math
from collections import deque

import numpy as np



# MARK: Classifying the cells

def find_levels(h: np.ndarray, top: float, cell: float, flat_tol: float, min_area: float, gap: float = 0.05) -> list[float]:
    """The flat depths, deepest last; the top is always one."""
    pad = np.pad(h, 1, mode="edge")
    d = np.maximum.reduce([abs(pad[1:-1, 1:-1] - pad[:-2, 1:-1]), abs(pad[1:-1, 1:-1] - pad[2:, 1:-1]),
                           abs(pad[1:-1, 1:-1] - pad[1:-1, :-2]), abs(pad[1:-1, 1:-1] - pad[1:-1, 2:])])
    flat = h[d < 0.002]
    levels: list[float] = [top]
    if flat.size:
        q = np.round(flat / 0.001) * 0.001
        vals, counts = np.unique(q, return_counts=True)
        order = np.argsort(-counts)
        min_cells = max(min_area / (cell * cell), 4)
        for i in order:
            if counts[i] < min_cells:
                break
            z = float(vals[i])
            if all(abs(z - l) > max(gap, flat_tol) for l in levels):
                levels.append(z)
    return sorted(levels, reverse=True)


def classify(h: np.ndarray, levels: list[float], flat_tol: float) -> tuple[np.ndarray, np.ndarray]:
    """Per cell: the cleaned height and whether it's sloped. A cell is at a level when it's within
    `flat_tol` of it and its neighbours are too (so a slope crossing a level's depth stays a slope)."""
    lv = np.array(levels)
    idx = np.argmin(abs(h[..., None] - lv[None, None, :]), axis=2)
    near = lv[idx]
    pad = np.pad(h, 1, mode="edge")
    steep = np.maximum.reduce([abs(pad[1:-1, 1:-1] - pad[:-2, 1:-1]), abs(pad[1:-1, 1:-1] - pad[2:, 1:-1]),
                               abs(pad[1:-1, 1:-1] - pad[1:-1, :-2]), abs(pad[1:-1, 1:-1] - pad[1:-1, 2:])])
    # A wall's foot is next to a much higher cell: that's an edge, not a slope.
    level_neighbours = np.maximum.reduce([abs(pad[1:-1, 1:-1] - pad[:-2, 1:-1]) > 0.2, abs(pad[1:-1, 1:-1] - pad[2:, 1:-1]) > 0.2,
                                          abs(pad[1:-1, 1:-1] - pad[1:-1, :-2]) > 0.2, abs(pad[1:-1, 1:-1] - pad[1:-1, 2:]) > 0.2])
    at = (abs(h - near) <= flat_tol) & ((steep <= flat_tol) | level_neighbours)
    eff = np.where(at, near, h)
    return eff, ~at


def _erode(m: np.ndarray) -> np.ndarray:
    p = np.pad(m, 1, mode="edge")
    return p[1:-1, 1:-1] & p[:-2, 1:-1] & p[2:, 1:-1] & p[1:-1, :-2] & p[1:-1, 2:]


def _dilate(m: np.ndarray) -> np.ndarray:
    p = np.pad(m, 1, mode="edge")
    return p[1:-1, 1:-1] | p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]


def open_mask(m: np.ndarray, n: int) -> np.ndarray:
    """Morphological opening: anything thinner than about 2n cells goes (hairline grooves)."""
    out = m
    for _ in range(n):
        out = _erode(out)
    for _ in range(n):
        out = _dilate(out)
    return out & m | (out & ~m)  # never grows past the original by more than it shrank


def components(mask: np.ndarray) -> list[np.ndarray]:
    """4-connected components of a mask, as arrays of (row, col)."""
    seen = np.zeros_like(mask, dtype=bool)
    rows, cols = mask.shape
    out = []
    for r0, c0 in zip(*np.nonzero(mask)):
        if seen[r0, c0]:
            continue
        q = deque([(r0, c0)])
        seen[r0, c0] = True
        cells = []
        while q:
            r, c = q.popleft()
            cells.append((r, c))
            for rr, cc in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
                if 0 <= rr < rows and 0 <= cc < cols and mask[rr, cc] and not seen[rr, cc]:
                    seen[rr, cc] = True
                    q.append((rr, cc))
        out.append(np.array(cells))
    return out


# MARK: Outlines

def trace_loops(mask: np.ndarray) -> list[np.ndarray]:
    """Closed loops around a mask's cells in grid-corner units (x = col, y = row), the mask on the
    left: outer loops counter-clockwise, holes clockwise. Saddles turn left."""
    m = np.pad(mask, 1, constant_values=False)
    r, c = np.nonzero(m)
    edges = []
    below, above, left, right = ~m[r - 1, c], ~m[r + 1, c], ~m[r, c - 1], ~m[r, c + 1]
    # Corners of padded cell (r, c): (c, r) … (c + 1, r + 1).
    edges += [((cc, rr), (cc + 1, rr)) for rr, cc in zip(r[below], c[below])]
    edges += [((cc + 1, rr), (cc + 1, rr + 1)) for rr, cc in zip(r[right], c[right])]
    edges += [((cc + 1, rr + 1), (cc, rr + 1)) for rr, cc in zip(r[above], c[above])]
    edges += [((cc, rr + 1), (cc, rr)) for rr, cc in zip(r[left], c[left])]
    out_of: dict[tuple, list] = {}
    for a, b in edges:
        out_of.setdefault(a, []).append(b)
    loops = []
    while out_of:
        start = next(iter(out_of))
        loop = [start]
        prev = None
        cur = start
        while True:
            nxt = out_of.get(cur)
            if not nxt:
                break
            if len(nxt) > 1 and prev is not None:
                # Turn left first: the cross product of the incoming and outgoing directions.
                din = (cur[0] - prev[0], cur[1] - prev[1])
                nxt.sort(key=lambda p: -(din[0] * (p[1] - cur[1]) - din[1] * (p[0] - cur[0])))
            b = nxt.pop(0)
            if not nxt:
                del out_of[cur]
            prev, cur = cur, b
            if cur == start:
                break
            loop.append(cur)
        if len(loop) >= 4:
            # Back to unpadded grid-corner units.
            loops.append(np.array(loop, dtype=float) - 1.0)
    return loops


def signed_area(p: np.ndarray) -> float:
    x, y = p[:, 0], p[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def simplify(p: np.ndarray, tol: float) -> np.ndarray:
    """Douglas-Peucker on a closed loop (split at its two farthest points)."""
    def dp(pts):
        if len(pts) < 3:
            return pts
        a, b = pts[0], pts[-1]
        ab = b - a
        n = np.hypot(*ab)
        d = np.abs(np.cross(ab, pts - a)) / n if n > 1e-12 else np.hypot(*(pts - a).T)
        i = int(np.argmax(d))
        if d[i] <= tol:
            return np.array([a, b])
        return np.vstack([dp(pts[: i + 1])[:-1], dp(pts[i:])])
    far = int(np.argmax(np.hypot(*(p - p[0]).T)))
    first = dp(p[: far + 1])
    second = dp(np.vstack([p[far:], p[:1]]))
    return np.vstack([first[:-1], second[:-1]])


def _dp_open(pts: np.ndarray, tol: float) -> np.ndarray:
    if len(pts) < 3:
        return pts
    a, b = pts[0], pts[-1]
    ab = b - a
    n = np.hypot(*ab)
    d = np.abs(np.cross(ab, pts - a)) / n if n > 1e-12 else np.hypot(*(pts - a).T)
    i = int(np.argmax(d))
    if d[i] <= tol:
        return np.array([a, b])
    return np.vstack([_dp_open(pts[: i + 1], tol)[:-1], _dp_open(pts[i:], tol)])


def _dp_indices(pts: np.ndarray, tol: float, lo: int, hi: int, out: list[int]) -> None:
    """Douglas-Peucker on pts[lo..hi], appending kept indices (lo excluded, hi included)."""
    if hi - lo < 2:
        out.append(hi)
        return
    a, b = pts[lo], pts[hi]
    ab = b - a
    n = np.hypot(*ab)
    seg = pts[lo + 1:hi]
    d = np.abs(np.cross(ab, seg - a)) / n if n > 1e-12 else np.hypot(*(seg - a).T)
    k = int(np.argmax(d))
    if d[k] <= tol:
        out.append(hi)
        return
    _dp_indices(pts, tol, lo, lo + 1 + k, out)
    _dp_indices(pts, tol, lo + 1 + k, hi, out)


def _circle_fit(p: np.ndarray):
    """Least-squares circle (Kasa): centre, radius."""
    x, y = p[:, 0], p[:, 1]
    a = np.c_[x, y, np.ones_like(x)]
    b = x * x + y * y
    try:
        sol, *_ = np.linalg.lstsq(a, b, rcond=None)
    except np.linalg.LinAlgError:
        return None
    cx, cy = sol[0] / 2, sol[1] / 2
    r2 = sol[2] + cx * cx + cy * cy
    if r2 <= 0:
        return None
    return np.array([cx, cy]), math.sqrt(r2)


def fit_outline(dense: np.ndarray, tol: float) -> tuple[np.ndarray, list]:
    """A closed traced outline as lines and arcs within tol: the start point and the segments
    [("line", end) | ("arc", end, centre, cw)]. Corners come from Douglas-Peucker; runs of corners
    that sit on one circle (least squares over all the points between) become one arc."""
    n = len(dense)
    # A whole circle (a round pocket or boss): two halves on one centre.
    whole = _circle_fit(dense)
    if whole is not None:
        c, r = whole
        if 0.2 <= r <= 500 and np.abs(np.hypot(*(dense - c).T) - r).max() <= tol:
            ccw = signed_area(dense) > 0
            a0 = math.atan2(dense[0][1] - c[1], dense[0][0] - c[0])
            p0 = c + r * np.array([math.cos(a0), math.sin(a0)])
            p1 = c + r * np.array([math.cos(a0 + math.pi), math.sin(a0 + math.pi)])
            return p0, [("arc", p1, c, not ccw), ("arc", p0, c, not ccw)]
    # Start at the sharpest turn so no arc is cut in two.
    v_prev = dense - np.roll(dense, 1, axis=0)
    v_next = np.roll(dense, -1, axis=0) - dense
    turn = np.abs(np.arctan2(np.cross(v_prev, v_next), np.einsum("ij,ij->i", v_prev, v_next)))
    s0 = int(np.argmax(turn))
    pts = np.vstack([np.roll(dense, -s0, axis=0), np.roll(dense, -s0, axis=0)[:1]])
    keep: list[int] = [0]
    _dp_indices(pts, tol, 0, len(pts) - 1, keep)
    def arc_through(i: int, j: int):
        run = pts[keep[i]:keep[j] + 1]
        fit = _circle_fit(run)
        if fit is None:
            return None
        c, r = fit
        if r < 0.2 or r > 500 or np.abs(np.hypot(*(run - c).T) - r).max() > tol:
            return None
        v = run - c
        cross = v[:-1, 0] * v[1:, 1] - v[:-1, 1] * v[1:, 0]
        if not (np.all(cross > -1e-9) or np.all(cross < 1e-9)):
            return None
        sweep = abs(np.arctan2(cross, np.einsum("ij,ij->i", v[:-1], v[1:])).sum())
        if sweep > 1.8 * math.pi or sweep < 0.15:
            return None
        return c, bool(cross.sum() < 0)

    segs = []
    i = 0
    while i < len(keep) - 1:
        # The longest arc from here (searching down from the far end), else a line.
        found = None
        for j in range(len(keep) - 1, i + 1, -1):
            fit = arc_through(i, j)
            if fit is not None:
                found = (j, *fit)
                break
        if found is not None:
            j, c, cw = found
            segs.append(("arc", pts[keep[j]], c, cw))
            i = j
        else:
            segs.append(("line", pts[keep[i + 1]]))
            i += 1
    return pts[0], segs


def smooth_loop(corners: np.ndarray) -> np.ndarray:
    """The staircase's edge midpoints: 45° steps become straight lines."""
    return (corners + np.roll(corners, -1, axis=0)) / 2


# MARK: Snapping to the part

# The part's vertical walls in the work frame while a build with the part runs (build_with_part):
# circles (cx, cy, r, seam angle) and lines (px, py, dx, dy). A fitted outline that runs along one of them
# takes the part's exact geometry, so the leftover's wall and the part's wall coincide exactly and
# merge, instead of leaving faces a few microns wide between them.
_SNAP: dict | None = None
SNAP_TOL = 0.04


def part_walls(shape) -> dict:
    """The part's vertical cylinders and planes, as circles and lines in plan."""
    from OCP.BRep import BRep_Tool
    from OCP.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
    from OCP.GeomAdaptor import GeomAdaptor_Surface
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS

    circles, lines = [], []
    ex = TopExp_Explorer(shape, TopAbs_FACE)
    while ex.More():
        s = GeomAdaptor_Surface(BRep_Tool.Surface_s(TopoDS.Face(ex.Current())))
        if s.GetType() == GeomAbs_Cylinder:
            c = s.Cylinder()
            d, o = c.Axis().Direction(), c.Axis().Location()
            if abs(abs(d.Z()) - 1) < 1e-6:
                x = c.Position().XDirection()  # the seam (u = 0)
                circles.append((o.X(), o.Y(), c.Radius(), math.atan2(x.Y(), x.X())))
        elif s.GetType() == GeomAbs_Plane:
            pl = s.Plane()
            n, o = pl.Axis().Direction(), pl.Location()
            if abs(n.Z()) < 1e-6:
                k = math.hypot(n.X(), n.Y())
                lines.append((o.X(), o.Y(), -n.Y() / k, n.X() / k))
        ex.Next()
    return {"circles": np.array(circles).reshape(-1, 4), "lines": np.array(lines).reshape(-1, 4)}


def _snap_outline(start: np.ndarray, segs: list) -> tuple[np.ndarray, list]:
    """Moves arcs onto the part's circles and lines onto its wall lines where they run within
    SNAP_TOL of them; corners go to where the snapped neighbours meet."""
    if _SNAP is None or not segs:
        return start, segs
    circles, lines = _SNAP["circles"], _SNAP["lines"]
    pts = [np.asarray(start, float)] + [np.asarray(sg[1], float) for sg in segs]
    n = len(segs)
    cons = []  # per segment: ("c", cx, cy, r) | ("l", px, py, dx, dy) | None
    seam = 0.0
    for i, sg in enumerate(segs):
        a, b = pts[i], pts[i + 1]
        con = None
        if sg[0] == "arc" and len(circles):
            c = np.asarray(sg[2], float)
            r = (np.hypot(*(a - c)) + np.hypot(*(b - c))) / 2
            dev = np.hypot(circles[:, 0] - c[0], circles[:, 1] - c[1]) + np.abs(circles[:, 2] - r)
            k = int(np.argmin(dev))
            if dev[k] <= SNAP_TOL:
                con = ("c", *circles[k][:3])
                seam = float(circles[k][3])
        elif sg[0] == "line" and len(lines) and np.hypot(*(b - a)) > 1e-6:
            u = (b - a) / np.hypot(*(b - a))
            par = np.abs(lines[:, 2] * u[1] - lines[:, 3] * u[0]) < 0.02
            da = np.abs((a[0] - lines[:, 0]) * lines[:, 3] - (a[1] - lines[:, 1]) * lines[:, 2])
            db = np.abs((b[0] - lines[:, 0]) * lines[:, 3] - (b[1] - lines[:, 1]) * lines[:, 2])
            ok = par & (da <= SNAP_TOL) & (db <= SNAP_TOL)
            if ok.any():
                k = int(np.argmin(np.where(ok, da + db, np.inf)))
                con = ("l", *lines[k])
        cons.append(con)
    if not any(cons):
        return start, segs
    # A whole circle on a part circle starts where the part's own circle does, so the two
    # circles merge into one closed edge (their seams on one spot).
    if n == 2 and all(sg[0] == "arc" for sg in segs) and cons[0] is not None and cons[0] == cons[1]:
        c, r = np.array(cons[0][1:3]), cons[0][3]
        p0 = c + r * np.array([math.cos(seam), math.sin(seam)])
        p1 = c - (p0 - c)
        return p0, [("arc", p1, c, segs[0][3]), ("arc", p0, c, segs[1][3])]

    def project(p, c):
        if c[0] == "c":
            v = p - c[1:3]
            return c[1:3] + v * (c[3] / max(np.hypot(*v), 1e-12))
        o, d = np.array(c[1:3]), np.array(c[3:5])
        return o + d * np.dot(p - o, d)

    def meet(p, c1, c2):
        """The point on both that's nearest p, if there is one near."""
        cand = []
        if c1[0] == "l" and c2[0] == "l":
            o1, d1, o2, d2 = np.array(c1[1:3]), np.array(c1[3:5]), np.array(c2[1:3]), np.array(c2[3:5])
            den = d1[0] * d2[1] - d1[1] * d2[0]
            if abs(den) > 1e-9:
                t = ((o2 - o1)[0] * d2[1] - (o2 - o1)[1] * d2[0]) / den
                cand.append(o1 + t * d1)
        elif c1[0] == "c" and c2[0] == "c":
            p1, r1, p2, r2 = np.array(c1[1:3]), c1[3], np.array(c2[1:3]), c2[3]
            dd = np.hypot(*(p2 - p1))
            if dd < 1e-9:
                return project(p, c1) if abs(r1 - r2) < 1e-9 else None
            a = (r1 * r1 - r2 * r2 + dd * dd) / (2 * dd)
            hh = r1 * r1 - a * a
            if hh >= 0:
                m = p1 + a * (p2 - p1) / dd
                off = math.sqrt(hh) * np.array([-(p2 - p1)[1], (p2 - p1)[0]]) / dd
                cand += [m + off, m - off]
        else:
            ci, li = (c1, c2) if c1[0] == "c" else (c2, c1)
            cc, r = np.array(ci[1:3]), ci[3]
            o, d = np.array(li[1:3]), np.array(li[3:5])
            t0 = np.dot(cc - o, d)
            foot = o + t0 * d
            q = r * r - np.dot(foot - cc, foot - cc)
            if q >= 0:
                cand += [foot + math.sqrt(q) * d, foot - math.sqrt(q) * d]
        if not cand:
            return None
        best = min(cand, key=lambda c: np.hypot(*(c - p)))
        return best if np.hypot(*(best - p)) <= 3 * SNAP_TOL else None

    closed = np.hypot(*(pts[-1] - pts[0])) < 1e-6
    out = [p.copy() for p in pts]
    for i in range(n + 1):
        before = cons[i - 1] if i > 0 else (cons[-1] if closed else None)
        after = cons[i] if i < n else (cons[0] if closed else None)
        p = pts[i]
        if before and after:
            q = meet(p, before, after)
            out[i] = q if q is not None else project(p, after if i < n else before)
        elif before or after:
            out[i] = project(p, before or after)
    if closed:
        out[-1] = out[0]
    new = []
    for i, sg in enumerate(segs):
        if sg[0] == "arc" and cons[i] is not None:
            new.append(("arc", out[i + 1], np.array(cons[i][1:3]), sg[3]))
        else:
            new.append((sg[0], out[i + 1], *sg[2:]))
    return out[0], new


# MARK: Building

def _wire(points_xy: np.ndarray, z: float, tol: float):
    """A closed wire through the loop: lines and arcs where they fit within tol."""
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire
    from OCP.GC import GC_MakeArcOfCircle
    from OCP.gp import gp_Pnt

    start, segs = _snap_outline(*fit_outline(points_xy, tol))
    pts = np.array([start])
    mk = BRepBuilderAPI_MakeWire()
    cur = pts[0]
    for s in segs:
        end = np.asarray(s[1], float)
        if np.hypot(*(end - cur)) < 1e-6:
            continue
        p1, p2 = gp_Pnt(float(cur[0]), float(cur[1]), z), gp_Pnt(float(end[0]), float(end[1]), z)
        if s[0] == "arc":
            centre, cw = np.asarray(s[2], float), bool(s[3])
            a1 = math.atan2(cur[1] - centre[1], cur[0] - centre[0])
            a2 = math.atan2(end[1] - centre[1], end[0] - centre[0])
            sweep = a2 - a1
            if cw:
                while sweep >= 0:
                    sweep -= 2 * math.pi
            else:
                while sweep <= 0:
                    sweep += 2 * math.pi
            rad = (np.hypot(*(cur - centre)) + np.hypot(*(end - centre))) / 2
            am = a1 + sweep / 2
            pm = gp_Pnt(float(centre[0] + rad * math.cos(am)), float(centre[1] + rad * math.sin(am)), z)
            try:
                arc = GC_MakeArcOfCircle(p1, pm, p2)
                if arc.IsDone():
                    mk.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge())
                    cur = end
                    continue
            except Exception:
                pass
        mk.Add(BRepBuilderAPI_MakeEdge(p1, p2).Edge())
        cur = end
    return mk.Wire() if mk.IsDone() else None


def _simple_prism(loop: np.ndarray, z0: float, z1: float, tol: float):
    """A prism over one loop (taken counter-clockwise), or None."""
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepPrimAPI import BRepPrimAPI_MakePrism
    from OCP.gp import gp_Vec

    if signed_area(loop) < 0:
        loop = loop[::-1]
    w = _wire(loop, z0, tol)
    if w is None:
        return None
    mk = BRepBuilderAPI_MakeFace(w, True)
    if not mk.IsDone():
        return None
    p = BRepPrimAPI_MakePrism(mk.Face(), gp_Vec(0, 0, z1 - z0)).Shape()
    return p if BRepCheck_Analyzer(p).IsValid() else None


def _region_prism(loops_world: list[np.ndarray], z0: float, z1: float, tol: float):
    """Prisms from z0 up to z1 over a mask's loops: each outer loop's prism with the prisms of the
    holes inside it cut away (one face with holes is fragile where outlines run close)."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.BRepCheck import BRepCheck_Analyzer

    outers = [l for l in loops_world if signed_area(l) > 0]
    holes = [l for l in loops_world if signed_area(l) < 0]
    solids = []
    for o in outers:
        prism = _simple_prism(o, z0, z1, tol)
        if prism is None:
            continue
        for hl in holes:
            if not _inside(hl[0], o):
                continue
            hp = _simple_prism(hl, z0 - 0.5, z1 + 0.5, tol)  # taller: no coplanar caps
            if hp is None:
                continue
            cut = BRepAlgoAPI_Cut(prism, hp)
            cut.SetFuzzyValue(1e-4)
            cut.Build()
            if cut.IsDone() and BRepCheck_Analyzer(cut.Shape()).IsValid():
                prism = cut.Shape()
        solids.append(prism)
    return solids


def _inside(p, poly) -> bool:
    x, y = p
    xs, ys = poly[:, 0], poly[:, 1]
    xj, yj = np.roll(xs, 1), np.roll(ys, 1)
    hit = ((ys > y) != (yj > y)) & (x < (xj - xs) * (y - ys) / np.where(yj - ys == 0, 1e-12, yj - ys) + xs)
    return bool(np.count_nonzero(hit) % 2)


def _extend(sub: np.ndarray, inside: np.ndarray) -> np.ndarray:
    """Heights outside the patch filled from its edge outward (no cliff for the fit to chase)."""
    out = np.where(inside, sub, np.nan)
    known = inside.copy()
    for _ in range(max(sub.shape)):
        if known.all():
            break
        pad = np.pad(out, 1, constant_values=np.nan)
        nb = np.stack([pad[:-2, 1:-1], pad[2:, 1:-1], pad[1:-1, :-2], pad[1:-1, 2:]])
        cnt = np.sum(~np.isnan(nb), axis=0)
        fill = (~known) & (cnt > 0)
        if not fill.any():
            break
        out[fill] = (np.nansum(nb, axis=0) / np.maximum(cnt, 1))[fill]
        known |= fill
    return np.where(np.isnan(out), np.nanmean(out), out)


def _fit_surface(eff: np.ndarray, inside: np.ndarray, rows: slice, cols: slice, x0: float, y0: float, cell: float):
    """A light cubic B-spline surface over the patch (its heights extended past its edge), and its
    worst deviation from the patch's own heights, mm."""
    from OCP.collections import Array2_gp_Pnt
    from OCP.GeomAbs import GeomAbs_C2
    from OCP.GeomAPI import GeomAPI_PointsToBSplineSurface
    from OCP.gp import gp_Pnt

    sub = _extend(eff[rows, cols], inside[rows, cols])
    nr, nc = sub.shape
    # About 40 × 40 points, cubic: smooth, and fast in the booleans.
    step = max(1, int(math.ceil(max(nr, nc) / 40)))
    ri = list(range(0, nr, step)) + ([nr - 1] if (nr - 1) % step else [])
    ci = list(range(0, nc, step)) + ([nc - 1] if (nc - 1) % step else [])
    if len(ri) < 4 or len(ci) < 4:
        return None, math.inf
    arr = Array2_gp_Pnt(1, len(ci), 1, len(ri))
    for a, c in enumerate(ci):
        for b, r in enumerate(ri):
            arr.SetValue(a + 1, b + 1, gp_Pnt(x0 + (cols.start + c) * cell, y0 + (rows.start + r) * cell, float(sub[r, c])))
    try:
        surf = GeomAPI_PointsToBSplineSurface(arr, 3, 3, GeomAbs_C2, max(cell * 0.6, 0.01)).Surface()
    except Exception:
        return None, math.inf
    # The surface is a graph over the grid (u ~ x, v ~ y): compare it with the patch's cells.
    pr, pc = np.nonzero(inside[rows, cols])
    pick = np.linspace(0, len(pr) - 1, min(len(pr), 400)).astype(int)
    u0, u1, v0, v1 = surf.Bounds()
    err = 0.0
    for k in pick:
        r, c = pr[k], pc[k]
        u = u0 + (u1 - u0) * (c / max(nc - 1, 1))
        v = v0 + (v1 - v0) * (r / max(nr - 1, 1))
        err = max(err, abs(surf.Value(u, v).Z() - float(sub[r, c])))
    return surf, err


def _surface_cutter(surf, footprint):
    """The part of the patch's footprint prism above its surface."""
    from OCP.BRep import BRep_Builder
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Splitter
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    from OCP.BRepGProp import BRepGProp
    from OCP.collections import List_TopoDS_Shape
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    from OCP.GProp import GProp_GProps
    from OCP.gp import gp_Pnt
    from OCP.TopAbs import TopAbs_SOLID
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS_Compound

    face = BRepBuilderAPI_MakeFace(surf, 1e-6).Face()
    split = BRepAlgoAPI_Splitter()
    args, tools = List_TopoDS_Shape(), List_TopoDS_Shape()
    args.Append(footprint)
    tools.Append(face)
    split.SetArguments(args)
    split.SetTools(tools)
    split.Build()
    if not split.IsDone():
        return None
    builder, comp = BRep_Builder(), TopoDS_Compound()
    builder.MakeCompound(comp)
    kept = 0
    ex = TopExp_Explorer(split.Shape(), TopAbs_SOLID)
    while ex.More():
        g = GProp_GProps()
        BRepGProp.VolumeProperties_s(ex.Current(), g)
        cg = g.CentreOfMass()
        proj = GeomAPI_ProjectPointOnSurf(gp_Pnt(cg.X(), cg.Y(), cg.Z()), surf)
        if g.Mass() > 1e-6 and proj.NbPoints() and cg.Z() > surf.Value(*proj.LowerDistanceParameters()).Z():
            builder.Add(comp, ex.Current())
            kept += 1
        ex.Next()
    return comp if kept else None


def build(heights: np.ndarray, origin: tuple[float, float], cell: float, top: float, bottom: float,
          flat_tol: float = 0.01, min_area: float = 1.0, gap: float = 0.05, surface_tol: float = 0.03,
          min_rise: float = 0.3, fit_share: float = 0.08) -> tuple[object, dict]:
    """The cleaned solid and what went into it. heights[row, col], cell centres at
    origin + (col, row) · cell."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.gp import gp_Pnt
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
    from OCP.BRep import BRep_Builder
    from OCP.TopoDS import TopoDS_Compound

    h = np.minimum(np.asarray(heights, float), top)
    rows, cols = h.shape
    x0, y0 = origin
    corner_x, corner_y = x0 - cell / 2, y0 - cell / 2
    levels = find_levels(h, top, cell, flat_tol, min_area, gap)
    eff, sloped = classify(h, levels, flat_tol)
    # Small or thin sloped patches snap to their nearest level (clean, simple geometry).
    min_cells = max(min_area / (cell * cell), 9)
    patches = []  # (cells, surface)
    rejected = 0
    lv = np.array(levels)

    def snap(rr, cc):
        eff[rr, cc] = lv[np.argmin(abs(h[rr, cc][:, None] - lv[None, :]), axis=1)]

    for comp in components(sloped):
        rr, cc = comp[:, 0], comp[:, 1]
        thin = min(rr.max() - rr.min(), cc.max() - cc.min()) < 3
        if len(comp) < min_cells or thin:
            snap(rr, cc)
            continue
        # A smooth surface only where one fits (a finished curve): a patch that rises less than
        # `min_rise`, or that a cubic can't follow within `fit_share` of its rise (a half-bored
        # spiral ramp), becomes steps at the levels instead.
        fmask = np.zeros_like(sloped)
        fmask[rr, cc] = True
        r0, r1 = max(rr.min() - 6, 0), min(rr.max() + 7, rows)
        c0, c1 = max(cc.min() - 6, 0), min(cc.max() + 7, cols)
        rise = float(np.ptp(h[rr, cc]))
        if rise < min_rise:  # a 0.1 mm transition between nearby levels, not a curve
            snap(rr, cc)
            continue
        surf, err = _fit_surface(eff, fmask, slice(r0, r1), slice(c0, c1), x0, y0, cell)
        if surf is None or err > max(surface_tol, fit_share * rise):
            # One flat step at the level nearest its middle height, not a staircase of cells.
            eff[rr, cc] = lv[int(np.argmin(abs(lv - float(np.median(h[rr, cc])))))]
            rejected += 1
        else:
            patches.append((comp, surf))

    def world(loop_units: np.ndarray) -> np.ndarray:
        return np.c_[corner_x + loop_units[:, 0] * cell, corner_y + loop_units[:, 1] * cell]

    fit_tol = max(cell * 0.6, 0.005)
    z_above = top + 1.0
    # The sloped patches are cut by their surfaces; the levels' outlines leave them out (no two
    # nearly identical walls meeting as slivers). Each patch's footprint reaches one cell past it.
    in_patch = np.zeros_like(sloped)
    for comp, _ in patches:
        in_patch[comp[:, 0], comp[:, 1]] = True
    tools = []
    for z in levels:
        if z >= top - 1e-9:
            continue
        mask = (eff <= z + 1e-6) & ~in_patch
        mask = open_mask(mask, 2)  # no hairline grooves or slivers
        if not mask.any():
            continue
        # Past the stock's sides: a pocket that reaches the edge cuts clean through it.
        loops = [world(smooth_loop(l)) for l in trace_loops(np.pad(mask, 1, mode="edge"))]
        loops = [l - cell for l in loops]
        loops = [l for l in loops if abs(signed_area(l)) >= min_area]  # specks are noise
        tools += _region_prism(loops, z, z_above, fit_tol)
    for comp, surf in patches:
        rr, cc = comp[:, 0], comp[:, 1]
        fmask = np.zeros_like(sloped)
        fmask[rr, cc] = True
        grown = fmask.copy()
        grown[1:, :] |= fmask[:-1, :]
        grown[:-1, :] |= fmask[1:, :]
        grown[:, 1:] |= fmask[:, :-1]
        grown[:, :-1] |= fmask[:, 1:]
        loops = [world(smooth_loop(l)) for l in trace_loops(grown)]
        # A curved patch usually meets its level tangentially: its ragged edge is fitted loosely
        # (a couple of cells), which keeps the footprint to a few lines and arcs.
        loops = [l for l in loops if abs(signed_area(l)) >= min_area]
        prisms = _region_prism(loops, bottom - 1.0, z_above + 1.0, max(fit_tol, cell * 2.5))
        if not prisms:
            continue
        cutter = _surface_cutter(surf, prisms[0])
        if cutter is not None:
            tools.append(cutter)

    box = BRepPrimAPI_MakeBox(gp_Pnt(corner_x, corner_y, bottom),
                              gp_Pnt(corner_x + cols * cell, corner_y + rows * cell, top)).Shape()
    shape = box
    # One cut per tool (cutting with overlapping tools at once cancels their overlap). Each cut is
    # checked: a degenerate tool, or a cut that removes more than the tool holds, is skipped.
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps

    def volume(x) -> float:
        g = GProp_GProps()
        BRepGProp.VolumeProperties_s(x, g)
        return g.Mass()

    skipped = 0
    why: list[str] = []
    current = volume(shape)
    for t in tools:
        tv = volume(t)
        if tv < cell * cell * 0.05 or not BRepCheck_Analyzer(t).IsValid():
            skipped += 1
            why.append(f"tool vol {tv:.2f} valid {BRepCheck_Analyzer(t).IsValid()}")
            continue
        cut = BRepAlgoAPI_Cut(shape, t)
        cut.SetRunParallel(True)
        cut.SetFuzzyValue(1e-4)
        cut.Build()
        if not cut.IsDone():
            skipped += 1
            why.append(f"cut failed, tool vol {tv:.2f}")
            continue
        after = volume(cut.Shape())
        if after < 0 or current - after > tv * 1.01 + 1e-6:
            skipped += 1
            why.append(f"cut removed {current - after:.2f} > tool {tv:.2f}")
            continue
        shape, current = cut.Shape(), after
    if not BRepCheck_Analyzer(shape).IsValid():
        from OCP.ShapeFix import ShapeFix_Shape
        try:
            fix = ShapeFix_Shape(shape)
            fix.Perform()
            shape = fix.Shape()
        except Exception:
            pass
    import os
    if os.environ.get("COASTLINE_CLEAN_WHY"):
        print("skipped:", why)
    if os.environ.get("COASTLINE_CLEAN_RAW"):  # for experiments: the shape before merging
        return shape, {"levels": len(levels), "patches": len(patches), "tools": len(tools), "skipped": skipped, "rough": rejected}
    # Merging coplanar faces can fail on an odd shape (OCCT raises): the solid is kept as it is.
    for unify_edges in (True, False):  # edges too when OCCT manages, else faces only
        try:
            unify = ShapeUpgrade_UnifySameDomain(shape, unify_edges, True, False)
            unify.Build()
            if BRepCheck_Analyzer(unify.Shape()).IsValid() or not BRepCheck_Analyzer(shape).IsValid():
                shape = unify.Shape()
            break
        except Exception:
            continue
    return shape, {"levels": len(levels), "patches": len(patches), "tools": len(tools), "skipped": skipped, "rough": rejected}


def faces_by_type(shape) -> dict[str, int]:
    from OCP.BRep import BRep_Tool
    from OCP.GeomAdaptor import GeomAdaptor_Surface
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS

    out: dict[str, int] = {}
    ex = TopExp_Explorer(shape, TopAbs_FACE)
    while ex.More():
        s = GeomAdaptor_Surface(BRep_Tool.Surface_s(TopoDS.Face(ex.Current())))
        k = str(s.GetType()).split(".")[-1].replace("GeomAbs_", "")
        out[k] = out.get(k, 0) + 1
        ex.Next()
    return out


def write_step(path: str, heights: np.ndarray, origin, cell: float, top: float, bottom: float, name: str) -> dict:
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.Interface import Interface_Static
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer

    shape, info = build(heights, origin, cell, top, bottom)
    Interface_Static.SetCVal_s("write.step.unit", "MM")
    Interface_Static.SetCVal_s("write.step.product.name", name[:60] or "Coastline snapshot")
    w = STEPControl_Writer()
    w.Transfer(shape, STEPControl_AsIs)
    if int(w.Write(path)) != 1:
        raise RuntimeError("OpenCASCADE couldn't write the STEP file")
    kinds = faces_by_type(shape)
    return dict(info, faces=sum(kinds.values()), kinds=kinds, valid=bool(BRepCheck_Analyzer(shape).IsValid()))


def write_3dm(path: str, heights: np.ndarray, origin, cell: float, top: float, bottom: float, name: str) -> dict:
    """The same clean solid as a joined Rhino polysurface (.3dm, openNURBS)."""
    from OCP.BRepCheck import BRepCheck_Analyzer

    from . import clean_3dm

    shape, info = build(heights, origin, cell, top, bottom)
    r = clean_3dm.write(path, shape, name)
    kinds = faces_by_type(shape)
    return dict(info, faces=sum(kinds.values()), kinds=kinds, valid=bool(BRepCheck_Analyzer(shape).IsValid()) and r["valid3dm"],
                dropped=r["dropped"], log=r["log"])


# MARK: Exact part plus what's left on it

def _merge_faces(shape):
    """Same-surface faces merged (the leftover's walls and the part's, where they coincide): with
    tight tolerances, repaired if that leaves a face invalid, or the shape as it was."""
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.ShapeFix import ShapeFix_Shape
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain

    if not BRepCheck_Analyzer(shape).IsValid():
        return shape
    for unify_edges in (True, False):
        try:
            u = ShapeUpgrade_UnifySameDomain(shape, unify_edges, True, False)
            u.SetLinearTolerance(1e-4)
            u.SetAngularTolerance(1e-4)
            u.Build()
            out = u.Shape()
            if BRepCheck_Analyzer(out).IsValid():
                return out
            fix = ShapeFix_Shape(out)
            fix.Perform()
            if BRepCheck_Analyzer(fix.Shape()).IsValid():
                return fix.Shape()
        except Exception:
            continue
    return shape


def build_with_part(heights: np.ndarray, origin, cell: float, top: float, bottom: float, part_shape,
                    part_top: np.ndarray, part_bottom: np.ndarray, finish_tol: float = 0.05) -> tuple[object, dict]:
    """The state as the exact part (the user's own CAD, placed in the work frame) joined with the
    material still left on it. Where the cut has reached the part (simulated height within
    `finish_tol` of the part's top), the part's own surfaces are the answer: those cells are lowered
    to the part's underside, so the reconstruction there sits inside the part and the union shows
    the exact CAD. Only leftover stock is reconstructed (levels, lines and arcs, surfaces), and its
    outlines take the part's exact circles and wall lines where they run along them."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Fuse

    h = np.minimum(np.asarray(heights, float), top)
    on_part = np.isfinite(part_top) & np.isfinite(part_bottom)
    finished = on_part & (h <= part_top + finish_tol)
    lowered = h.copy()
    # Inside the part: down to its underside (never below what the simulation still has).
    lowered[finished] = np.maximum(np.minimum(part_bottom[finished], h[finished]), bottom)
    global _SNAP
    _SNAP = part_walls(part_shape)
    try:
        leftover, info = build(lowered.astype(np.float32), origin, cell, top, bottom)
    finally:
        _SNAP = None
    fuse = BRepAlgoAPI_Fuse(leftover, part_shape)
    fuse.SetFuzzyValue(1e-4)
    fuse.SetRunParallel(True)
    fuse.Build()
    shape = fuse.Shape() if fuse.IsDone() else leftover
    shape = _merge_faces(shape)
    info = dict(info, finished=float(finished.sum()) / max(on_part.sum(), 1), exact_part=True)
    return shape, info


def part_heights(mesh, m: np.ndarray, origin, cell: float, cols: int, rows: int) -> tuple[np.ndarray, np.ndarray]:
    """The part's top and underside heights (work Z) at every cell centre, NaN off the part."""
    import opencamlib as ocl

    from .cam import geometry as g
    from .cam import surface3d as S3

    xs = origin[0] + cell * np.arange(cols)
    ys = origin[1] + cell * np.arange(rows)
    X, Y = np.meshgrid(xs, ys)
    pts = np.c_[X.ravel(), Y.ravel()]
    geo = g.PartGeometry(mesh.vertices, mesh.indices, m)
    floor = geo.zmin - 1.0
    top = S3.Surface(geo, ocl.CylCutter(0.02, 100), floor).drop(pts)
    top = np.where(top <= floor + 1e-6, np.nan, top).reshape(rows, cols)
    # The underside: the part turned over about X, dropped onto from above, turned back.
    turn = np.diag([1.0, -1.0, -1.0, 1.0])
    flipped = g.PartGeometry(mesh.vertices, mesh.indices, turn @ m)
    ffloor = flipped.zmin - 1.0
    under = S3.Surface(flipped, ocl.CylCutter(0.02, 100), ffloor).drop(np.c_[pts[:, 0], -pts[:, 1]])
    under = np.where(under <= ffloor + 1e-6, np.nan, -under).reshape(rows, cols)
    return top, under


def write_with_part(path: str, heights, origin, cell: float, top: float, bottom: float, name: str, part_shape,
                    part_top, part_bottom, fmt: str = "step") -> dict:
    from OCP.BRepCheck import BRepCheck_Analyzer

    shape, info = build_with_part(heights, origin, cell, top, bottom, part_shape, part_top, part_bottom)
    kinds = faces_by_type(shape)
    valid = bool(BRepCheck_Analyzer(shape).IsValid())
    if fmt == "3dm":
        from . import clean_3dm
        if not clean_3dm.available():
            raise RuntimeError("Rhino export needs openNURBS in the engine: run engine/native/get_opennurbs.sh, "
                               "then engine/native/build_opennurbs.sh")
        r = clean_3dm.write(path, shape, name)
        return dict(info, faces=sum(kinds.values()), kinds=kinds, valid=valid and r["valid3dm"], dropped=r["dropped"], log=r["log"])
    from OCP.Interface import Interface_Static
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
    Interface_Static.SetCVal_s("write.step.unit", "MM")
    Interface_Static.SetCVal_s("write.step.product.name", name[:60] or "Coastline snapshot")
    w = STEPControl_Writer()
    w.Transfer(shape, STEPControl_AsIs)
    if int(w.Write(path)) != 1:
        raise RuntimeError("OpenCASCADE couldn't write the STEP file")
    return dict(info, faces=sum(kinds.values()), kinds=kinds, valid=valid)
