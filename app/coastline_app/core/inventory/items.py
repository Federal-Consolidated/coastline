"""Inventory items: cutting tools, stock, fixtures, measuring tools and accessories.
Port of Inventory/Tool.swift and Inventory/InventoryItems.swift. All lengths are mm."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from enum import Enum

from ..codable import Range, jfield
from ..geometry import Vec3
from ..ids import new_id
from ..materials import Material, MaterialLibrary
from ..units import Length


# ---------------------------------------------------------------- tools

class ToolKind(Enum):
    FLAT_END_MILL = "flatEndMill"
    BALL_END_MILL = "ballEndMill"
    BULL_NOSE_END_MILL = "bullNoseEndMill"
    CHAMFER_MILL = "chamferMill"
    ENGRAVER = "engraver"
    DRILL = "drill"
    SPOT_DRILL = "spotDrill"
    THREAD_MILL = "threadMill"
    FACE_MILL = "faceMill"

    @property
    def title(self) -> str:
        return {"flatEndMill": "Flat end mill", "ballEndMill": "Ball end mill", "bullNoseEndMill": "Bull nose end mill",
                "chamferMill": "Chamfer mill", "engraver": "Engraver (V-bit)", "drill": "Drill", "spotDrill": "Spot drill",
                "threadMill": "Thread mill", "faceMill": "Face mill"}[self.value]

    @property
    def cuts_sideways(self) -> bool:
        """Does the tool cut sideways (so it can profile and pocket)?"""
        return self not in (ToolKind.DRILL, ToolKind.SPOT_DRILL)


class ToolMaterial(Enum):
    UNSPECIFIED = "unspecified"
    CARBIDE = "carbide"
    HSS = "hss"
    COBALT = "cobalt"

    @property
    def title(self) -> str:
        return "Not specified" if self is ToolMaterial.UNSPECIFIED else "HSS" if self is ToolMaterial.HSS else self.value.capitalize()


class Coating(Enum):
    UNSPECIFIED = "unspecified"
    NONE = "none"
    TIN = "tiN"
    TIALN = "tiAlN"
    ALTIN = "alTiN"
    ALCRN = "alCrN"
    ZRN = "zrN"
    DLC = "dlc"
    DIAMOND = "diamond"
    OTHER = "other"

    @property
    def title(self) -> str:
        return {"unspecified": "Not specified", "none": "Uncoated", "tiN": "TiN", "tiAlN": "TiAlN", "alTiN": "AlTiN",
                "alCrN": "AlCrN", "zrN": "ZrN", "dlc": "DLC", "diamond": "Diamond", "other": "Other / proprietary"}[self.value]


class Condition(Enum):
    NEW = "new"
    GOOD = "good"
    WORN = "worn"
    BROKEN = "broken"

    @property
    def title(self) -> str:
        return self.value.capitalize()


@dataclass
class ToolPreset:
    """A cutting-data preset that came with the tool (kept for reference)."""

    name: str
    rpm: float
    feed: float  # mm/min
    plunge_feed: float
    ramp_feed: float
    stepdown: float | None = None
    stepover: float | None = None


@dataclass
class Tool:
    id: str
    name: str
    kind: ToolKind
    vendor: str
    part_number: str
    product_link: str
    diameter: float
    shank_diameter: float
    flutes: int
    flute_length: float
    stickout: float  # length below the collet nut
    overall_length: float
    corner_radius: float  # bull nose; ball = diameter / 2; flat = 0
    tool_material: ToolMaterial
    coating: Coating
    intended_for: str
    quantity: int
    condition: Condition
    notes: str
    presets: list[ToolPreset]
    source: str
    cutting_minutes: float
    cutting_distance: float  # mm
    tip_diameter: float = 0.0
    angle: float | None = None  # half-angle of chamfer mills/engravers, or a drill's point angle
    thread_pitch: float | None = None  # thread mills: the pitch their profile is ground for
    unit_cost: float | None = None
    # Catalog definitions with incomplete published specifications: not a machining tool until measured.
    unconfirmed_specifications: list[str] | None = None

    @staticmethod
    def make(name: str, kind: ToolKind, diameter: float, shank_diameter: float, flutes: int, flute_length: float,
             stickout: float, overall_length: float, *, id: str | None = None, vendor: str = "", part_number: str = "",
             product_link: str = "", corner_radius: float = 0.0, angle: float | None = None, tip_diameter: float = 0.0,
             tool_material: ToolMaterial = ToolMaterial.CARBIDE, coating: Coating = Coating.NONE, intended_for: str = "",
             quantity: int = 1, condition: Condition = Condition.NEW, unit_cost: float | None = None, notes: str = "",
             presets: list[ToolPreset] | None = None, source: str = "", cutting_minutes: float = 0.0,
             cutting_distance: float = 0.0) -> "Tool":
        """The Swift initializer: a ball end mill's corner radius is half its diameter."""
        return Tool(id or new_id(), name, kind, vendor, part_number, product_link, diameter, shank_diameter, flutes,
                    flute_length, stickout, overall_length,
                    diameter / 2 if kind is ToolKind.BALL_END_MILL else corner_radius, tool_material, coating, intended_for,
                    quantity, condition, notes, list(presets or []), source, cutting_minutes, cutting_distance,
                    tip_diameter, angle, None, unit_cost)

    def copy(self) -> "Tool":
        return copy.deepcopy(self)

    @property
    def requires_specification_review(self) -> bool:
        return bool(self.unconfirmed_specifications)

    @property
    def summary(self) -> str:
        """'3.175 mm (1/8") ball end mill · 3 fl' style summary for lists."""
        return f"{Length.describe(self.diameter)} {self.kind.title.lower()} · {self.flutes} fl"

    @property
    def is_suggestion(self) -> bool:
        from .catalogs import ToolCatalog
        return self.source == ToolCatalog.SOURCE and self.quantity == 0

    def __hash__(self) -> int:
        return hash(self.id)


