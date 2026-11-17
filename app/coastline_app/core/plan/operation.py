"""One machining operation in a setup, and the rule-of-thumb first operation list. Port of
Plan/Operation.swift. `None` overrides mean "let Coastline decide"."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from enum import Enum

from .. import feeds
from ..codable import jfield
from ..feeds import CuttingData, OperationKind, RoughingStyle
from ..geometry import swift_round
from ..ids import new_id
from ..units import Length
from .engraving import Engraving
from .threads import ThreadMilling

DEFAULT_MIN_POCKET = 1.6  # pockets narrower than this many tool diameters go to a smaller tool


class ReferenceFeature(Enum):
    """Two-sided registration features Coastline adds: side A's bores, side B's windows."""

    BORES = "bores"
    WINDOWS = "windows"


@dataclass
class Operation:
    kind: OperationKind
    id: str = field(default_factory=new_id)
    enabled: bool = True
    tool_id: str | None = jfield(None, key="toolID")
    leave_radial: float = 0.0  # material left on walls for the finishing passes, mm
    leave_axial: float = 0.0  # material left on floors, mm
    stepdown_override: float | None = None
    stepover_override: float | None = None
    face_depth: float = 0.25  # facing depth below the stock top, mm
    spring_pass: bool = False  # repeat the last contour pass to take out deflection
    scallop: float = 0.008  # 3D finishing: cusp height, mm
    angle: float = 0.0  # raster angle, degrees
    steep_angle: float = 45.0  # the steep/shallow split, degrees
    feed_scale: float = 1.0  # pace from the tuner
    engraving: Engraving | None = None
    pockets_only: bool | None = None  # roughing only the pockets inside the outline
    min_pocket: float | None = None  # pockets narrower than this many diameters are left
    floor_max_width: float | None = None  # floor finishing: only floors narrower than this (mm)
    reference: ReferenceFeature | None = None
    roughing: RoughingStyle | None = None
    thread: ThreadMilling | None = None

    def copy(self) -> "Operation":
        return copy.deepcopy(self)

    @property
    def title(self) -> str:
        if self.reference is ReferenceFeature.BORES:
            return "Reference bores"
        if self.reference is ReferenceFeature.WINDOWS:
            return "Reference windows"
        if self.kind is OperationKind.ENGRAVE and self.engraving is not None and self.engraving.texture is not None:
            return f"Texture · {self.engraving.texture.pattern.title}"
        return self.kind.title

    @property
    def explanation(self) -> str:
        if self.kind is OperationKind.ENGRAVE and self.engraving is not None and self.engraving.texture is not None:
            return ("Cuts a decorative pattern into the surface at a set depth, following its shape, like a watchmaker's "
                    "rose engine: guilloché, waves, hobnail. A V engraver gives the crispest lines.")
        return self.kind.explanation

    def cutting_data(self, tool, material, machine=None) -> CuttingData:
        """Cutting data with the user's overrides applied."""
        from ..machine.profile import MachineProfile
        machine = machine or MachineProfile.standard()
        data = feeds.compute(tool, material, self.kind, machine, self.roughing or RoughingStyle.THINNED)
        if self.kind.is_3d:
            data.stepover = feeds.scallop_stepover(tool, self.scallop)
            data.stepdown = data.stepover
            data.notes = [n for n in data.notes if not n.startswith("Stepover")]
            data.notes.append(f"Stepover {Length.mm(data.stepover)} mm leaves cusps about {int(swift_round(self.scallop * 1000))} µm high.")
        if abs(self.feed_scale - 1) > 1e-6:
            cap = machine.max_feed_any_direction
            data.feed = min(swift_round(data.feed * self.feed_scale), cap)
            data.plunge_feed = min(swift_round(data.plunge_feed * self.feed_scale), cap)
            data.ramp_feed = min(swift_round(data.ramp_feed * self.feed_scale), cap)
            if self.kind is OperationKind.ADAPTIVE:
                data.stepover *= math.sqrt(self.feed_scale)
            data.notes.append(f"Pace {int(swift_round(self.feed_scale * 100))} %: feeds"
                              + (" and engagement" if self.kind is OperationKind.ADAPTIVE else "")
                              + " scaled from the recommended values.")
        if self.stepdown_override is not None:
            data.stepdown = self.stepdown_override
        if self.stepover_override is not None:
            data.stepover = self.stepover_override
        return data


@dataclass
class Proposal:
    operations: list[Operation]
    notes: list[str]


