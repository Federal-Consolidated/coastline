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

def find_levels(h: np.ndarray, top: float, cell: float, flat_tol: float, min_area: float) -> list[float]:
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
            if all(abs(z - l) > flat_tol for l in levels):
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


# MARK: Building

def _wire(points_xy: np.ndarray, z: float, tol: float):
    """A closed wire through the loop: lines and arcs where they fit within tol."""
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire
    from OCP.GC import GC_MakeArcOfCircle
    from OCP.gp import gp_Pnt

    start, segs = fit_outline(points_xy, tol)
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


def _region_prism(loops_world: list[np.ndarray], z0: float, z1: float, tol: float):
    """Prisms from z0 up to z1 over a mask's loops (outer loops with their holes)."""
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    from OCP.BRepPrimAPI import BRepPrimAPI_MakePrism
    from OCP.gp import gp_Vec

    outers = [l for l in loops_world if signed_area(l) > 0]
    holes = [l for l in loops_world if signed_area(l) < 0]
    solids = []
    for o in outers:
        w = _wire(o, z0, tol)
        if w is None:
            continue
        mk = BRepBuilderAPI_MakeFace(w, True)
        if not mk.IsDone():
            continue
        for hl in holes:
            if _inside(hl[0], o):
                hw = _wire(hl, z0, tol)
                if hw is not None:
                    mk.Add(hw)  # traced clockwise: already an inner wire
        face = mk.Face()
        solids.append(BRepPrimAPI_MakePrism(face, gp_Vec(0, 0, z1 - z0)).Shape())
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


def _surface_cutter(eff: np.ndarray, inside: np.ndarray, rows: slice, cols: slice, x0: float, y0: float, cell: float,
                    footprint):
    """The part of the patch's footprint prism above a B-spline surface fitted to its heights."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Splitter
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    from OCP.BRepGProp import BRepGProp
    from OCP.collections import Array2_gp_Pnt, List_TopoDS_Shape
    from OCP.GeomAbs import GeomAbs_C2
    from OCP.GeomAPI import GeomAPI_PointsToBSplineSurface, GeomAPI_ProjectPointOnSurf
    from OCP.GProp import GProp_GProps
    from OCP.gp import gp_Pnt
    from OCP.TopAbs import TopAbs_SOLID
    from OCP.TopExp import TopExp_Explorer

    sub = _extend(eff[rows, cols], inside[rows, cols])
    nr, nc = sub.shape
    # A light surface (about 30 × 30 points, cubic): smooth, and fast in the booleans.
    step = max(1, int(math.ceil(max(nr, nc) / 30)))
    ri = list(range(0, nr, step)) + ([nr - 1] if (nr - 1) % step else [])
    ci = list(range(0, nc, step)) + ([nc - 1] if (nc - 1) % step else [])
    if len(ri) < 4 or len(ci) < 4:
        return None
    arr = Array2_gp_Pnt(1, len(ci), 1, len(ri))
    for a, c in enumerate(ci):
        for b, r in enumerate(ri):
            arr.SetValue(a + 1, b + 1, gp_Pnt(x0 + (cols.start + c) * cell, y0 + (rows.start + r) * cell, float(sub[r, c])))
    try:
        surf = GeomAPI_PointsToBSplineSurface(arr, 3, 3, GeomAbs_C2, max(cell * 0.6, 0.01)).Surface()
    except Exception:
        return None
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
    # Keep the pieces above the surface.
    from OCP.BRep import BRep_Builder
    from OCP.TopoDS import TopoDS_Compound
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
          flat_tol: float = 0.01, min_area: float = 0.2) -> tuple[object, dict]:
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
    levels = find_levels(h, top, cell, flat_tol, min_area)
    eff, sloped = classify(h, levels, flat_tol)
    # Small or thin sloped patches snap to their nearest level (clean, simple geometry).
    min_cells = max(min_area / (cell * cell), 9)
    patches = []
    for comp in components(sloped):
        rr, cc = comp[:, 0], comp[:, 1]
        thin = min(rr.max() - rr.min(), cc.max() - cc.min()) < 3
        if len(comp) < min_cells or thin:
            lv = np.array(levels)
            eff[rr, cc] = lv[np.argmin(abs(h[rr, cc][:, None] - lv[None, :]), axis=1)]
        else:
            patches.append(comp)

    def world(loop_units: np.ndarray) -> np.ndarray:
        return np.c_[corner_x + loop_units[:, 0] * cell, corner_y + loop_units[:, 1] * cell]

    fit_tol = max(cell * 0.6, 0.005)
    z_above = top + 1.0
    # The sloped patches are cut by their surfaces; the levels' outlines leave them out (no two
    # nearly identical walls meeting as slivers). Each patch's footprint reaches one cell past it.
    in_patch = np.zeros_like(sloped)
    for comp in patches:
        in_patch[comp[:, 0], comp[:, 1]] = True
    tools = []
    for z in levels:
        if z >= top - 1e-9:
            continue
        mask = (eff <= z + 1e-6) & ~in_patch
        if not mask.any():
            continue
        # Past the stock's sides: a pocket that reaches the edge cuts clean through it.
        loops = [world(smooth_loop(l)) for l in trace_loops(np.pad(mask, 1, mode="edge"))]
        loops = [l - cell for l in loops]
        loops = [l for l in loops if abs(signed_area(l)) >= min_area]  # specks are noise
        tools += _region_prism(loops, z, z_above, fit_tol)
    for comp in patches:
        rr, cc = comp[:, 0], comp[:, 1]
        fmask = np.zeros_like(sloped)
        fmask[rr, cc] = True
        grown = fmask.copy()
        grown[1:, :] |= fmask[:-1, :]
        grown[:-1, :] |= fmask[1:, :]
        grown[:, 1:] |= fmask[:, :-1]
        grown[:, :-1] |= fmask[:, 1:]
        loops = [world(smooth_loop(l)) for l in trace_loops(grown)]
        prisms = _region_prism(loops, bottom - 1.0, z_above + 1.0, fit_tol)
        if not prisms:
            continue
        # The surface reaches well past the footprint (heights extended outward), so it splits it
        # cleanly in two.
        r0, r1 = max(rr.min() - 6, 0), min(rr.max() + 7, rows)
        c0, c1 = max(cc.min() - 6, 0), min(cc.max() + 7, cols)
        cutter = _surface_cutter(eff, fmask, slice(r0, r1), slice(c0, c1), x0, y0, cell, prisms[0])
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
    current = volume(shape)
    for t in tools:
        tv = volume(t)
        if tv < cell * cell * 0.05 or not BRepCheck_Analyzer(t).IsValid():
            skipped += 1
            continue
        cut = BRepAlgoAPI_Cut(shape, t)
        cut.SetRunParallel(True)
        cut.SetFuzzyValue(1e-4)
        cut.Build()
        if not cut.IsDone():
            skipped += 1
            continue
        after = volume(cut.Shape())
        if after < 0 or current - after > tv * 1.01 + 1e-6:
            skipped += 1
            continue
        shape, current = cut.Shape(), after
    if not BRepCheck_Analyzer(shape).IsValid():
        from OCP.ShapeFix import ShapeFix_Shape
        fix = ShapeFix_Shape(shape)
        fix.Perform()
        shape = fix.Shape()
    unify = ShapeUpgrade_UnifySameDomain(shape, True, True, False)
    unify.Build()
    if BRepCheck_Analyzer(unify.Shape()).IsValid() or not BRepCheck_Analyzer(shape).IsValid():
        shape = unify.Shape()
    return shape, {"levels": len(levels), "patches": len(patches), "tools": len(tools), "skipped": skipped}


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
