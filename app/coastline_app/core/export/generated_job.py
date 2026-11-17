"""The individual programs and the built-in guided run share the same generated source.
Port of Export/GeneratedJob.swift."""

from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from ..program import gcode_reader as GCodeReader
from ..program.program_job import JobSetup, ProgramFile, ProgramJob, Purpose
from ..program.program_job import Step as JobStep
from ..program.program_job import StepKind
from . import guided_job as GuidedJobBuilder


class GeneratedJobError(Exception):
    pass


class CodeKind(Enum):
    CUT = "Cutting"
    PROBE = "Probing"
    SETUP = "Setup"
    AIR_CUT = "Air cuts"


@dataclass(frozen=True)
class CodeFile:
    path: str
    title: str
    kind: CodeKind
    text: str

    @property
    def id(self) -> str:
        return self.path


def code_files(inp, machine=None) -> list[CodeFile]:
    jobs, files = GuidedJobBuilder.build(inp, machine)
    seen: set[str] = set()
    out = []
    for job in jobs:
        for step in job.steps:
            if not step.has_gcode or step.gcode_path in seen:
                continue
            seen.add(step.gcode_path)
            data = files.get(step.gcode_path)
            if data is None:
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            read = GCodeReader.read(text)
            path = step.gcode_path.lower()
            if "aircut" in path:
                kind = CodeKind.AIR_CUT
            elif "_cut" in path or "/square_" in path or "/prep_" in path:
                kind = CodeKind.CUT
            elif read.probes > 0 or read.offset_writes > 0 or read.macros:
                kind = CodeKind.PROBE
            else:
                kind = CodeKind.SETUP
            out.append(CodeFile(step.gcode_path, step.title, kind, text))
    return out


def _write(folder: Path, file: CodeFile) -> Path:
    url = folder / file.path
    url.parent.mkdir(parents=True, exist_ok=True)
    url.write_bytes(file.text.encode("utf-8"))  # bytes: keep "\n" line ends on Windows too
    return url


def export(files: list[CodeFile], selected: set[str], folder: Path) -> list[Path]:
    """Write only the selected files into a new folder, keeping their relative paths. An existing
    destination is refused, so export can't replace an unrelated program."""
    chosen = [f for f in files if f.id in selected]
    if not chosen:
        raise GeneratedJobError("Select at least one program to export.")
    if folder.exists():
        raise GeneratedJobError("That export folder already exists. Choose a new folder name.")
    folder.mkdir(parents=True)
    try:
        return [_write(folder, f) for f in chosen]
    except Exception:
        shutil.rmtree(folder, ignore_errors=True)
        raise


def write_native(inp, folder: Path, machine=None) -> ProgramJob:
    """All prep and part setups run in order. The built-in runner supplies its own optional air
    cut action; the package's popup and retry branches become explicit confirmations."""
    from ..machine.profile import MachineProfile
    machine = machine or MachineProfile.standard()
    GuidedJobBuilder.validate_workholding(inp)
    if not inp.programs:
        raise GeneratedJobError("Generate toolpaths first.")
    contour = set(range(111, 115))
    if not all(p.surface_probe is None and not (GCodeReader.read(p.gcode).macros & contour) for p in inp.programs):
        raise GeneratedJobError("Surface-follow engraving uses contour-map codes that the built-in runner does not support yet. "
                                "Export a guided job for a compatible sender.")
    jobs, _ = GuidedJobBuilder.build(inp, machine)
    files = code_files(inp, machine)
    for f in files:
        if f.kind is CodeKind.AIR_CUT:
            continue
        unsupported = sorted(GCodeReader.read(f.text).macros - {100, 101, 102, 106})
        if unsupported:
            codes = ", ".join(f"M{c}" for c in unsupported)
            raise GeneratedJobError(f"{f.title} uses host codes that the built-in runner does not support yet ({codes}). "
                                    "Export a guided job for a compatible sender.")
    by_path = {f.path: f for f in files}
    job = ProgramJob(id=str(uuid.uuid4()).upper(), title=inp.part_name,
                     summary="Generated in Coastline. Stock prep and machining run in order.")
    job.machines = [machine.name]
    job.material = inp.material.name
    job.requirements = ["I have reviewed the generated programs and the workholding.",
                        "The tool and stock are secured, the chip cover is on, and I can reach the E-stop."]
    job.programs = [ProgramFile(f.path, f.title, f.path,
                                Purpose.CUT if f.kind is CodeKind.CUT else Purpose.PROBE if f.kind is CodeKind.PROBE else Purpose.MOVE,
                                tool=None, source=f.path)
                    for f in files if f.kind is not CodeKind.AIR_CUT]
    for k, source in enumerate(jobs):
        steps: list[JobStep] = []
        for num, step in enumerate(source.steps):
            # The optional air cut is on each cutting step in the built-in runner; the
            # out-of-tolerance retry branch is part of the measurement confirmation.
            if step.title in ("Air Cut First?", "Out of Tolerance"):
                continue
            f = by_path.get(step.gcode_path)
            if f is not None and f.kind is CodeKind.AIR_CUT:
                continue
            sid = f"s{k}-{num}"
            text = step.prompt if not step.markdown else step.markdown
            if text or step.has_popup:
                steps.append(JobStep(sid, StepKind.INSTRUCTION, step.title, text=text,
                                     caution=step.popup_text if step.has_popup else None))
            if step.has_gcode:
                if step.gcode_path not in by_path:
                    raise GeneratedJobError(f"Missing generated code: {step.gcode_path}")
                steps.append(JobStep(sid + "-run", StepKind.RUN, step.title, program=step.gcode_path))
        job.setups.append(JobSetup(f"setup{k}", source.title, steps, summary=source.prompt))
    if folder.exists():
        raise GeneratedJobError("The generated job folder already exists.")
    folder.mkdir(parents=True)
    try:
        for f in files:
            if f.kind is not CodeKind.AIR_CUT:
                _write(folder, f)
        job.save(folder)
        return job
    except Exception:
        shutil.rmtree(folder, ignore_errors=True)
        raise
