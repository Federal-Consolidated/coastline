"""A guided job built around G-code that already exists: an old .dd job, another CAM program's
output, or your own. Port of Program/ProgramJob.swift. On disk a job is a folder: `job.json`,
`programs/*.nc` and `models/*.step`. Jobs are written by hand too: a missing key takes its default."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from .. import codable


@dataclass
class Choice:
    id: str
    title: str
    detail: str | None = None


@dataclass
class Condition:
    """True when the option's chosen value is one of `one_of`."""

    option: str
    one_of: list[str]


@dataclass
class Option:
    """A choice the operator makes before starting (pocket width, where to start…)."""

    id: str
    title: str
    choices: list[Choice]
    default_choice: str = ""
    detail: str | None = None
    when: list[Condition] = field(default_factory=list)

    @staticmethod
    def from_json(d) -> "Option":
        choices = codable.from_json(list[Choice], d["choices"])
        default = d.get("defaultChoice")
        if default is None:
            default = choices[0].id if choices else ""
        return Option(d["id"], d["title"], choices, default, d.get("detail"),
                      codable.from_json(list[Condition], d.get("when") or []))


@dataclass
class ToolSpec:
    id: str
    name: str
    kind: str  # "End mill" or "Drill"
    diameter: float  # mm
    collet: str  # e.g. '1/4"' or '4 mm (5/32")'
    fitting: str | None = None
    note: str | None = None
    shape: str | None = None  # "flat", "ball", "drill" or "disc" (for the cut simulation)
    disc_thickness: float | None = None
    shank_diameter: float | None = None


class ModelRole(Enum):
    PART = "part"
    STOCK = "stock"
    FIXTURE = "fixture"


@dataclass
class Model:
    """A 3D model shown in the setup views."""

    id: str
    title: str
    file: str  # relative to the job folder
    role: ModelRole


@dataclass
class Placement:
    """Model → work frame: each work axis is a model axis ("x", "-z"…), then the offset (mm)."""

    axes: list[str] = field(default_factory=lambda: ["x", "y", "z"])
    offset: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])

    @property
    def rows(self) -> list[tuple[int, float]]:
        out = []
        for a in self.axes[:3]:
            sign = -1.0 if a.startswith("-") else 1.0
            axis = {"x": 0, "y": 1, "z": 2}.get(a.lstrip("-+").lower(), 0)
            out.append((axis, sign))
        return out

    def apply(self, p, normal: bool = False) -> tuple[float, float, float]:
        r = self.rows
        o = [0.0, 0.0, 0.0] if normal else [self.offset[k] if k < len(self.offset) else 0.0 for k in range(3)]
        return (r[0][1] * p[r[0][0]] + o[0], r[1][1] * p[r[1][0]] + o[1], r[2][1] * p[r[2][0]] + o[2])


class Purpose(Enum):
    MOVE = "move"  # homes or moves the machine to a position
    WARMUP = "warmup"
    PROBE = "probe"  # finds the part and sets the work offset
    CUT = "cut"


@dataclass
class ProgramFile:
    id: str
    title: str
    file: str  # relative to the job folder
    purpose: Purpose
    tool: str | None = None  # the tool in the spindle while it runs
    changes: list[str] = field(default_factory=list)  # what Coastline changed to run it here
    source: str | None = None  # the original file name


@dataclass
class MachinePose:
    """A setup's work zero in machine coordinates, with the tool's stick-out it was found with."""

    work_zero: list[float]
    stickout: float


class StepKind(Enum):
    INSTRUCTION = "instruction"
    TOOL_CHANGE = "toolChange"
    MOUNT = "mount"
    RUN = "run"
    MEASURE = "measure"


@dataclass
class Check:
    what: str
    expected: float  # mm
    tolerance: float


@dataclass
class Step:
    id: str
    kind: StepKind
    title: str
    text: str | None = None
    items: list[str] = field(default_factory=list)
    caution: str | None = None
    program: str | None = None
    tool: str | None = None
    check: Check | None = None
    when: list[Condition] = field(default_factory=list)


