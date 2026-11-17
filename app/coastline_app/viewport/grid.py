"""The simulated stock's mesh: a height grid closed into a solid (walls and bottom), rewritten in
place as it is cut. Port of SceneMesh.grid / updateGrid (Viewport/MeshBuilder.swift)."""

from __future__ import annotations

import numpy as np

from .scene import SceneMesh


def grid_mesh(id: str, x0: float, y0: float, cell: float, cols: int, rows: int, z: float, color, transform=None,
              bottom: float | None = None, bottom_face: bool = True, facing_down: bool = False) -> SceneMesh:
    c, r = np.meshgrid(np.arange(cols), np.arange(rows))
    p = [np.column_stack([x0 + c.reshape(-1) * cell, y0 + r.reshape(-1) * cell, np.full(cols * rows, z)])]
    n = [np.tile(np.array([0, 0, 1.0]), (cols * rows, 1))]
    a = (np.arange(rows - 1)[:, None] * cols + np.arange(cols - 1)[None, :]).reshape(-1)
    b, d = a + 1, a + cols
    e = d + 1
    # Counter-clockwise seen from the side it faces (a surface facing down is wound the other way).
    tri = np.stack([a, e, b, a, d, e] if facing_down else [a, b, e, a, e, d], axis=1).reshape(-1)
    t = [tri]
    skirt_grid, skirt_vertex = [], []
    count = cols * rows
    if bottom is not None:
        sides = [(np.arange(cols), (0, -1), False), ((rows - 1) * cols + np.arange(cols), (0, 1), True),
                 (np.arange(rows) * cols, (-1, 0), True), (np.arange(rows) * cols + cols - 1, (1, 0), False)]
        grid = p[0]
        for edge, nrm, flip in sides:
            m = len(edge)
            xy = grid[edge, :2]
            # Interleaved top/bottom pairs: vertex k*2 is the top, k*2+1 the bottom (as Swift's order).
            tops = count + np.arange(m) * 2
            bots = tops + 1
            pts = np.empty((2 * m, 3))
            pts[0::2, :2], pts[0::2, 2] = xy, z
            pts[1::2, :2], pts[1::2, 2] = xy, bottom
            p.append(pts)
            n.append(np.tile(np.array([nrm[0], nrm[1], 0.0]), (2 * m, 1)))
            skirt_grid.append(edge)
            skirt_vertex.append(tops)
            b0, b1, t0, t1 = bots[:-1], bots[1:], tops[:-1], tops[1:]
            quad = np.stack([b1, b0, t0, b1, t0, t1] if flip else [b0, b1, t1, b0, t1, t0], axis=1).reshape(-1)
            t.append(quad)
            count += 2 * m
        if bottom_face:
            xa, xb, ya, yb = x0, x0 + (cols - 1) * cell, y0, y0 + (rows - 1) * cell
            p.append(np.array([[xa, ya, bottom], [xb, ya, bottom], [xb, yb, bottom], [xa, yb, bottom]]))
            n.append(np.tile(np.array([0, 0, -1.0]), (4, 1)))
            q0, q1, q2, q3 = count, count + 1, count + 2, count + 3
            t.append(np.array([q0, q2, q1, q0, q3, q2]))
            count += 4
    mesh = SceneMesh(id, np.concatenate(p), np.concatenate(n), np.concatenate(t).astype(np.uint32), color, transform)
    object.__setattr__(mesh, "skirt", (np.concatenate(skirt_grid), np.concatenate(skirt_vertex)) if skirt_grid else None)
    object.__setattr__(mesh, "grid_size", (cols, rows))
    return mesh


def update_grid(mesh: SceneMesh, values, top, back, cols: int, rows: int, cell: float, c0: int, r0: int, c1: int, r1: int,
                downward: bool, floor: float) -> None:
    """Rewrites the grid's heights and normals over the dirty rectangle (and one cell around it),
    and the outer walls."""
    s = np.asarray(values, np.float32).reshape(rows, cols)
    h = np.asarray(top, np.float32).reshape(rows, cols)
    bk = np.asarray(back, np.float32).reshape(rows, cols) if back is not None else None
    v = mesh.vertices.copy()
    nrm = mesh.normals.copy()
    ra, rb = max(r0 - 1, 0), min(r1 + 1, rows - 1)
    ca, cb = max(c0 - 1, 0), min(c1 + 1, cols - 1)
    rr = np.arange(ra, rb + 1)
    cc = np.arange(ca, cb + 1)
    idx = (rr[:, None] * cols + cc[None, :])
    v.reshape(-1, 3)[idx.reshape(-1), 2] = s[ra:rb + 1, ca:cb + 1].reshape(-1)
    left = s[np.ix_(rr, np.maximum(cc - 1, 0))]
    right = s[np.ix_(rr, np.minimum(cc + 1, cols - 1))]
    down = s[np.ix_(np.maximum(rr - 1, 0), cc)]
    up = s[np.ix_(np.minimum(rr + 1, rows - 1), cc)]
    g = np.stack([left - right, down - up, np.full(left.shape, 2 * cell, np.float32)], axis=-1)
    g /= np.linalg.norm(g, axis=-1, keepdims=True)
    if downward:
        g = -g
    if bk is not None:
        g[h[ra:rb + 1, ca:cb + 1] <= bk[ra:rb + 1, ca:cb + 1] + 0.005] = 0  # cut through: the triangles drop
    nrm[idx.reshape(-1)] = g.reshape(-1, 3)
    skirt = getattr(mesh, "skirt", None)
    if skirt is not None and not downward:
        gi, w = skirt
        hf = h.reshape(-1)
        lo = bk.reshape(-1)[gi] if bk is not None else np.full(len(gi), floor, np.float32)
        opened = hf[gi] <= lo + 0.005 if bk is not None else np.zeros(len(gi), bool)
        v[w, 2] = np.where(opened, lo, hf[gi])
        v[w + 1, 2] = lo
    mesh.update_vertices(v, nrm)