class OperationPlanner:
    """Proposes a first operation list from the inventory: rules of thumb, each explained."""

    @staticmethod
    def usable_tools(inventory, include_suggestions: bool = False, machine=None) -> list:
        """Tools the planner may use: owned, not broken, and with a matching collet."""
        from ..inventory.checks import InventoryChecks, Severity
        from ..inventory.items import Condition
        out = []
        for t in inventory.tools:
            if not (t.quantity > 0 or (include_suggestions and t.is_suggestion)) or t.condition is Condition.BROKEN:
                continue
            if not all(i.severity < Severity.ERROR for i in InventoryChecks.check_tool(t, inventory, machine)):
                continue
            if not any(abs(c - t.shank_diameter) <= 0.05 for c in inventory.collet_sizes):
                continue
            out.append(t)
        return out

    @staticmethod
    def propose(inventory, hole_diameters: list[float] = (), has_floors: bool = False, freeform: bool = False,
                min_concave_radius: float | None = None, face_depth: float = 0.25, machine=None) -> Proposal:
        from ..inventory.items import ToolKind
        K = OperationKind
        tools = OperationPlanner.usable_tools(inventory, machine=machine)
        flats = sorted((t for t in tools if t.kind is ToolKind.FLAT_END_MILL), key=lambda t: -t.diameter)
        ops: list[Operation] = []
        notes: list[str] = []
        rougher = next((t for t in flats if t.diameter <= 6.36), flats[0] if flats else None)
        if rougher is None:
            return Proposal([], ["No usable flat end mill in your inventory (check quantities and collets)."])
        if face_depth > 1e-6:
            ops.append(Operation(K.FACING, tool_id=rougher.id, face_depth=face_depth))
        else:
            notes.append("Zero face allowance: keep the existing stock face, with no facing operation.")
        notes.append(f"Roughing with the {rougher.name}: the largest end mill you can hold, for speed and rigidity.")
        rough = Operation(K.ADAPTIVE, tool_id=rougher.id, leave_radial=0.2, leave_axial=0.1)
        if freeform:
            rough.stepdown_override = 1.0
            rough.leave_axial = 0.15
            notes.append("Curved surfaces: roughing steps down 1 mm at a time so the terraces it leaves are small for the ball finisher.")
        ops.append(rough)
        finisher = next((t for t in flats if t.diameter < rougher.diameter - 0.5 and t.diameter >= 2.9), rougher)
        if finisher.id != rougher.id:
            notes.append(f"Finishing walls with the {finisher.name}: reaches tighter corners and cuts lighter.")
        ops.append(Operation(K.CONTOUR, tool_id=finisher.id, spring_pass=True))
        if has_floors:
            ops.append(Operation(K.FLOOR, tool_id=finisher.id))
        if freeform:
            balls = sorted((t for t in tools if t.kind is ToolKind.BALL_END_MILL), key=lambda t: -t.diameter)
            limit = 2 * min_concave_radius if min_concave_radius is not None else math.inf
            ball = next((b for b in balls if b.diameter <= min(limit, 6.36)), balls[-1] if balls else None)
            if ball is not None:
                ops.append(Operation(K.STEEP_SHALLOW, tool_id=ball.id))
                notes.append(f"Curved surfaces: steep & shallow finishing with the {ball.name}, leaving ~8 µm cusps.")
                small = next((b for b in balls if b.diameter < ball.diameter - 0.4), None)
                if small is not None:
                    ops.append(Operation(K.REST, tool_id=small.id))
                    notes.append(f"Then the {small.name} cleans the corners the bigger ball couldn't reach.")
            else:
                notes.append('Curved surfaces need a ball end mill for a smooth finish. A 1/8" ball is a good first one to buy.')
        drills = [t for t in tools if t.kind is ToolKind.DRILL]
        for d in sorted({swift_round(h * 100) / 100 for h in hole_diameters}):
            drill = next((t for t in drills if abs(t.diameter - d) <= 0.05), None)
            if drill is not None:
                ops.append(Operation(K.DRILL, tool_id=drill.id))
                notes.append(f"⌀{Length.mm(d)} holes: drilled with the {drill.name}.")
                continue
            mills = [t for t in flats if d * 0.3 <= t.diameter <= d * 0.8]
            if mills:
                mill = max(mills, key=lambda t: t.diameter)
                ops.append(Operation(K.BORE, tool_id=mill.id))
                notes.append(f"⌀{Length.mm(d)} holes: no matching drill, so they're helically bored with the {mill.name}.")
            else:
                notes.append(f"⌀{Length.mm(d)} holes: no drill or small enough end mill. Add one to your inventory.")
        return Proposal(ops, notes)
