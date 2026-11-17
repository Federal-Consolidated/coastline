"""Port of MillCoreSelfTest/ProgramLibraryTests.swift."""

import json
from dataclasses import replace

import pytest

from coastline_app.mill.geometry import Point3
from coastline_app.mill.programs import (SavedProgramKind, SavedTestProgram, TestProgramLibrary, check_job_program,
                                         check_test_program)
from coastline_app.mill.session_types import MillEnvelope, MillRefusal

from .helpers import real_settings


def roundtrip(library: TestProgramLibrary) -> TestProgramLibrary:
    return TestProgramLibrary.from_json(json.loads(json.dumps(library.to_json())))


def test_edits_favorites_and_deletion_survive_persistence():
    library = TestProgramLibrary()
    built_in = library.programs[0]
    custom = SavedTestProgram("Check Y", "Move down and back", "G91\nG1 Y-1 F100\nG1 Y1 F100")
    library.save(custom)
    library.toggle_favorite(custom.id)
    assert library.ordered[0].id == custom.id
    custom = replace(custom, title="Y setup check", is_favorite=True)
    library.save(custom)
    assert len(library.programs) == 2
    library.remove(built_in.id)
    restored = roundtrip(library)
    assert restored.programs == [custom]
    assert restored.ordered[0].title == "Y setup check"


def test_empty_library_remains_empty():
    library = TestProgramLibrary()
    for p in list(library.programs):
        library.remove(p.id)
    assert roundtrip(library).programs == []


def test_custom_programs_keep_motion_checks():
    envelope = MillEnvelope.from_settings(real_settings())
    start = Point3(-40, -10, -10)
    good = SavedTestProgram("Relative Y", code="G91\nG1 Y-1 F100\nG1 Y1 F100")
    assert check_test_program(good.lines, start, envelope)[:3] == ["G21", "G90", "M5"]
    for code in ["M3 S1000", "G20", "G91\nG1 Y-999 F100", "G1 X-30 F100", "G38.2 Z-2 F100",
                 "G999999999999999999999999", "G91\nG1 X999999999999999999999999 F100"]:
        with pytest.raises(MillRefusal):
            check_test_program(SavedTestProgram("Unsafe", code=code).lines, start, envelope)


def test_empty_name_and_comments_only_code_are_invalid():
    assert SavedTestProgram(" \n").validation_message is not None
    assert SavedTestProgram("Empty", code="(only a comment)\n; nothing to send\n").validation_message is not None
    assert SavedTestProgram("Dwell", code="G4 P1").validation_message is None


def test_old_saved_programs_default_to_motion_checks():
    program = SavedTestProgram("Old check", code="G4 P1")
    d = program.to_json()
    del d["kind"]
    restored = SavedTestProgram.from_json(d)
    assert restored.kind is SavedProgramKind.MOTION_CHECK and restored.id == program.id


def test_setup_programs_use_guided_code_checks():
    settings = real_settings()
    envelope = MillEnvelope.from_settings(settings)
    setup = SavedTestProgram("Probe Z", code="G91\nG38.2 Z-2 F100\nG90\nG10 L20 P1 Z0", kind=SavedProgramKind.SETUP)
    checked = check_job_program(setup.lines, settings, envelope)
    assert "G38.2Z-2F100" in checked.lines and "G10L20P1Z0" in checked.lines
    for code in ["G20", "$RST=*", "G53 G0 Z-9999", "M3 S999999", "G10 L3 P1 X0",
                 "M3 S999999999999999999999999", "G10 L2 P999999999999999999999999 X0", "G10 L20 P1.5 X0"]:
        with pytest.raises(MillRefusal):
            check_job_program(SavedTestProgram("Bad setup", code=code, kind=SavedProgramKind.SETUP).lines, settings, envelope)


def test_setup_homing_remains_first_before_injected_startup():
    settings = real_settings()
    envelope = MillEnvelope.from_settings(settings)
    setup = SavedTestProgram("Home", code="; Home first\n $H (home)\nG53 G0 X-40", kind=SavedProgramKind.SETUP)
    assert setup.homes_first
    checked = check_job_program(setup.lines, settings, envelope)
    assert checked.starts_with_home and checked.lines[:4] == ["$H", "G21", "G90", "M5"]
    checks_only = replace(setup, kind=SavedProgramKind.MOTION_CHECK)
    assert not checks_only.homes_first
    with pytest.raises(MillRefusal):
        check_test_program(checks_only.lines, Point3(-40, -10, -10), envelope)
