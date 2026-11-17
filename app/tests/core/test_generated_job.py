"""Port of CoastlineSelfTest/GeneratedJobTests.swift."""

import pytest

from coastline_app.core.export import generated_job as GJ
from coastline_app.core.export import guided_job as G
from coastline_app.core.inventory.items import MeasuringKind, MeasuringTool, StockItem, Tool, ToolKind
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan import reference_bores as ReferenceBores
from coastline_app.core.plan.operation import ReferenceFeature
from coastline_app.core.program.program_job import ProgramJob, Purpose, StepKind
from coastline_app.mill.geometry import Range as MillRange
from coastline_app.mill.mock import STANDARD_SETTINGS
from coastline_app.mill.programs import check_job_program
from coastline_app.mill.session_types import MillEnvelope
from coastline_app.mill.status import MillSettings


def generated_input():
    tool = Tool.make("Uncoated flat", ToolKind.FLAT_END_MILL, 6, 6, 2, 12, 28, 50)
    return G.Input("Small cut", MaterialLibrary.material("al-6061"), StockItem.make("al-6061", 60, 30, 10), (30, 60, 10), "Setup 1",
                   [G.Program(tool, "(One short cut)\nG21 G90\nM3 S5000\nG0 X0 Y0 Z2\nG1 Z-0.1 F20\nG1 Y0.05 F50\nG0 Z2\nM5\n",
                              ["Tiny contour"], 0.1)],
                   [G.Checkpoint(0, "Stock thickness", 10, 0.05)], [MeasuringTool.make("Digital caliper", MeasuringKind.CALIPER)], None)


def check_native_programs(job, folder):
    """Exactly the checker the live sender uses, without connecting to a controller."""
    machine = MachineProfile.standard()
    settings = MillSettings()
    for key, value, _ in STANDARD_SETTINGS:
        settings.update(key, value)
    settings.update(30, machine.spindle_rpm.upper)
    e = machine.machine_envelope
    envelope = MillEnvelope(MillRange(e.x.lower, e.x.upper), MillRange(e.y.lower, e.y.upper), MillRange(e.z.lower, e.z.upper))
    for p in job.programs:
        check_job_program((folder / p.file).read_text(encoding="utf-8").split("\n"), settings, envelope)


def test_code_catalog_keeps_short_cuts_and_original_bytes():
    inp = generated_input()
    jobs, built = G.build(inp)
    files = GJ.code_files(inp)
    assert len({f.path for f in files}) == len(files)
    kinds = {f.path: f.kind for f in files}
    assert kinds["Code/T1_cut.nc"] is GJ.CodeKind.CUT
    assert kinds["Code/T1_aircut.nc"] is GJ.CodeKind.AIR_CUT
    assert kinds["Code/home.nc"] is GJ.CodeKind.SETUP
    for f in files:
        assert f.text.encode() == built[f.path], f.path
        assert any(s.gcode_path == f.path for j in jobs for s in j.steps)


def test_cut_only_export_contains_exactly_selected_original_programs(tmp_path):
    inp = generated_input()
    files = GJ.code_files(inp)
    selected = {f.id for f in files if f.kind is GJ.CodeKind.CUT}
    assert selected
    destination = tmp_path / "Cuts"
    written = GJ.export(files, selected, destination)
    relative = {p.relative_to(destination).as_posix() for p in written}
    assert relative == selected
    _, original = G.build(inp)
    for path in relative:
        assert (destination / path).read_bytes() == original[path]
    for f in files:
        if f.id not in selected:
            assert not (destination / f.path).exists()
    assert not (destination / "job.json").exists()


def test_selective_export_never_overwrites_and_needs_a_selection(tmp_path):
    files = GJ.code_files(generated_input())
    existing = tmp_path / "Existing"
    existing.mkdir()
    sentinel = existing / "keep.nc"
    sentinel.write_text("Keep these bytes\n")
    with pytest.raises(GJ.GeneratedJobError):
        GJ.export(files, {f.id for f in files}, existing)
    assert sentinel.read_text() == "Keep these bytes\n"
    empty = tmp_path / "Empty"
    with pytest.raises(GJ.GeneratedJobError):
        GJ.export(files, set(), empty)
    assert not empty.exists()
    with pytest.raises(GJ.GeneratedJobError):
        GJ.export(files, {"unknown.nc"}, empty)
    assert not empty.exists()


def test_native_job_keeps_program_order_and_operator_confirmations(tmp_path):
    inp = generated_input()
    source_jobs, source_files = G.build(inp)
    destination = tmp_path / "Native"
    job = GJ.write_native(inp, destination)
    assert [s.title for s in job.setups] == ["Setup 1 · Small cut"]
    assert job.options == []
    assert all(not s.when and all(not st.when for st in s.steps) for s in job.setups)
    assert ProgramJob.load(destination) == job
    assert job.problems(destination) == []
    check_native_programs(job, destination)
    catalog = {f.path: f.kind for f in GJ.code_files(inp)}
    for k, original in enumerate(source_jobs):
        expected = [s.gcode_path for s in original.steps if s.has_gcode and catalog.get(s.gcode_path) is not GJ.CodeKind.AIR_CUT]
        assert [s.program for s in job.setups[k].steps if s.kind is StepKind.RUN] == expected
        for n, step in enumerate(original.steps):
            if step.has_popup and step.title != "Air Cut First?":
                c = next(s for s in job.setups[k].steps if s.id == f"s{k}-{n}")
                assert c.kind is StepKind.INSTRUCTION and c.caution == step.popup_text
                assert c.text == (step.prompt if not step.markdown else step.markdown)
    assert all(s.title not in ("Air Cut First?", "Out of Tolerance") for st in job.setups for s in st.steps)
    assert next(p for p in job.programs if p.file == "Code/T1_cut.nc").purpose is Purpose.CUT
    assert all("aircut" not in p.file.lower() for p in job.programs)
    for p in job.programs:
        assert (destination / p.file).read_bytes() == source_files[p.file]
    with pytest.raises(GJ.GeneratedJobError):
        GJ.write_native(inp, destination)
    assert ProgramJob.load(destination) == job


def test_native_job_rejects_unsupported_surface_map_and_empty_programs(tmp_path):
    inp = generated_input()
    inp.programs[0].surface_probe = "M114\nM111 Z-2 F20\n"
    destination = tmp_path / "Native"
    with pytest.raises(GJ.GeneratedJobError, match="contour-map"):
        GJ.write_native(inp, destination)
    assert not destination.exists()
    inp.programs[0].surface_probe = None
    inp.programs[0].gcode += "M112\n"
    with pytest.raises(GJ.GeneratedJobError):
        GJ.write_native(inp, destination)
    assert not destination.exists()
    inp.programs = []
    with pytest.raises(GJ.GeneratedJobError):
        GJ.write_native(inp, destination)
    assert not destination.exists()


def test_native_job_runs_reference_bore_macros(tmp_path):
    # M102/M106 (the reference-bore checks) run in Coastline's own runner, like M100/M101.
    import copy
    inp = generated_input()
    inp.programs[0].reference = ReferenceFeature.BORES
    back = copy.copy(inp.programs[0])
    back.side, back.reference = 1, ReferenceFeature.WINDOWS
    inp.programs.append(back)
    inp.probing.bores = ReferenceBores.Plan([(7, -15), (7, 15)], 7, 10)
    destination = tmp_path / "Native"
    job = GJ.write_native(inp, destination)
    texts = [(destination / p.file).read_text() for p in job.programs]
    assert any("M102" in t for t in texts) and any("M106" in t for t in texts), "the bore programs keep their checks"
