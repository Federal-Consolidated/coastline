"""Builds the guided job the runner steps through: mount the stock → edge-find → install each
tool → touch off → cut, with air cuts and measuring checkpoints. Port of Export/GuidedJob.swift
(GuidedJobBuilder, AirCut, FacingProgram)."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

from ...mill.project import Job, Step
from ..geometry import swift_round
from ..ids import new_id
from ..inventory.items import MeasuringKind
from ..machine.profile import MachineProfile
from ..plan import edge_finding as EdgeFinding
from ..plan import reference_bores as ReferenceBores
from ..plan.operation import ReferenceFeature
from ..plan.setup_side import SetupSide
from ..post import grbl_post as GRBLPost
from ..post.toolpath import Move, OperationToolpath, Role
from ..units import Length
from . import finishing_guide as FinishingGuide

n = ReferenceBores.n


class WorkholdingNotReviewed(Exception):
    pass


@dataclass
class Program:
    tool: object
    gcode: str
    operation_names: list[str]
    minutes: float
    side: int = 0  # 0 = side A, 1 = side B (after flipping the stock)
    touch_z: float = 0.0  # where the face is when this tool is touched off (work Z)
    reference: ReferenceFeature | None = None  # cuts reference features (bores, windows)
    surface_probe: str | None = None  # probes the face first (SurfaceProbe.program)
    workholding: object | None = None  # LibraryWorkholdingPlan.Step


@dataclass
class Probing:
    """How the guided job finds the stock's position after each clamping."""

    lower_x_reachable: list[bool] = field(default_factory=lambda: [True, True])
    upper_x_reachable: list[bool] = field(default_factory=lambda: [True, True])
    bores: ReferenceBores.Plan | None = None  # side B's zero from side A's reference bores


@dataclass
class Checkpoint:
    after_program: int
    what: str
    expected: float
    tolerance: float


@dataclass
class Input:
    part_name: str
    material: object
    stock: object
    stock_size: tuple[float, float, float]  # X (vertical), Y (left–right), Z (toward the spindle)
    setup_name: str
    programs: list[Program]
    checkpoints: list[Checkpoint]
    measuring: list
    setup_image: bytes | None
    face_allowance: float = 0.5
    tabs: object | None = None  # HoldingTabs on the side that cuts through
    flip_image: bytes | None = None
    flip_axis: int | None = None
    custom_holding: object | None = None  # Setup.CustomFixture
    probing: Probing = field(default_factory=Probing)
    tool_change_z: float | None = None
    tool_change_y: float | None = None


# ---------------------------------------------------------------- fixed helper programs

def tool_change_moves(machine: MachineProfile, z: float | None, y: float | None = None) -> list[str]:
    moves = list(machine.tool_change_moves)
    if z is not None:
        k = next((i for i in range(len(moves) - 1, -1, -1) if "Z" in moves[i].upper()), None)
        if k is not None:
            moves[k] = f"G53 G0 Z{n(z)}"
    if y is not None:
        k = next((i for i in range(len(moves) - 1, -1, -1) if "Y" in moves[i].upper()), None)
        if k is not None:
            moves[k] = f"G53 G0 Y{n(y)}"
    return moves


def helper_files(machine: MachineProfile, tool_change_z: float | None = None, tool_change_y: float | None = None) -> dict[str, str]:
    return {
        "Code/home.nc": "$H\n",
        "Code/tool_change_position.nc": "\n".join(["G21 G90"] + tool_change_moves(machine, tool_change_z, tool_change_y)) + "\n",
        "Code/edgefinder_spin.nc": f"G21 G90\nM3 S{int(machine.probe_spindle_rpm)}\n",
        "Code/spindle_stop.nc": "M5\n",
        "Code/store_x_low.nc": "G10 L20 P2 X0\nG4 P0.5\n",
        "Code/store_x_high.nc": "G10 L20 P3 X0\nG4 P0.5\n",
        "Code/set_x_centre.nc": "M100 G55X G56X G54X\nG4 P0.5\n",
        "Code/store_y_left.nc": "G10 L20 P2 Y0\nG4 P0.5\n",
        "Code/store_y_right.nc": "G10 L20 P3 Y0\nG4 P0.5\n",
        "Code/set_y_centre.nc": "M100 G55Y G56Y G54Y\nG4 P0.5\n",
        "Code/store_z.nc": "G10 L20 P1 Z0\nG4 P0.5\nG54\n",
    }


# ---------------------------------------------------------------- tool changes, touch-off

