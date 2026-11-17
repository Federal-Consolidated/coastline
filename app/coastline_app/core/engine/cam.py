"""Machining features and toolpath generation through the engine. Port of Engine/EngineCAM.swift.
The engine does geometry only; feeds come from the feeds engine via `PlannedOperation.data`."""

from __future__ import annotations

from dataclasses import dataclass, field

from ..codable import Range
from ..post.toolpath import OperationToolpath
from .client import EngineError, row_major


@dataclass
class Hole:
    x: float
    y: float
    diameter: float
    z_top: float
    z_bottom: float
    through: bool


@dataclass
class PartFeatures:
    """Machining features found by the engine (work frame)."""

    holes: list[Hole]
    floor_levels: list[float]
    part_z: Range
    pocket_widths: list[float] = field(default_factory=list)  # widest circle in each pocket, narrowest first
    floor_widths: list[float] = field(default_factory=list)
    floor_depths: list[float] = field(default_factory=list)


@dataclass
class PlannedOperation:
    """One planned operation, ready for the engine."""

    operation: object
    tool: object
    data: object  # CuttingData
    z_min: float | None = None  # never cut below this work Z (two-sided jobs)
    through: bool = False  # cut through to z_min even below the part's own bottom
    z_top: float = 0.0  # where the material starts (work Z)
    ref_tool: object | None = None  # rest finishing: the larger tool that finished before
    keep_out: list[tuple[tuple[float, float], tuple[float, float]]] = field(default_factory=list)  # clamp areas (XY)
    keep_out_below: float = 0.0
    band: float | None = None  # roughing: how far around the outline to clear
    frame_top: float | None = None
    rest_from: list[tuple[float, float, float]] = field(default_factory=list)  # (diameter, min_pocket, leave)
    tile: Range | None = None  # 3D finishing in strips: only this work-Y stretch
    clearance: float | None = None  # clearance height for rapids when it isn't 3 mm above Z0
    window: tuple[tuple[float, float], tuple[float, float]] | None = None  # a side setup's work-XY window
    holes: list[tuple[tuple[float, float], float, float, float]] = field(default_factory=list)  # (centre, d, top, bottom)


def features(engine, part_id: str, transform) -> PartFeatures:
    result, _ = engine.call("features", {"part_id": part_id, "transform": row_major(transform)})
    holes = [Hole(float(h.get("x", 0)), float(h.get("y", 0)), float(h.get("diameter", 0)), float(h.get("z_top", 0)),
                  float(h.get("z_bottom", 0)), bool(h.get("through", False))) for h in result.get("holes") or []]
    floors_raw = result.get("floors") or []
    floors = [float(f["z"]) for f in floors_raw if isinstance(f.get("z"), (int, float))]
    z = result.get("part_z") or [0, 0]
    f = PartFeatures(holes, floors, Range(float(z[0]), max(float(z[0]), float(z[1]))))
    f.pocket_widths = [float(v) for v in result.get("pockets") or []]
    wide = [fl for fl in floors_raw if float(fl.get("width", 0) or 0) > 0]
    f.floor_widths = [float(fl.get("width", 0)) for fl in wide]
    f.floor_depths = [max(-float(fl.get("z", 0) or 0), 0.0) for fl in wide]
    return f


