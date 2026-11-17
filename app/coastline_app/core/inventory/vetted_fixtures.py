"""Only exact reviewed source files receive mechanical definitions. Port of
Inventory/VettedFixtureLibrary.swift: display names do not identify an assembly, and an edited
CAD file cannot inherit reviewed joints."""

from __future__ import annotations

import copy
import hashlib
from dataclasses import dataclass
from pathlib import Path

from .. import codable
from ..plan.fixture_assembly import AssemblyError, FixtureAssemblyDefinition, FixtureAssemblyState


@dataclass(frozen=True)
class _Entry:
    source: str
    model: str
    definition: str


ENTRIES = [
    _Entry("cc141eb5ee58f00fb420ab2272d84bb448de1758a691a8f1dcd6947a87dca9e3", "fixtures/bookends/assembly.step", "fixtures/bookends/definition.json"),
    _Entry("06df20ac25bc5ab5268f1cc4cf124da6e7e32c7f25f91cd8525b316a0bdc83c1", "fixtures/quick-release/fixture.step", "fixtures/quick-release/definition.json"),
    _Entry("95144b1255821d8162ce28efeecd827796a4694456376d21365980d67f7ceea6", "fixtures/quick-release/assembly.step", "fixtures/quick-release/assembly-definition.json"),
    _Entry("bc10325376db711475497a27841e29a87b710c57317697a112febb32528e4ace", "fixtures/c-clamps/assembly.step", "fixtures/c-clamps/definition.json"),
    _Entry("202b461426c21c267684533de27d34a8c0b1014423cdd4d1d9a286019350a87c", "fixtures/vise/assembly.step", "fixtures/vise/definition.json"),
]
ASSEMBLED_QUICK_RELEASE = "fixtures/quick-release/assembly.step"
CLAMP_PAIR = "fixtures/c-clamps/assembly.step"

_sha_cache: dict[tuple[str, float, int], str] = {}


def sha(path: Path) -> str:
    st = path.stat()
    key = (str(path), st.st_mtime, st.st_size)
    digest = _sha_cache.get(key)
    if digest is None:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        digest = _sha_cache[key] = h.hexdigest()
    return digest


def _resolve(path: str, resources: Path) -> Path:
    p = Path(path)
    return p if p.is_absolute() else resources / path


def _definition(entry: _Entry, resources: Path) -> FixtureAssemblyDefinition:
    return codable.decode(FixtureAssemblyDefinition, (resources / entry.definition).read_bytes())


class VettedFixtureLibrary:
    @staticmethod
    def prepared(fixture, resources: Path):
        if fixture.model_path is None:
            return fixture
        digest = sha(_resolve(fixture.model_path, resources))
        entry = next((e for e in ENTRIES if e.source == digest), None)
        definition = fixture.assembly
        if definition is not None and definition.model_sha256.lower() != digest:
            # A newer reviewed revision of the same bundled fixture replaces the old one.
            newer = None
            if entry is not None:
                try:
                    newer = _definition(entry, resources)
                except Exception:  # noqa: BLE001
                    newer = None
            if newer is None or newer.id != definition.id or newer.revision <= definition.revision:
                raise AssemblyError([f"The CAD for {fixture.name} changed. Rebind its mechanical definition before using it."])
        elif definition is not None:
            if (definition.bookends is None or definition.bookends.contact_metadata_complete) or entry is None:
                definition.validate(fixture.planning.assembly_state if fixture.planning and fixture.planning.assembly_state else FixtureAssemblyState())
                return fixture
        if entry is None:
            return fixture
        definition_new = _definition(entry, resources)
        definition_new.validate()
        if fixture.assembly is not None and fixture.assembly.id != definition_new.id:
            raise AssemblyError(["The incomplete fixture definition does not match the reviewed assembly."])
        if sha(resources / entry.model) != definition_new.model_sha256.lower():
            raise AssemblyError(["The bundled fixture model does not match its mechanical definition."])
        out = copy.deepcopy(fixture)
        out.model_path = entry.model
        out.assembly = definition_new
        if out.planning is not None:
            p = out.planning
            p.assembly_state = FixtureAssemblyState()
            p.component_placements = None
            p.component_layout_id = None
            p.component_model_signature = None
            p.workspace_placed = False
            p.grip_definition_reviewed = False
        return out

    @staticmethod
    def migrate(inventory, resources: Path) -> bool:
        from .items import FixtureKind
        changed = False
        for index, original in enumerate(inventory.fixtures):
            fixture = copy.deepcopy(original)
            if fixture.name == "CR-1 Universal Clamp" and fixture.kind is FixtureKind.UNIVERSAL_CLAMP:
                fixture.name = "Universal Clamp"
            if fixture.assembly is not None and fixture.assembly.id == "quick-release-jig-plate" and fixture.assembly.revision < 2:
                fixture.model_path, fixture.assembly, fixture.planning = ASSEMBLED_QUICK_RELEASE, None, None
            if fixture.kind is FixtureKind.T_SLOT_NUTS and fixture.model_path is None and "M4" in fixture.name:
                fixture.model_path = "fixtures/hardware/t-slot-nut-m4.step"
            if fixture.kind is FixtureKind.C_CLAMP and fixture.model_path is None and fixture.quantity >= 2:
                fixture.model_path, fixture.assembly, fixture.planning = CLAMP_PAIR, None, None
            try:
                fixture = VettedFixtureLibrary.prepared(fixture, resources)
            except Exception:  # noqa: BLE001
                pass
            if fixture != original:
                inventory.fixtures[index] = fixture
                changed = True
        return changed