# ---------------------------------------------------------------- stock

class StockShape(Enum):
    BLOCK = "block"
    ROUND_BAR = "roundBar"
    PLATE = "plate"
    PRINTED_BLANK = "printedBlank"

    @property
    def title(self) -> str:
        return {"block": "Block", "roundBar": "Round bar", "plate": "Plate / sheet", "printedBlank": "Printed blank"}[self.value]


class StockFinish(Enum):
    """How true the faces are. Sawn stock needs a facing pass before it can be a datum."""

    SAWN = "sawn"
    MILLED = "milled"
    PRECISION_GROUND = "precisionGround"
    AS_PRINTED = "asPrinted"

    @property
    def title(self) -> str:
        return {"sawn": "Sawn / rough", "milled": "Milled square", "precisionGround": "Precision ground",
                "asPrinted": "As printed"}[self.value]


@dataclass
class StockItem:
    id: str
    material_id: str
    shape: StockShape
    size_x: float  # block/plate: x × y × z; round bar: x = diameter, y = length (z unused)
    size_y: float
    size_z: float
    quantity: int
    finish: StockFinish
    supplier: str
    location: str  # where it is in the workshop
    notes: str
    is_remnant: bool  # offcut from an earlier job
    material_snapshot: Material | None = None  # the definition selected for this stock
    unit_cost: float | None = None
    model_path: str | None = None  # printed blanks: the STEP the blank was printed from
    extrusion_axis: int | None = None  # which size runs along the extrusion (0 X, 1 Y, 2 Z)

    @staticmethod
    def make(material_id: str, size_x: float, size_y: float, size_z: float, *, id: str | None = None,
             shape: StockShape = StockShape.BLOCK, quantity: int = 1, finish: StockFinish = StockFinish.SAWN,
             unit_cost: float | None = None, supplier: str = "", location: str = "", notes: str = "",
             is_remnant: bool = False, model_path: str | None = None, material_snapshot: Material | None = None) -> "StockItem":
        return StockItem(id or new_id(), material_id, shape, size_x, size_y, size_z, quantity, finish, supplier, location,
                         notes, is_remnant, material_snapshot, unit_cost, model_path)

    def copy(self) -> "StockItem":
        return copy.deepcopy(self)

    def __hash__(self) -> int:
        return hash(self.id)

    @property
    def material(self) -> Material | None:
        if self.material_snapshot is not None and self.material_snapshot.id == self.material_id:
            return self.material_snapshot
        return MaterialLibrary.material(self.material_id)

    @property
    def envelope(self) -> Vec3:
        """Bounding box of the stock, mm."""
        if self.shape is StockShape.ROUND_BAR:
            return Vec3(self.size_x, self.size_y, self.size_x)
        return Vec3(self.size_x, self.size_y, self.size_z)

    @property
    def extrusion_length(self) -> float:
        e = self.envelope
        dims = (e.x, e.y, e.z)
        return dims[min(max(self.extrusion_axis, 0), 2)] if self.extrusion_axis is not None else max(dims)

    @property
    def volume(self) -> float:  # mm³
        if self.shape is StockShape.ROUND_BAR:
            return math.pi * self.size_x * self.size_x / 4 * self.size_y
        return self.size_x * self.size_y * self.size_z

    @property
    def weight(self) -> float | None:
        """Weight of one piece, grams."""
        m = self.material
        return None if m is None else self.volume / 1000 * m.density

    @property
    def size_description(self) -> str:
        if self.shape is StockShape.ROUND_BAR:
            return f"⌀{Length.mm(self.size_x)} × {Length.mm(self.size_y)} mm"
        return f"{Length.mm(self.size_x)} × {Length.mm(self.size_y)} × {Length.mm(self.size_z)} mm"

    @property
    def is_suggestion(self) -> bool:
        from .catalogs import StockCatalog
        return self.supplier == StockCatalog.SOURCE and self.quantity == 0