def tool_change_steps(title: str, tool, previous=None, note: str = "") -> list[Step]:
    shank = Length.describe(tool.shank_diameter)
    swap_collet = abs(previous.shank_diameter - tool.shank_diameter) > 0.01 if previous is not None else True
    inside = tool.overall_length - tool.stickout
    if swap_collet:
        if previous is None:
            collet = (f"\n**The collet** must be the **{shank}** one. If another is in the nut, unscrew the nut completely, pop that collet out and snap the {shank} one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out (one that isn't snapped in lets the tool walk out mid-cut). Thread the nut back on a few turns by hand.\n")
        else:
            collet = (f"\n**Change the collet** to the **{shank}** one (the last tool had a {Length.describe(previous.shank_diameter)} shank): unscrew the nut completely, pop the old collet out and snap the new one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out. Thread the nut back on a few turns by hand.\n")
    else:
        collet = ""
    take_out = f"the {previous.name}" if previous is not None else "the tool in the spindle, if there is one"
    return [
        step("Tool Change Position", markdown=(
            "Click Next: the machine homes, lowers the table to the bottom of its travel (the stock as far from the spindle as it goes), moves the gantry to where there's room and brings the spindle forward, out of the machine towards you, so the collet nut stands free with room for both wrenches.\n"
            "\n"
            "Leave the stock clamped: the zero found for it stays valid."), gcode="Code/tool_change_position.nc", timeout=90),
        step(title, markdown=(
            f"**You need** the 12 mm and 17 mm wrenches{f' and the {shank} ER-11 collet' if swap_collet else ''}.{'' if not note else ' ' + note}\n"
            "\n"
            f"**Take out {take_out}**\n"
            "1. Pull the chip fan off the collet nut.\n"
            "2. Put the **12 mm wrench on the spindle's flats** and the **17 mm wrench on the collet nut**.\n"
            "3. Hold the 12 mm wrench still and turn the 17 mm one to loosen the nut. Unscrew it a little by hand and pull the tool out.\n"
            f"{collet}\n"
            f"**Fit the {tool.name}**\n"
            f"4. Slide it into the collet so **{Length.mm(tool.stickout)} mm sticks out** below the nut (measure it){'' if inside < 8 else '; at least 8 mm of the shank stays in the collet'}.\n"
            "5. Hold it there and tighten the nut by hand as far as it goes.\n"
            "6. With both wrenches as before, tighten until it won't easily go further. Don't force it.\n"
            "7. Push the chip fan back over the nut, hexagon side first."),
            popup=("Tool in?", f"Is the {tool.name} tight in the collet with {Length.mm(tool.stickout)} mm sticking out?"), no_step="-0"),
    ]


def paper_touch_off(where: str, extra: str = "") -> str:
    """Paper touch-off by hand (manual §4.6.2): the spindle stopped, 1 → 0.1 → 0.01 mm steps."""
    return ("The spindle stays **stopped**. In **Machine Control**:\n"
            f"1. Jog the tool over {where} and toward the face in 1 mm steps until it's 1–2 mm away.\n"
            "2. Slide a strip of paper between the tip and the face and keep wiggling it.\n"
            "3. Jog in 0.1 mm steps until the paper drags. If it's pinched tight, back off 0.1 mm.\n"
            f"4. Switch to 0.01 mm steps and jog until the paper just stops moving. Stop there.{extra}")


@dataclass
class Approach:
    """Where the stock should be in the current zero (G54) after it was clamped again.
    `z_shift`: how much longer the tool in the spindle is than the one that set Z0."""

    centre: tuple[float, float, float]
    size: tuple[float, float, float]
    z_shift: float

    def beside(self, axis: int, side: float, gap: float, radius: float) -> list[float]:
        p = [self.centre[0], self.centre[1]]
        half = self.size[0] / 2 if axis == 0 else self.size[1] / 2
        p[axis] += side * (half + gap + radius)
        return p

    def program(self, axis: int, side: float, radius: float, front: float = 6) -> str:
        p = self.beside(axis, side, 4, radius)
        z = self.centre[2] + front + self.z_shift
        return f"G21 G90\nG53 G0 Z-1\nG54 G0 X{n(p[0])} Y{n(p[1])}\nG0 Z{n(z + 6)}\nG1 Z{n(z)} F400\n"

    def probe_program(self, axis: int, side: float, radius: float, depth: float) -> str:
        p = self.beside(axis, side, 3, radius)
        return f"G21 G90\nG54 G0 Z5\nG0 X{n(p[0])} Y{n(p[1])}\nG38.3 Z{n(-depth)} F150\n"


# ---------------------------------------------------------------- build

def build(inp: Input, machine: MachineProfile | None = None) -> tuple[list[Job], dict[str, bytes]]:
    machine = machine or MachineProfile.standard()
    files = {k: v.encode() for k, v in helper_files(machine, inp.tool_change_z, inp.tool_change_y).items()}
    if inp.setup_image is not None:
        files["Image/setup.png"] = inp.setup_image
    if inp.flip_image is not None:
        files["Image/flip.png"] = inp.flip_image
    return [part_job(inp, machine, files)], files


def validate_workholding(inp: Input) -> None:
    for program in inp.programs:
        s = program.workholding
        if s is not None and not s.reviewed:
            raise WorkholdingNotReviewed(f"Review placement and secure grip for {s.title} before exporting or running.")