def _op_params(p: PlannedOperation, machine) -> dict:
    from ..feeds import OperationKind as K
    from ..inventory.items import ToolKind
    op, tool, data = p.operation, p.tool, p.data
    engrave_tip = op.kind is K.ENGRAVE and tool.kind in (ToolKind.ENGRAVER, ToolKind.CHAMFER_MILL)
    cut = max(tool.tip_diameter, 0.1) if engrave_tip else tool.diameter
    d = {
        "id": op.id,
        "kind": op.kind.value,
        "tool": {"diameter": cut, "flute_length": tool.flute_length, "kind": tool.kind.value,
                 "angle": tool.angle if tool.angle is not None else 118, "corner_radius": tool.corner_radius,
                 "stickout": tool.stickout,
                 # The shank above the flutes: wider than the cutter, it mustn't go into the part.
                 "shank_diameter": cut if (engrave_tip or tool.kind in (ToolKind.ENGRAVER, ToolKind.DRILL)) else tool.shank_diameter},
        "data": {"feed": data.feed, "plunge_feed": data.plunge_feed, "ramp_feed": data.ramp_feed,
                 "stepdown": data.stepdown, "stepover": data.stepover, "ramp_angle": data.ramp_angle},
        "leave_radial": op.leave_radial, "leave_axial": op.leave_axial, "face_depth": op.face_depth,
        "spring_pass": op.spring_pass,
    }
    if p.z_min is not None:
        d["z_min"] = p.z_min
    if p.through:
        d["through"] = True
    if op.kind.is_3d:
        params = {"scallop": op.scallop, "angle": op.angle, "steep_angle": op.steep_angle}
        if p.ref_tool is not None:
            r = p.ref_tool
            params["ref_tool"] = {"kind": r.kind.value, "diameter": r.diameter, "corner_radius": r.corner_radius}
        d["params"] = params
    d["z_top"] = p.z_top
    if op.pockets_only is True:
        d["pockets_only"] = True
    if op.min_pocket is not None:
        d["min_pocket"] = op.min_pocket
    if op.floor_max_width is not None:
        d["floor_max_width"] = op.floor_max_width
    if p.band is not None:
        d["band"] = p.band
    if op.kind is K.ADAPTIVE:
        # Roughing never asks for more travel than the machine has (less 1.5 mm).
        t = machine.travel
        d["max_span"] = [max(t.x - 1.5, 0.0), max(t.y - 1.5, 0.0)]
    if p.frame_top is not None:
        d["frame_top"] = p.frame_top
    if p.tile is not None:
        d["tile"] = [p.tile.lower, p.tile.upper]
    if p.window is not None:
        (x0, y0), (x1, y1) = p.window
        d["window"] = [x0, y0, x1, y1]
        if op.kind is K.ADAPTIVE:
            d["side_cavity"] = True  # a setup from a side roughs only that side's own cavities
    if p.holes:
        d["holes"] = [{"x": c[0], "y": c[1], "diameter": dia, "z_top": top, "z_bottom": bottom} for c, dia, top, bottom in p.holes]
    if p.rest_from:
        d["rest_from"] = [{"diameter": a, "min_pocket": b, "leave": c} for a, b, c in p.rest_from]
    if op.kind is K.THREAD and op.thread is not None and op.thread.thread is not None:
        spec = op.thread.thread
        th = {"major": spec.major, "pitch": spec.pitch, "hole_min": spec.hole_range.lower, "hole_max": spec.hole_range.upper}
        if op.thread.depth is not None:
            th["depth"] = op.thread.depth
        d["thread"] = th
    if op.kind is K.ENGRAVE and op.engraving is not None:
        d["curves"] = [[[x, y] for x, y in line] for line in op.engraving.polylines()]
        d["engrave_depth"] = op.engraving.depth
    if p.keep_out:
        d["keep_out"] = {"below": p.keep_out_below, "rects": [[a[0], a[1], b[0], b[1]] for a, b in p.keep_out]}
    return d


def generate(engine, part_id: str, transform, stock_min, stock_max, operations: list[PlannedOperation],
             safe_z: float = 3.0, tabs=None, tab_bottom: float = 0.0, machine=None):
    """Toolpaths for the operations (work frame), and the holding tabs the engine placed."""
    from ..feeds import OperationKind as K
    from ..machine.profile import MachineProfile
    from ..plan.holding_tabs import PlacedTab
    machine = machine or MachineProfile.standard()
    if any(p.operation.kind is K.ADAPTIVE for p in operations) and (machine.travel.x <= 1.5 or machine.travel.y <= 1.5):
        raise EngineError("MachineTravel", "Adaptive roughing needs more than 1.5 mm of X and Y travel for its clearance margin.")
    params = {"part_id": part_id, "transform": row_major(transform),
              "stock_min": [float(v) for v in stock_min], "stock_max": [float(v) for v in stock_max],
              "safe_z": safe_z, "ops": [_op_params(p, machine) for p in operations]}
    if tabs is not None:
        t = {"count": tabs.count, "width": tabs.width, "height": tabs.height, "z_bottom": tab_bottom}
        if tabs.reach is not None:
            t["reach"] = tabs.reach
        if tabs.within_x is not None:
            t["within_x"] = [tabs.within_x.lower, tabs.within_x.upper]
        if tabs.lift is True:
            t["lift"] = True
        if tabs.skin_top is not None:
            t["skin_top"] = tabs.skin_top
        if tabs.avoid:
            t["avoid"] = [list(a) for a in tabs.avoid]
        if tabs.frame is not None:
            f = tabs.frame
            t["frame"] = {"x0": f.origin[0], "y0": f.origin[1], "cell": f.cell, "cols": f.cols, "rows": f.rows, "bits": f.bits}
        params["tabs"] = t
    result, blobs = engine.call("generate", params)
    meta = result.get("ops") or []
    paths = []
    for p, m, blob in zip(operations, meta, blobs):
        path = OperationToolpath.decode(p.operation.id, blob, list(m.get("warnings") or []))
        path.min_stickout = m.get("min_stickout")
        paths.append(path)
    placed = []
    for t in result.get("tabs") or []:
        c, n, poly = t.get("centre"), t.get("normal"), t.get("poly")
        if isinstance(c, list) and isinstance(n, list) and isinstance(poly, list) and len(c) == 2 and len(n) == 2:
            placed.append(PlacedTab((c[0], c[1]), (n[0], n[1]), [(q[0], q[1]) for q in poly if len(q) == 2]))
    return paths, placed
