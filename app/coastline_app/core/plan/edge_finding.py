"""The edge finder's visits after a clamping, for the viewer. Port of Plan/EdgeFinding.swift."""

from __future__ import annotations

from ..inventory.items import Tool, ToolKind
from ..post.toolpath import Move, Role

# 0.2" edge finder: 0.2" tip on a 1/4" shank.
TOOL = Tool.make('Edge finder (0.2" tip)', ToolKind.FLAT_END_MILL, 5.08, 6.35, 0, 9, 32, 63.5,
                 id="E06EF1D0-0000-4000-8000-000000000001")


def is_edge_finder(t) -> bool:
    return t is not None and t.id == TOOL.id


def moves(stock, depth: float = 1.5, radius: float | None = None) -> list[Move]:
    """Work-frame moves: down beside each edge `depth` below the face, a slow creep to the touch,
    back off, up. `radius`: the touching tool's (electrical probing touches with the cutter)."""
    r = radius if radius is not None else TOOL.diameter / 2
    away = 6.0
    s = stock
    edges = [((-s[0] / 2 - r - away, 0.0), (-s[0] / 2 - r, 0.0)), ((s[0] / 2 + r + away, 0.0), (s[0] / 2 + r, 0.0)),
             ((0.0, -s[1] / 2 - r - away), (0.0, -s[1] / 2 - r)), ((0.0, s[1] / 2 + r + away), (0.0, s[1] / 2 + r))]
    out = []
    for frm, touch in edges:
        out += [Move(Role.RAPID, x=frm[0], y=frm[1], z=5), Move(Role.PLUNGE, x=frm[0], y=frm[1], z=-depth, feed=400),
                Move(Role.LEAD, x=touch[0], y=touch[1], z=-depth, feed=120), Move(Role.LEAD, x=frm[0], y=frm[1], z=-depth, feed=400),
                Move(Role.RAPID, x=frm[0], y=frm[1], z=5)]
    return out