def _mins(m: float) -> int:
    return int(swift_round(m))


def part_job(i: Input, machine: MachineProfile, files: dict[str, bytes]) -> Job:
    count = len(i.programs)
    job = Job(title=f"{i.setup_name} · {i.part_name}",
              prompt=f"Machines {i.part_name} from {i.material.name}, in {count} tool program{'' if count == 1 else 's'}.")
    steps: list[Step] = []
    size = i.stock_size
    tool_list = "\n".join(
        f"{k + 1}. **{p.tool.name}**, stick-out {Length.mm(p.tool.stickout)} mm ({', '.join(p.operation_names)}, about {_mins(p.minutes)} min)"
        for k, p in enumerate(i.programs))
    steps.append(step("Before You Start", markdown=(
        "This job was planned by **Coastline** for your machine.\n"
        "\n"
        f"**Material** {i.material.name}. {i.material.lubricant}\n"
        "\n"
        f"**Stock** {Length.mm(size[0])} mm tall (X) × {Length.mm(size[1])} mm wide (Y) × {Length.mm(size[2])} mm thick (toward the spindle).\n"
        "\n"
        "**Tools, in order**\n"
        f"{tool_list}\n"
        "\n"
        "Stay with the machine while it cuts, and keep a hand near the E-stop. Never use compressed air on the machine; vacuum chips instead.")))
    steps.append(step("Home the Machine", text="Click Next to home all axes.", gcode="Code/home.nc", timeout=60))
    setup_png = "" if i.setup_image is None else "Image/setup.png"
    flip_png = "" if i.flip_image is None else "Image/flip.png"
    first_holding = i.programs[0].workholding if i.programs else None
    if i.custom_holding is not None:
        c = i.custom_holding
        steps.append(step("Mount the Stock", markdown=(
            f"Secure the stock in **{c.name}** with its {Length.mm(size[0])} × {Length.mm(size[1])} mm face toward the spindle.\n"
            "\n"
            f"Stock bottom: **{Length.mm(c.height)} mm above the table**. Stock face: **{Length.mm(c.face_protrusion)} mm past the table's front edge**.\n"
            "\n"
            f"{c.notes}\n"
            "\n"
            "The face toward the spindle is **Z0**; its centre is **X0 Y0**. Edge-find and touch off after mounting.\n"
            "\n"
            "**Custom fixture geometry is not included in collision checks.** Check cutter, shank and holder clearance to your jaws and fasteners. Keep the part secured independently of material removed by these programs."),
            image=setup_png, popup=("Stock secured?", "Is the stock secured in your fixture, with cutter and holder clearance checked?")))
    elif first_holding is not None:
        h = first_holding
        steps.append(step(f"Mount the Stock · {h.title}", markdown=(
            f"{h.instructions}\n"
            "\n"
            "The face toward the spindle is **Z0**; its centre is **X0 Y0**. The next steps establish work zero."),
            image=setup_png, popup=("Stock secured?", f"Is the stock secured in {h.fixture.name}, with the defined grip patches intact?")))
    else:
        steps.append(step("Mount the Stock", markdown=(
            f"Secure the stock with its **{Length.mm(size[1])} × {Length.mm(size[0])} mm face toward the spindle**, square to the spindle.\n"
            "\n"
            "The face toward the spindle becomes **Z0**; the middle of that face becomes **X0 Y0**. The next steps find the stock's real edges and face, and every program follows them."),
            image=setup_png, popup=("Stock clamped?", "Is the stock clamped tight and square to the spindle?")))
    pr = i.probing
    # The tool in the spindle with its Z set (None after the edge finder or a flip), and the
    # last one fitted (for the tool change: which collet it had, how long it was).
    state = {"spindle": None, "fitted": None}

    def touch_z_file(z: float) -> str:
        name = "Code/store_z" + ("" if abs(z) < 1e-9 else "_" + n(z).replace("-", "m").replace(".", "_")) + ".nc"
        if abs(z) > 1e-9:
            files[name] = f"G10 L20 P1 Z{n(z)}\nG4 P0.5\nG54\n".encode()
        return name

    def install_tool(k: int, p: Program) -> None:
        spindle = state["spindle"]
        if spindle is not None and spindle.id == p.tool.id:
            return
        steps.extend(tool_change_steps(f"Change to Tool {k}", p.tool, state["fitted"]))
        state["fitted"] = p.tool
        faced = (f" The face was milled {Length.mm(-p.touch_z)} mm down by an earlier program: touch off anywhere on the milled face (Coastline stores it as Z{n(p.touch_z)})."
                 if p.touch_z < -1e-6 else "")
        steps.append(step(f"Touch Off Tool {k} on the Face", markdown=(
            "Touch off the face by hand with paper for this setup.\n"
            "\n"
            + paper_touch_off("a solid spot of the stock face (the frame, not over a cut)", "" if not faced else "\n\n" + faced)),
            popup=("Paper pinched?", "Is the paper just pinched between the tool and the stock face?"), no_step="-0"))
        steps.append(step(f"Record Z0 for Tool {k}", text=f"Click Next to store this height{' as Z0' if abs(p.touch_z) < 1e-9 else ''} .",
                          gcode=touch_z_file(p.touch_z)))
        state["spindle"] = p.tool

    def find_edges(side: int, first: int) -> None:
        holding = i.programs[first].workholding
        if holding is not None:
            steps.append(step(f"Establish Work Zero · {holding.title}", markdown=(
                "In Machine Control, establish **G54 X0 Y0 at the original stock-face centre and Z0 at the original stock face**, using this fixture's locating datum. Account for material removed in previous setups.\n"
                "\n"
                "Do not use an edge or surface that has been machined away as though it were the original blank. Use the fixture's repeatable reference or a measured offset. This step does not move or probe automatically.\n"
                "\n"
                f"{holding.fixture.notes}"),
                popup=("Work zero verified?", f"Have you established and verified G54 for {holding.fixture.name} using its locating reference?")))
            state["spindle"] = None
            return
        lower, upper = pr.lower_x_reachable[min(side, 1)], pr.upper_x_reachable[min(side, 1)]
        # Side B: turned about the vertical in the same clamps, so it sits where side A did.
        last_z = i.programs[:first][-1].tool if side == 1 and i.custom_holding is None and first > 0 else None
        near = Approach((0.0, 0.0, 0.0), size, EdgeFinding.TOOL.stickout - last_z.stickout) if last_z is not None else None
        steps.extend(edge_find_steps(machine, lower=lower, upper=upper, height=size[0], previous=state["fitted"], approach=near,
                                     tag=f"s{side}p{first}", files=files))
        state["spindle"] = None
        state["fitted"] = EdgeFinding.TOOL

    find_edges(0, 0)
    for k, p in enumerate(i.programs):
        num = k + 1
        prev_holding = i.programs[k - 1].workholding if k > 0 else None
        if k > 0 and p.workholding is not None and (prev_holding is None or p.workholding.id != prev_holding.id):
            holding = p.workholding
            before = i.programs[k - 1].side
            if p.side == before:
                flip = "Keep the part's current orientation. "
            elif p.side >= 2:
                flip = ""  # its instructions say how to turn it
            elif p.side == 1 and before == 0:
                flip = ("Roll the stock over about its length for side B. " if i.flip_axis == 1
                        else "Turn the stock front-to-back about its vertical axis for side B. ")
            else:
                flip = f"Turn the stock so its {SetupSide.words(p.side)} faces the spindle. "
            steps.append(step(f"Change Workholding · {holding.title}", markdown=(
                f"Stop the spindle and move the tool clear by hand before releasing any fixture. {flip}\n"
                "\n"
                f"{holding.instructions}\n"
                "\n"
                "This continues the same partially machined stock. Do not substitute a fresh blank. The next steps establish work zero again; the previous fixture's zero is not reused."),
                popup=("New setup secured?", f"Is the stock secured in {holding.fixture.name}, with the defined grip patches intact and the tool clear?")))
            state["spindle"] = None
            find_edges(p.side, k)
        elif p.workholding is None and p.side == 1 and (k == 0 or i.programs[k - 1].side == 0):
            if i.custom_holding is not None:
                c = i.custom_holding
                turn = "Roll the stock over about its length" if i.flip_axis == 1 else "Turn the stock front-to-back about its vertical axis"
                steps.append(step("Flip the Stock", markdown=(
                    f"Vacuum the chips. {turn} and secure it in **{c.name}** for side B.\n"
                    "\n"
                    f"{c.notes}\n"
                    "\n"
                    "Check cutter and holder clearance to the fixture again. The next steps find the stock's edges and face afresh; the previous clamping's position is not assumed."),
                    image=flip_png, popup=("Stock secured for side B?", "Is the stock turned front-to-back and secured in your fixture with clearance checked?")))
            else:
                how = ("Release the stock and **roll it over** about its length: the face that was at the back now faces the spindle, and the face that was on the table is now on top. Its ends stay where they were. Secure it again."
                       if i.flip_axis == 1 else
                       "Release the stock and **turn it front-to-back** about its vertical axis: the face that was at the back now faces the spindle, and the end that was on the left is now on the right. Secure it again.")
                bores_note = " Side B's edges give a first zero; the reference bores then set it exactly." if pr.bores is not None else ""
                steps.append(step("Flip the Stock", markdown=(
                    f"Side A is done. Vacuum the chips from the stock, the fixture and the table{', and out of the two reference bores in the frame' if pr.bores is not None else ''}.\n"
                    "\n"
                    f"{how}\n"
                    "\n"
                    "The next steps find the stock's edges and face afresh." + bores_note),
                    image=flip_png, gcode="Code/tool_change_position.nc", timeout=90,
                    popup=("Flipped and secured?", "Is the stock turned front-to-back and secured again?")))
            state["spindle"] = None
            find_edges(1, k)
        cut_path, air_path = f"Code/T{num}_cut.nc", f"Code/T{num}_aircut.nc"
        files[cut_path] = p.gcode.encode()
        files[air_path] = air_cut(p.gcode).encode()
        install_tool(num, p)
        if p.surface_probe is not None:
            probe_path = f"Code/T{num}_surface.nc"
            files[probe_path] = p.surface_probe.encode()
            points = p.surface_probe.count("M111")
            steps.append(step("Probe the Surface", markdown=(
                f"The engraving follows the real face, not the CAD: the tool feels it at **{points} points** over the text. It turns slowly backwards and creeps down at each one until it touches (the stock is insulated in the fixture; the probe wire stays on the fixture).\n"
                "\n"
                "The points go into the sender's contour map (M111); the engraving turns the compensation on (M112), so its depth stays the same everywhere, even on a face that isn't quite flat or square."),
                gcode=probe_path, timeout=240, popup=("Wire on the fixture?", "Is the probe wire plugged in and fixed to the fixture, and the tool clean?")))
        steps.append(step("Air Cut First?", markdown=(
            "The first time you run a program, run it **10 mm above the stock with the spindle off**. Watch that every move goes where you expect."),
            popup=("Run an air cut?", f"Run program {num} as an air cut first? Choose No to skip straight to cutting."), no_step="+2"))
        steps.append(step(f"Air Cut · Program {num}", text="The tool moves 10 mm above the work with the spindle off.", gcode=air_path))
        if p.reference is ReferenceFeature.BORES:
            depth = pr.bores.depth_a if pr.bores is not None else 0
            ref_note = (f"\n\nThis program also bores **two reference holes** in the frame (⌀{n(ReferenceBores.DIAMETER)} mm, {Length.mm(depth)} mm deep). Side B finds its zero from them: keep them clean.")
        elif p.reference is ReferenceFeature.WINDOWS:
            depth = pr.bores.window_depth if pr.bores is not None else 0
            ref_note = (f"\n\nIt opens the two **reference bores** from this side (⌀{n(ReferenceBores.WINDOW_DIAMETER)} mm windows, {Length.mm(depth)} mm deep) so they can be found next.")
        else:
            ref_note = ""
        steps.append(step(f"Cut · Program {num}", markdown=(
            f"**{' → '.join(p.operation_names)}** with {p.tool.name}. About {_mins(p.minutes)} minutes.{ref_note}\n"
            "\n"
            f"{i.material.chips}"), gcode=cut_path))
        windows = p.reference is ReferenceFeature.WINDOWS
        steps.append(step("Clear the Chips", markdown=(
            f"Vacuum the chips from the stock, clamps and table{', and out of both reference bores (a chip in a bore throws the probing off)' if windows else ''}. Never use compressed air: it drives chips into the machine's bearings.")))
        if windows and pr.bores is not None:
            steps.extend(bore_pickup_steps(pr.bores, p.tool, False, files))
            state["spindle"] = None
        for c in i.checkpoints:
            if c.after_program == k:
                steps.extend(checkpoint_steps(c, i.measuring))
    two_sided = any(p.side == 1 for p in i.programs)
    if i.tabs is not None:
        t = i.tabs
        from ..materials import MaterialFamily
        cutters = " or flush cutters" if i.material.family in (MaterialFamily.WAX, MaterialFamily.PLASTIC) else ""
        free = (f"cut the part free. It hangs in the frame on **{t.count} small tabs** ({Length.mm(t.width)} mm wide, {Length.mm(t.height)} mm thick): cut each one close to the part with a jeweller's saw{cutters}, then file and sand the stubs flush")
    elif two_sided and i.custom_holding is None:
        free = "saw through the thin web to free the part, then file the web marks flush"
    else:
        free = "deburr the part"
    finishing = "\n".join("- " + s for s in FinishingGuide.steps(i.material))
    steps.append(step("Done", markdown=(
        f"Home the machine, unclamp the stock and {free}.\n"
        "\n"
        "**Finishing**\n"
        f"{finishing}\n"
        "\n"
        "Log the result in Coastline's job journal: measured sizes, finish and any chatter. Coastline uses them to tune the next job."),
        gcode="Code/home.nc"))
    job.steps = steps
    return job


