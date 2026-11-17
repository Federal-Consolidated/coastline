"""The simulated stock is a grid of heights (the top) and, on two-sided jobs, a second grid (the
back). Where both sides cut through, the grid's triangles are dropped; these build what closes the
solid around those holes, and find the pieces that came loose. Port of Model/SimSurfaces.swift."""

from __future__ import annotations

import numpy as np


def walls(cols: int, rows: int, x0: float, y0: float, cell: float, top, back, bottom: float, open_mask) -> tuple[np.ndarray, np.ndarray]:
    """Walls along the edge of every hole cut through: from the back (or the bottom) up to the top,
    facing into the hole. (positions, normals) as (n, 3) float32, grid coordinates. `open_mask`:
    per grid point, cut through."""
    empty = (np.zeros((0, 3), np.float32), np.zeros((0, 3), np.float32))
    qc, qr = cols - 1, rows - 1
    if qc <= 0 or qr <= 0:
        return empty
    mat = ~np.asarray(open_mask, bool).reshape(rows, cols)
    if mat.all():
        return empty
    h = np.asarray(top, np.float32).reshape(-1)
    bk = np.asarray(back, np.float32).reshape(-1) if back is not None else None
    # Each quad (r, c) is two triangles: T1 = (a, b, e), T2 = (a, e, d); a triangle draws only if
    # all three corners have material.
    A, B, D, E = mat[:-1, :-1], mat[:-1, 1:], mat[1:, :-1], mat[1:, 1:]
    t1, t2 = A & B & E, A & E & D
    r, c = np.meshgrid(np.arange(qr), np.arange(qc), indexing="ij")
    a = r * cols + c
    b, d = a + 1, a + cols
    e = d + 1
    no = np.zeros((qr, qc), bool)
    t2_up = no.copy(); t2_up[1:] = ~t2[:-1]
    t2_right = no.copy(); t2_right[:, :-1] = ~t2[:, 1:]
    t1_down = no.copy(); t1_down[:-1] = ~t1[1:]
    t1_left = no.copy(); t1_left[:, 1:] = ~t1[:, :-1]
    cases = [(t1 & t2_up, a, b, e), (t1 & t2_right, b, e, a), (t1 & ~t2, a, e, b),
             (t2 & t1_down, e, d, a), (t2 & t1_left, d, a, e), (t2 & ~t1, a, e, d)]
    I = np.concatenate([i[m] for m, i, _, _ in cases])
    J = np.concatenate([j[m] for m, _, j, _ in cases])
    K = np.concatenate([k[m] for m, _, _, k in cases])
    if not len(I):
        return empty

    def xy(i):
        return np.stack([x0 + (i % cols) * cell, y0 + (i // cols) * cell], axis=1).astype(np.float32)

    pi, pj, pk = xy(I), xy(J), xy(K)
    along = pj - pi
    out = np.stack([along[:, 1], -along[:, 0]], axis=1)
    out /= np.maximum(np.linalg.norm(out, axis=1), 1e-30)[:, None]
    flip = ((out * (pk - pi)).sum(axis=1) > 0)
    out[flip] *= -1  # away from the drawn triangle
    bi = bk[I] if bk is not None else np.full(len(I), bottom, np.float32)
    bj = bk[J] if bk is not None else np.full(len(I), bottom, np.float32)
    q0 = np.column_stack([pi, h[I]])
    q1 = np.column_stack([pj, h[J]])
    q2 = np.column_stack([pj, bj])
    q3 = np.column_stack([pi, bi])
    # Counter-clockwise seen from the hole (the shader turns back faces' normals around).
    n3 = np.column_stack([out, np.zeros(len(I), np.float32)])
    rev = (np.cross(q1 - q0, q2 - q0) * n3).sum(axis=1) < 0
    q0r, q1r, q2r, q3r = q0.copy(), q1.copy(), q2.copy(), q3.copy()
    q0[rev], q1[rev], q2[rev], q3[rev] = q3r[rev], q2r[rev], q1r[rev], q0r[rev]
    p = np.stack([q0, q1, q2, q0, q2, q3], axis=1).reshape(-1, 3).astype(np.float32)
    n = np.repeat(n3, 6, axis=0).astype(np.float32)
    return p, n


def loose(cols: int, rows: int, top, back, bottom: float, open_mask, held_mask) -> tuple[np.ndarray, int]:
    """Material that hangs together with nothing holding it: grid points with material, in pieces
    (4-connected) none of which touches `held_mask`. Without any held point the biggest piece
    counts as held. Returns a mask and how many pieces."""
    count = cols * rows
    h = np.asarray(top, np.float32).reshape(-1)
    under = np.asarray(back, np.float32).reshape(-1) if back is not None else np.full(count, bottom, np.float32)
    solid = (~np.asarray(open_mask, bool).reshape(-1)) & (h - under > 0.02)
    held = np.asarray(held_mask, bool).reshape(-1)
    label = np.full(count, -1, np.int32)
    sizes: list[int] = []
    anchored: list[bool] = []
    sl = solid.tolist()
    lab = label.tolist()
    hl = held.tolist()
    for s in np.flatnonzero(solid).tolist():
        if lab[s] >= 0:
            continue
        pid = len(sizes)
        size, holds = 0, False
        lab[s] = pid
        stack = [s]
        while stack:
            i = stack.pop()
            size += 1
            if not holds and hl[i]:
                holds = True
            r, c = divmod(i, cols)
            if c > 0 and sl[i - 1] and lab[i - 1] < 0:
                lab[i - 1] = pid; stack.append(i - 1)
            if c + 1 < cols and sl[i + 1] and lab[i + 1] < 0:
                lab[i + 1] = pid; stack.append(i + 1)
            if r > 0 and sl[i - cols] and lab[i - cols] < 0:
                lab[i - cols] = pid; stack.append(i - cols)
            if r + 1 < rows and sl[i + cols] and lab[i + cols] < 0:
                lab[i + cols] = pid; stack.append(i + cols)
        sizes.append(size)
        anchored.append(holds)
    if sizes and not any(anchored):
        big = 0
        for k in range(1, len(sizes)):
            if sizes[big] < sizes[k]:
                big = k
        anchored[big] = True
    # Specks of a few cells are rounding at the grid's resolution, not pieces.
    real = [k for k in range(len(sizes)) if not anchored[k] and sizes[k] >= 6]
    label = np.array(lab, np.int32)
    mask = np.isin(label, np.array(real, np.int32)) if real else np.zeros(count, bool)
    return mask, len(real)


def overlay(cols: int, rows: int, x0: float, y0: float, cell: float, top, mask) -> tuple[np.ndarray, np.ndarray]:
    """Quads just above the top surface over loose material (every quad whose corners are all
    loose), to colour it."""
    m = np.asarray(mask, bool).reshape(rows, cols)
    h = np.asarray(top, np.float32).reshape(-1)
    q = m[:-1, :-1] & m[:-1, 1:] & m[1:, :-1] & m[1:, 1:]
    r, c = np.nonzero(q)
    if not len(r):
        return np.zeros((0, 3), np.float32), np.zeros((0, 3), np.float32)
    a = r * cols + c
    b, d = a + 1, a + cols
    e = d + 1

    def v(i):
        return np.column_stack([x0 + (i % cols) * cell, y0 + (i // cols) * cell, h[i] + 0.03])

    p = np.stack([v(a), v(b), v(e), v(a), v(e), v(d)], axis=1).reshape(-1, 3).astype(np.float32)
    n = np.tile(np.array([0, 0, 1], np.float32), (len(p), 1))
    return p, n