# ---------------------------------------------------------------- fixtures

class FixtureKind(Enum):
    UNIVERSAL_CLAMP = "universalClamp"
    VISE = "vise"
    JIG_PLATE = "jigPlate"
    TOMBSTONE = "tombstone"
    SQUARING_BOSS = "squaringBoss"
    SOFT_JAWS = "softJaws"
    PRINTED_NEST = "printedNest"
    FIXTURE_PLATE = "fixturePlate"
    T_SLOT_NUTS = "tSlotNuts"
    C_CLAMP = "cClamp"
    SQUARING_STOP = "squaringStop"
    RISER = "riser"
    OTHER = "other"

    @property
    def title(self) -> str:
        return {"universalClamp": "Universal clamp", "vise": "Vise", "jigPlate": "Jig plate", "tombstone": "Tombstone",
                "squaringBoss": "Squaring boss", "softJaws": "Soft jaws", "printedNest": "Printed nest",
                "fixturePlate": "Fixture plate", "tSlotNuts": "T-slot nuts", "cClamp": "C-clamp",
                "squaringStop": "Squaring stop", "riser": "Riser plate", "other": "Other"}[self.value]


class ClampAxis(Enum):
    X = "x"
    Y = "y"
    NONE = "none"

    @property
    def title(self) -> str:
        return "—" if self is ClampAxis.NONE else self.value.upper()