# ---------------------------------------------------------------- edge finding

def edge_find_steps(machine: MachineProfile, note: str = "", lower: bool = True, upper: bool = True, height: float = 0,
                    previous=None, approach: Approach | None = None, tag: str = "",
                    files: dict[str, bytes] | None = None) -> list[Step]:
    """Edge finding to the stock centre in X and Y, as the maker's cutcodes do it: store both
    edges in G55/G56, then M100 puts their midpoint into G54. An X edge out of reach: X0 from
    the other edge and the stock's height instead."""
    files = files if files is not None else {}
    s: list[Step] = []
    finder = EdgeFinding.TOOL
    r = finder.diameter / 2
    if not (previous is not None and EdgeFinding.is_edge_finder(previous)):
        s.extend(tool_change_steps("Fit the Edge Finder", finder, previous,
                                   note=f"The stock was just clamped, so its edges are found again: everything after this works from them. The **edge finder** spins at {int(machine.probe_spindle_rpm)} RPM while you search. {note}"))
    elif note:
        s.append(step("Edge Finder Still In", markdown=f"The edge finder is still in the spindle. {note}"))
    s.append(step("Start the Edge Finder", text="Click Next to spin the edge finder.", gcode="Code/edgefinder_spin.nc"))

    def edge(title: str, where: str, store: str, axis: int, side: float) -> None:
        if approach is not None:
            f = f"Code/near_{tag}_{'x' if axis == 0 else 'y'}{'lo' if side < 0 else 'hi'}.nc"
            files[f] = approach.program(axis, side, r).encode()
            s.append(step(f"Move Near the {title}", markdown=f"Click Next: the machine drives the spinning finder to about 4 mm outside {where}, 6 mm in front of the face, from where the stock should be. It can't feel the edge: if the stock sits elsewhere, stop and jog instead.",
                          gcode=f, timeout=60))
        s.extend(_edge_pair(title, where, store, nearby=approach is not None))

    if lower and upper:
        edge("Lower Edge (X)", "the **lower** edge of the stock", "Code/store_x_low.nc", 0, -1)
        edge("Upper Edge (X)", "the **upper** edge of the stock", "Code/store_x_high.nc", 0, 1)
        s.append(step("Centre in X", text="Click Next to set X0 halfway between the two edges.", gcode="Code/set_x_centre.nc"))
    else:
        use_lower = lower
        name = "x_from_lower.nc" if use_lower else "x_from_upper.nc"
        files["Code/" + name] = ReferenceBores.single_edge_program("X", 1 if use_lower else -1, (-1 if use_lower else 1) * height / 2,
                                                                   EdgeFinding.TOOL.diameter / 2, False).encode()
        this, other = ("lower", "upper") if use_lower else ("upper", "lower")
        s.append(step(f"Find the {this.capitalize()} Edge (X)", markdown=(
            f"The {other} edge is **out of the machine's reach** in this clamping, so X0 comes from the {this} edge and the stock's height, **{Length.mm(height)} mm** (measure it: if it differs, the part shifts by half the difference).\n"
            "\n"
            + edge_finding(f"the **{this}** edge")),
            popup=("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), no_step="-0"))
        s.append(step("Set X0 from the Edge", text="Click Next to set X0 half the stock's height from this edge.", gcode="Code/" + name))
    edge("Left Edge (Y)", "the **left** edge of the stock", "Code/store_y_left.nc", 1, -1)
    edge("Right Edge (Y)", "the **right** edge of the stock", "Code/store_y_right.nc", 1, 1)
    s.append(step("Centre in Y", text="Click Next to set Y0 halfway between the two edges.", gcode="Code/set_y_centre.nc"))
    s.append(step("Stop the Spindle", text="Click Next to stop the edge finder.", gcode="Code/spindle_stop.nc"))
    return s


def bore_pickup_steps(plan: ReferenceBores.Plan, tool, electrical: bool, files: dict[str, bytes]) -> list[Step]:
    """Side B's exact zero from side A's reference bores (after the windows are open)."""
    s: list[Step] = []
    b = plan.centres_b
    s.append(step("Reference Bores", markdown=(
        f"Side A bored two ⌀{n(ReferenceBores.DIAMETER)} mm holes in the frame from the same zero as the part, and side B just opened them. Their centres are found now and **X0 Y0 is set from them**: side B then lines up with side A to a few hundredths, whatever the stock's edges are like.\n"
        "\n"
        f"Bore 1 is at X{n(b[0][0])} Y{n(b[0][1])}, bore 2 at X{n(b[1][0])} Y{n(b[1][1])} (side B). Each bore's diameter, their spacing and the line between them are checked: if anything is off (a chip, a wrong flip, the stock seated crooked) the step stops with a message instead of cutting.")))
    if electrical:
        for k in range(2):
            f = f"Code/B_bore{k + 1}.nc"
            files[f] = ReferenceBores.bore_program(plan, k, tool.diameter, True).encode()
            s.append(step(f"Find Bore {k + 1}", markdown=(
                f"Click Next: the tool goes down into bore {k + 1} ({n(-plan.probe_z)} mm deep) and touches its wall four times, turning slowly backwards."),
                gcode=f, timeout=300))
    else:
        s.append(step("Install the Edge Finder", markdown=(
            "The spindle moves to the tool-change position. Take the tool out and fit the **edge finder**: it finds the bores' walls."),
            gcode="Code/tool_change_position.nc", timeout=90))
        for k in range(2):
            over = f"Code/B_over_bore{k + 1}.nc"
            files[over] = f"G21 G90\nG53 G0 Z-1\nG54 G0 X{n(b[k][0])} Y{n(b[k][1])}\nG0 Z3\n".encode()
            s.append(step(f"Over Bore {k + 1}", text=f"Click Next to bring the edge finder over bore {k + 1}.", gcode=over, timeout=120))
            s.append(step("Start the Edge Finder", text="Click Next to spin the edge finder.", gcode="Code/edgefinder_spin.nc"))
            s.append(step(f"Into Bore {k + 1}", markdown=(
                f"In **Machine Control**, lower the edge finder into the bore to about **Z{n(plan.probe_z)}**, its tip below the wider window, in the bore's own wall."),
                popup=("In the bore?", "Is the edge finder's tip down in the narrow bore, not touching?"), no_step="-0"))
            for axis in ("X", "Y"):
                plus, minus = f"Code/B_wall_{axis}p.nc", f"Code/B_wall_{axis}m.nc"
                files[plus] = ReferenceBores.store_wall(axis, True).encode()
                files[minus] = ReferenceBores.store_wall(axis, False).encode()
                for sign, f in (("+", plus), ("−", minus)):
                    s.append(step(f"Bore {k + 1}: {sign}{axis} Wall", markdown=(
                        f"Step toward the bore's **{sign}{axis}** wall (0.1 mm, then 0.01 mm moves) until the edge finder **kicks off-centre**."),
                        popup=("Wall found?", f"Has the edge finder just kicked at the {sign}{axis} wall?"), no_step="-0"))
                    s.append(step(f"Record the {sign}{axis} Wall", text="Click Next to store this position.", gcode=f))
                centre = f"Code/B_bore{k + 1}_{axis}.nc"
                files[centre] = (ReferenceBores.store_centre(k, axis, EdgeFinding.TOOL.diameter)
                                 + f"G{55 if k == 0 else 56} G0 {axis}0\n").encode()
                s.append(step(f"Bore {k + 1}: Centre in {axis}", text=f"Click Next to store the centre in {axis} and move there.", gcode=centre))
            files["Code/B_up.nc"] = b"G53 G0 Z-1\n"
            s.append(step(f"Up Out of Bore {k + 1}", text="Click Next to raise the edge finder.", gcode="Code/B_up.nc"))
        s.append(step("Stop the Spindle", text="Click Next to stop the edge finder.", gcode="Code/spindle_stop.nc"))
    files["Code/B_bores_zero.nc"] = ReferenceBores.zero_program(plan).encode()
    s.append(step("Set X0 Y0 from the Bores", markdown=(
        "Click Next to check the two centres against each other and set X0 Y0 from them. The tool then stands over bore 1 at the top of its travel."),
        gcode="Code/B_bores_zero.nc", timeout=120))
    return s


def edge_finding(where: str, nearby: bool = False) -> str:
    """Edge finding by hand (manual §4.6.1): 1 → 0.1 → 0.01 mm steps, backing off between."""
    first = ("Jog toward the stock (−Z) about 7.5 mm, so the tip is 1.5 mm below the face beside the edge." if nearby
             else f"Bring the spinning edge finder beside {where}, its tip about 1.5 mm below the face (its side touches, not its end).")
    return ("In **Machine Control**:\n"
            f"1. {first}\n"
            "2. Jog toward the edge in 1 mm steps until it **clicks** and kicks off-centre.\n"
            "3. Back off 1 mm, then jog in 0.1 mm steps until it clicks again.\n"
            "4. Back off 0.1 mm, then jog in 0.01 mm steps until it just clicks. Stop there.")


def _edge_pair(title: str, where: str, store: str, nearby: bool = False) -> list[Step]:
    return [
        step(f"Find the {title}", markdown=edge_finding(where, nearby),
             popup=("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), no_step="-0"),
        step(f"Record the {title}", text="Click Next to store this position.", gcode=store),
    ]


def checkpoint_steps(c: Checkpoint, measuring: list) -> list[Step]:
    """Measure, then a yes/no. No goes to a step with advice, which loops back to measuring."""
    instrument = next((m.name for m in measuring if m.kind in (MeasuringKind.MICROMETER, MeasuringKind.CALIPER)),
                      "a caliper (add one to your inventory)")
    low, high = Length.mm(c.expected - c.tolerance), Length.mm(c.expected + c.tolerance)
    return [
        step(f"Measure · {c.what}", markdown=(
            f"With **{instrument}**, measure {c.what.lower()}.\n"
            "\n"
            f"**Expected** {Length.mm(c.expected)} mm (between {low} and {high} mm)."),
            popup=("In tolerance?", f"Is {c.what.lower()} between {low} and {high} mm?"), no_step="+1", yes_step="+2"),
        step("Out of Tolerance", markdown=(
            "Don't unclamp the stock.\n"
            "\n"
            "- **Too big**: the tool may be deflecting or worn. Re-run the finishing program (it removes only what's left), or add a spring pass.\n"
            "- **Too small**: check the tool's real diameter and stick-out, and the touch-off.\n"
            "\n"
            "Note the measurement for the job journal, then measure again."), go_to="-1"),
    ]


# ---------------------------------------------------------------- step helper

def step(title: str, text: str = "", markdown: str = "", image: str = "", gcode: str = "", timeout: int = 0,
         popup: tuple[str, str] | None = None, no_step: str = "", yes_step: str = "", go_to: str = "") -> Step:
    s = Step("manifest.yml")
    s.title = clean(title)
    s.prompt = clean(text)
    s.markdown = safe_markdown(markdown)
    s.image_path = image
    s.gcode_path = gcode
    s.timeout = timeout
    if popup is not None:
        s.popup_title = clean(popup[0])
        s.popup_text = clean(popup[1])
    s.popup_no_step = no_step
    s.popup_yes_step = yes_step
    s.go_to = go_to
    return s


def clean(s: str) -> str:
    """Scalars can't contain '#' (comment marker in the cutcode format)."""
    return s.replace("#", "No.")


_KEY_LIKE = re.compile(r"^\s*[A-Za-z0-9_\-]+\s*:")


def safe_markdown(md: str) -> str:
    """Markdown blocks end at any line that looks like `key: value`, and 3-character lines are
    skipped by the sender's parser. Make every line safe without changing what it says."""
    if not md:
        return ""
    out = []
    for line in md.split("\n"):
        if _KEY_LIKE.search(line):
            line = "› " + line
        if len(line) == 3:
            line += " "
        out.append(line)
    return "\n".join(out)


# ---------------------------------------------------------------- air cut, facing

_S_START = re.compile(r"^S\d")
_Z_WORD = re.compile(r"Z(-?\d+(\.\d+)?)")


def air_cut(gcode: str, lift: float = 10) -> str:
    """The air-cut copy of a program: the spindle never starts, and every work-coordinate Z is
    lifted, so the whole program can be watched safely above the stock."""
    out = [f"(AIR CUT: spindle off, all moves {GRBLPost.fmt(lift)} mm above the work)"]
    for line in gcode.split("\n"):
        upper = line.upper()
        if upper.startswith("("):
            out.append(line)
            continue
        if "M3" in upper or "M4" in upper or _S_START.search(upper):
            out.append("(spindle start removed: " + line.replace("(", "[").replace(")", "]") + ")")
            continue
        if "G53" not in upper:
            m = _Z_WORD.search(line)
            if m:
                v = float(m.group(1))
                line = line[:m.start()] + "Z" + GRBLPost.fmt(v + lift) + line[m.end():]
        out.append(line)
    return "\n".join(out)


def facing_program(width: float, length: float, depth: float, tool, data, machine: MachineProfile, title: str) -> str:
    """A standalone facing program (zig-zag along Y), for stock squaring."""
    header = GRBLPost.Header(title, "Squaring", tool, ["Facing"], f"{Length.mm(width)} × {Length.mm(length)} mm face")
    return GRBLPost.program(header, data.rpm, [OperationToolpath(new_id(), facing_moves(width, length, depth, tool, data))], machine)


def facing_moves(width: float, length: float, depth: float, tool, data, y_range=None, start_high: bool = False,
                 safe_z: float = 3) -> list[Move]:
    """The facing moves (work frame: X across the face's width, Y along its length).
    `y_range`: where the tool centre travels along Y (default: past both ends). `start_high`:
    enter from its high end."""
    r = tool.diameter / 2
    moves: list[Move] = []
    passes = max(1, int(math.ceil(depth / max(data.stepdown, 0.05))))
    y0 = y_range.lower if y_range is not None else (-length / 2 - r - 1)
    y1 = y_range.upper if y_range is not None else (length / 2 + r + 1)
    if start_high:
        y0, y1 = y1, y0
    xs: list[float] = []
    x = -width / 2 - r + data.stepover * 0.5
    while x - r < width / 2:
        xs.append(x)
        x += data.stepover
    for p in range(1, passes + 1):
        z = -depth * p / passes
        moves.append(Move(Role.RAPID, x=xs[0], y=y0, z=safe_z))
        moves.append(Move(Role.RAPID, x=xs[0], y=y0, z=1))
        moves.append(Move(Role.PLUNGE, x=xs[0], y=y0, z=z, feed=data.plunge_feed))
        forward = True
        for k, xv in enumerate(xs):
            if k > 0:
                moves.append(Move(Role.LINK, x=xv, y=y0 if forward else y1, z=z, feed=data.feed))
            moves.append(Move(Role.CUT, x=xv, y=y1 if forward else y0, z=z, feed=data.feed))
            forward = not forward
        moves.append(Move(Role.RAPID, x=xs[-1], y=y0 if forward else y1, z=safe_z))
    return moves