@dataclass
class JobSetup:
    """One clamping of the part, with the steps done in it."""

    id: str
    title: str
    steps: list[Step]
    summary: str = ""
    when: list[Condition] = field(default_factory=list)
    placements: dict[str, Placement] = field(default_factory=dict)
    machine: MachinePose | None = None


@dataclass
class ProgramJob:
    id: str
    title: str
    summary: str = ""
    machines: list[str] = field(default_factory=list)
    material: str | None = None
    requirements: list[str] = field(default_factory=list)
    options: list[Option] = field(default_factory=list)
    tools: list[ToolSpec] = field(default_factory=list)
    models: list[Model] = field(default_factory=list)
    programs: list[ProgramFile] = field(default_factory=list)
    setups: list[JobSetup] = field(default_factory=list)

    def choices(self, chosen: dict[str, str] | None = None) -> dict[str, str]:
        chosen = chosen or {}
        return {o.id: chosen.get(o.id, o.default_choice) for o in self.options}

    def applies(self, conditions: list[Condition], chosen: dict[str, str]) -> bool:
        c = self.choices(chosen)
        return all(cond.option in c and c[cond.option] in cond.one_of for cond in conditions)

    def plan(self, chosen: dict[str, str]) -> list[tuple[JobSetup, list[Step]]]:
        """The setups and steps that run for these choices, in order."""
        out = []
        for setup in self.setups:
            if not self.applies(setup.when, chosen):
                continue
            steps = [s for s in setup.steps if self.applies(s.when, chosen)]
            if steps:
                out.append((setup, steps))
        return out

    def program(self, id: str | None) -> ProgramFile | None:
        return next((p for p in self.programs if p.id == id), None)

    def setup_running(self, program_id: str, chosen: dict[str, str]) -> JobSetup | None:
        return next((s for s, steps in self.plan(chosen) if any(st.program == program_id for st in steps)), None)

    def tool(self, id: str | None) -> ToolSpec | None:
        return next((t for t in self.tools if t.id == id), None)

    @staticmethod
    def load(folder: Path) -> "ProgramJob":
        return codable.decode(ProgramJob, (Path(folder) / "job.json").read_bytes())

    def save(self, folder: Path) -> None:
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "job.json").write_bytes(codable.encode(self, pretty=True, sort_keys=True, escape_slashes=False))

    def problems(self, folder: Path) -> list[str]:
        """Problems that stop the job from running: missing programs or tools, dangling ids."""
        folder = Path(folder)
        problems = []
        for p in self.programs:
            if not (folder / p.file).exists():
                problems.append(f"Program file {p.file} is missing.")
        for s in self.setups:
            for step in s.steps:
                if step.kind is StepKind.RUN and self.program(step.program) is None:
                    problems.append(f"{s.title} ▸ {step.title}: no program {step.program or '-'}.")
                if step.kind is StepKind.TOOL_CHANGE and self.tool(step.tool) is None:
                    problems.append(f"{s.title} ▸ {step.title}: no tool {step.tool or '-'}.")
        model_ids = {m.id for m in self.models}
        for s in self.setups:
            for mid in s.placements:
                if mid not in model_ids:
                    problems.append(f"{s.title} uses the unknown model {mid}.")
        for s in self.setups:
            if s.machine is not None and (len(s.machine.work_zero) != 3 or s.machine.stickout <= 0):
                problems.append(f"{s.title}: the machine entry needs a work zero (X, Y, Z) and a stick-out above 0.")
        for m in self.models:
            if not (folder / m.file).exists():
                problems.append(f"Model file {m.file} is missing.")
        option_ids = {o.id for o in self.options}
        conditions = [c for s in self.setups for c in s.when + [c2 for st in s.steps for c2 in st.when]] + [c for o in self.options for c in o.when]
        for c in conditions:
            if c.option not in option_ids:
                problems.append(f"A condition uses the unknown option {c.option}.")
        return problems