@dataclass
class Fixture:
    id: str
    name: str
    kind: FixtureKind
    quantity: int
    clamp_axis: ClampAxis  # the machine axis it clamps along
    height: float  # how far it raises the stock above the table
    isolated: bool  # electrically isolated from the bed (conductive probing works)
    notes: str
    grip_range: Range | None = None  # smallest and largest stock it grips along the clamp axis
    model_path: str | None = None  # STEP/3MF/STL (relative to resources/ or absolute)
    planning: FixturePlanningProfile | None = None
    assembly: FixtureAssemblyDefinition | None = None  # exact CAD bindings for a vetted assembly

    @staticmethod
    def make(name: str, kind: FixtureKind, *, id: str | None = None, quantity: int = 1, clamp_axis: ClampAxis = ClampAxis.NONE,
             grip_range: Range | None = None, height: float = 0.0, isolated: bool = False, model_path: str | None = None,
             notes: str = "") -> "Fixture":
        return Fixture(id or new_id(), name, kind, quantity, clamp_axis, height, isolated, notes, grip_range, model_path)

    def copy(self) -> "Fixture":
        return copy.deepcopy(self)

    def __hash__(self) -> int:
        return hash(self.id)


# ---------------------------------------------------------------- measuring, accessories

class MeasuringKind(Enum):
    CALIPER = "caliper"
    MICROMETER = "micrometer"
    DEPTH_MICROMETER = "depthMicrometer"
    HEIGHT_GAUGE = "heightGauge"
    DIAL_INDICATOR = "dialIndicator"
    TEST_INDICATOR = "testIndicator"
    EDGE_FINDER = "edgeFinder"
    TOUCH_PROBE = "touchProbe"
    GAUGE_PINS = "gaugePins"
    GAUGE_BLOCKS = "gaugeBlocks"
    RADIUS_GAUGE = "radiusGauge"
    THREAD_GAUGE = "threadGauge"
    FEELER_GAUGE = "feelerGauge"
    LOUPE = "loupe"
    SURFACE_PLATE = "surfacePlate"

    @property
    def title(self) -> str:
        return {"caliper": "Caliper", "micrometer": "Outside micrometer", "depthMicrometer": "Depth micrometer",
                "heightGauge": "Height gauge", "dialIndicator": "Dial indicator", "testIndicator": "Test indicator",
                "edgeFinder": "Edge finder", "touchProbe": "Touch probe / touch plate", "gaugePins": "Gauge pins",
                "gaugeBlocks": "Gauge blocks", "radiusGauge": "Radius gauge", "threadGauge": "Thread gauge",
                "feelerGauge": "Feeler gauge", "loupe": "Loupe", "surfacePlate": "Surface plate"}[self.value]


@dataclass
class MeasuringTool:
    id: str
    name: str
    kind: MeasuringKind
    quantity: int
    notes: str
    range: Range | None = None  # measuring range, mm
    resolution: float | None = None  # smallest step it reads, mm
    accuracy: float | None = None  # ± mm

    @staticmethod
    def make(name: str, kind: MeasuringKind, *, range: Range | None = None, resolution: float | None = None,
             accuracy: float | None = None, quantity: int = 1, notes: str = "") -> "MeasuringTool":
        return MeasuringTool(new_id(), name, kind, quantity, notes, range, resolution, accuracy)


class AccessoryKind(Enum):
    COLLET = "collet"
    LUBRICANT = "lubricant"
    ADHESIVE = "adhesive"
    DOWEL_PIN = "dowelPin"
    TAPE = "tape"
    DEBURRING = "deburring"
    POLISHING = "polishing"
    OTHER = "other"

    @property
    def title(self) -> str:
        return {"collet": "Collet", "lubricant": "Lubricant", "adhesive": "Adhesive", "dowelPin": "Dowel pins",
                "tape": "Tape", "deburring": "Deburring", "polishing": "Polishing", "other": "Other"}[self.value]


@dataclass
class Accessory:
    id: str
    name: str
    kind: AccessoryKind
    quantity: int
    notes: str
    size: float | None = None  # collets: bore in mm; dowel pins: diameter

    @staticmethod
    def make(name: str, kind: AccessoryKind, *, size: float | None = None, quantity: int = 1, notes: str = "") -> "Accessory":
        return Accessory(new_id(), name, kind, quantity, notes, size)


from ..plan.fixture_assembly import FixtureAssemblyDefinition  # noqa: E402
from ..plan.workholding_profile import FixturePlanningProfile  # noqa: E402
