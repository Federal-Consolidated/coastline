"""Checks of inventory items against the machine and the rest of the inventory, and the
structural validation shared by library files and editors. Port of Inventory/InventoryChecks.swift
and ResourceLibraryValidation (Inventory/ResourceLibraryPackage.swift)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from ..units import Length


class Severity(Enum):
    INFO = 0
    WARNING = 1
    ERROR = 2

    def __lt__(self, o: "Severity") -> bool:
        return self.value < o.value

    def __le__(self, o: "Severity") -> bool:
        return self.value <= o.value

    def __gt__(self, o: "Severity") -> bool:
        return self.value > o.value

    def __ge__(self, o: "Severity") -> bool:
        return self.value >= o.value


@dataclass(frozen=True)
class Issue:
    """A problem or hint about an item, shown in its inspector and used by the planner."""

    severity: Severity
    message: str

    @property
    def id(self) -> str:
        return f"{self.severity.value}|{self.message}"


class ResourceLibraryValidation:
    """Validation for resource files and the stock/tool editors. Machine fit is a separate check."""

    @staticmethod
    def stock_issues(stock) -> list[str]:
        from .items import StockShape
        issues = []
        if not stock.material_id.strip():
            issues.append("Choose a material.")
        if (not all(math.isfinite(v) and v > 0 for v in (stock.size_x, stock.size_y)) or not math.isfinite(stock.size_z)
                or (stock.size_z < 0 if stock.shape is StockShape.ROUND_BAR else stock.size_z <= 0)):
            issues.append("Stock dimensions must be finite and positive (round-bar Z may be zero).")
        if stock.quantity < 0:
            issues.append("Quantity cannot be negative.")
        if stock.unit_cost is not None and (not math.isfinite(stock.unit_cost) or stock.unit_cost < 0):
            issues.append("Cost must be finite and nonnegative.")
        if stock.extrusion_axis is not None and not 0 <= stock.extrusion_axis <= 2:
            issues.append("Extrusion axis must be X, Y or Z.")
        m = stock.material_snapshot
        if m is not None:
            if m.id != stock.material_id:
                issues.append("The embedded material does not match the stock's material ID.")
            issues += m.validation_issues
        return issues

    @staticmethod
    def tool_issues(tool) -> list[str]:
        from .items import Coating, ToolMaterial
        issues = []
        if not tool.name.strip():
            issues.append("Give the tool a name.")
        draft = tool.requires_specification_review
        if not all(math.isfinite(v) and (v >= 0 if draft else v > 0)
                   for v in (tool.diameter, tool.shank_diameter, tool.flute_length, tool.stickout, tool.overall_length)):
            issues.append("Tool diameters and lengths must be finite and positive.")
        if tool.overall_length > 0 and (tool.flute_length > tool.overall_length or tool.stickout > tool.overall_length):
            issues.append("Flute length and stickout cannot exceed overall length.")
        if (tool.flutes < 0) if draft else (tool.flutes <= 0):
            issues.append("The number of flutes must be positive.")
        if tool.coating is Coating.UNSPECIFIED and not draft:
            issues.append("Confirm the tool's coating, including uncoated if applicable.")
        if tool.tool_material is ToolMaterial.UNSPECIFIED and not draft:
            issues.append("Confirm the tool's cutting material.")
        if tool.unconfirmed_specifications is not None and any(not f.strip() for f in tool.unconfirmed_specifications):
            issues.append("Unconfirmed specifications must identify the missing measurements.")
        if not math.isfinite(tool.corner_radius) or tool.corner_radius < 0 or tool.corner_radius > tool.diameter / 2:
            issues.append("Corner radius must be between zero and half the tool diameter.")
        if not math.isfinite(tool.tip_diameter) or tool.tip_diameter < 0 or tool.tip_diameter > tool.diameter:
            issues.append("Tip diameter must fit inside the tool diameter.")
        if tool.angle is not None and (not math.isfinite(tool.angle) or tool.angle <= 0 or tool.angle > 180):
            issues.append("Tool angle must be between zero and 180 degrees.")
        if tool.thread_pitch is not None and (not math.isfinite(tool.thread_pitch) or tool.thread_pitch <= 0):
            issues.append("Thread pitch must be positive and finite.")
        if tool.quantity < 0:
            issues.append("Quantity cannot be negative.")
        if tool.unit_cost is not None and (not math.isfinite(tool.unit_cost) or tool.unit_cost < 0):
            issues.append("Cost must be finite and nonnegative.")
        if not all(math.isfinite(v) and v >= 0 for v in (tool.cutting_minutes, tool.cutting_distance)):
            issues.append("Tool usage cannot be negative or nonfinite.")
        for p in tool.presets:
            if not math.isfinite(p.rpm) or p.rpm <= 0 or not all(math.isfinite(v) and v >= 0 for v in (p.feed, p.plunge_feed, p.ramp_feed)):
                issues.append(f"Preset {p.name} needs a positive spindle speed and finite, nonnegative feeds.")
            if any(not math.isfinite(v) or v <= 0 for v in (p.stepdown, p.stepover) if v is not None):
                issues.append(f"Preset {p.name} depths must be finite and positive.")
        return issues


class InventoryChecks:
    COLLET_TOLERANCE = 0.05  # how close a collet must match a shank, mm

    @staticmethod
    def check_tool(tool, inventory, machine=None) -> list[Issue]:
        from ..machine.profile import MachineProfile
        from .items import Condition
        machine = machine or MachineProfile.standard()
        invalid = ResourceLibraryValidation.tool_issues(tool)
        if invalid:
            return [Issue(Severity.ERROR, m) for m in invalid]
        if tool.requires_specification_review:
            return [Issue(Severity.ERROR, "Complete and confirm the tool specifications before planning: "
                          + ", ".join(tool.unconfirmed_specifications or []) + ".")]
        issues = []
        if tool.shank_diameter > machine.max_shank_diameter + 1e-6:
            issues.append(Issue(Severity.ERROR, f"The {Length.describe(tool.shank_diameter)} shank is too big for the {machine.collet_name} collet (max {Length.mm(machine.max_shank_diameter)} mm)."))
        elif not any(abs(c - tool.shank_diameter) <= InventoryChecks.COLLET_TOLERANCE for c in inventory.collet_sizes):
            issues.append(Issue(Severity.WARNING, f"You have no {machine.collet_name} collet for a {Length.describe(tool.shank_diameter)} shank. Add one under Accessories, or buy one."))
        if tool.overall_length > machine.max_tool_length + 1e-6:
            issues.append(Issue(Severity.ERROR, f"{Length.mm(tool.overall_length)} mm long: tools over {Length.mm(machine.max_tool_length)} mm exceed this machine profile’s tool-length limit."))
        if tool.kind.cuts_sideways and tool.stickout + 1e-6 < tool.flute_length:
            issues.append(Issue(Severity.WARNING, f"Stick-out ({Length.mm(tool.stickout)} mm) is shorter than the flutes ({Length.mm(tool.flute_length)} mm). The flutes would sit inside the collet."))
        fluted = min(tool.flute_length, tool.stickout)
        ratio = fluted / max(tool.diameter, 0.01) + (tool.stickout - fluted) / max(tool.shank_diameter, 0.01)
        if tool.kind.cuts_sideways and ratio > 10:
            issues.append(Issue(Severity.WARNING, f"The tool is very slender (about {ratio:.0f}× its diameter). Expect deflection and chatter; the planner will use very light cuts."))
        elif tool.kind.cuts_sideways and ratio > 7:
            issues.append(Issue(Severity.INFO, f"The tool is fairly slender (about {ratio:.1f}× its diameter). Shorten the stick-out if the job allows; it improves finish and tool life."))
        if tool.overall_length - tool.stickout < 10:
            issues.append(Issue(Severity.WARNING, f"Only {Length.mm(tool.overall_length - tool.stickout)} mm of shank in the collet. Grip at least 10 mm."))
        if tool.condition is Condition.WORN:
            issues.append(Issue(Severity.WARNING, "Marked worn. Fine for roughing; don't use it for finishing passes."))
        elif tool.condition is Condition.BROKEN:
            issues.append(Issue(Severity.ERROR, "Marked broken. The planner won't use it."))
        if tool.quantity <= 0:
            issues.append(Issue(Severity.INFO, "Quantity is 0, so the planner treats it as not owned. It will suggest buying it when it helps."))
        return issues

    @staticmethod
    def check_stock(stock, machine=None) -> list[Issue]:
        from ..machine.profile import MachineProfile
        from ..materials import Difficulty
        from .items import StockFinish, StockShape
        machine = machine or MachineProfile.standard()
        invalid = ResourceLibraryValidation.stock_issues(stock)
        if invalid:
            return [Issue(Severity.ERROR, m) for m in invalid]
        if not (stock.size_x > 0 and stock.size_y > 0 and (stock.shape is StockShape.ROUND_BAR or stock.size_z > 0)):
            return [Issue(Severity.ERROR, "Enter all the dimensions.")]
        issues = []
        if stock.material is None:
            issues.append(Issue(Severity.ERROR, "Unknown material. Pick one from the library."))
        env = machine.physical_envelope
        dims = sorted((stock.envelope.x, stock.envelope.y, stock.envelope.z))
        box = sorted((env.x, env.y, env.z))
        if any(d > b for d, b in zip(dims, box)):
            issues.append(Issue(Severity.ERROR, f"Doesn't fit the machine work envelope ({Length.mm(env.x)} × {Length.mm(env.y)} × {Length.mm(env.z)} mm) in any orientation. Cut it down first."))
        else:
            room = env.z - dims[0]  # lying on its largest face, how much Z is left for the tool?
            if room < 30:
                issues.append(Issue(Severity.WARNING, f"Lying flat it leaves only {Length.mm(room)} mm of Z for the tool and collet nut. Use short tools, or a thinner piece."))
        if stock.finish is StockFinish.SAWN:
            issues.append(Issue(Severity.INFO, "Sawn faces aren't flat or square. The plan will face a datum surface first."))
        m = stock.material
        if m is not None and m.difficulty >= Difficulty.CAREFUL:
            issues.append(Issue(Severity.INFO, f"{m.name}: {m.difficulty.title}. {m.difficulty.explanation}"))
        return issues
