"""A validated, local, self-contained machine profile package. Importing it never runs a post,
controller command or Fusion script, and never changes the active machine.
Port of Machine/MachineDefinitionPackage.swift."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path

from .. import codable
from .definition import MachineAssetRole, MachineDefinition, MachineDefinitionError

MAXIMUM_MANIFEST_BYTES = 1_048_576
MAXIMUM_ASSET_BYTES = 209_715_200
MAXIMUM_PACKAGE_BYTES = 524_288_000


@dataclass(frozen=True)
class MachineDefinitionPackage:
    definition: MachineDefinition
    root: Path

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    @property
    def geometry_path(self) -> Path:
        # A loaded package has exactly one geometry asset, enforced before construction.
        return self.root / next(a for a in self.definition.assets if a.role is MachineAssetRole.GEOMETRY).path

    @property
    def fusion_definition_path(self) -> Path | None:
        a = next((a for a in self.definition.assets if a.role is MachineAssetRole.FUSION_DEFINITION), None)
        return self.root / a.path if a is not None else None

    @staticmethod
    def load(path: Path) -> "MachineDefinitionPackage":
        path = Path(path)
        if not path.exists():
            raise MachineDefinitionError(f"Machine package was not found at '{path.name}'.")
        is_dir = path.is_dir()
        if not is_dir and path.name != "manifest.json":
            raise MachineDefinitionError("Select a machine package folder or its manifest.json. A Fusion .mch alone needs model and calibration data.")
        root = (path if is_dir else path.parent).resolve()
        manifest = _checked_file("manifest.json", root, MAXIMUM_MANIFEST_BYTES)
        with open(manifest, "rb") as f:
            data = f.read(MAXIMUM_MANIFEST_BYTES + 1)
        if len(data) > MAXIMUM_MANIFEST_BYTES:
            raise MachineDefinitionError("Machine manifest is too large.")
        # Check the envelope before decoding enums, so future profiles get a useful version message.
        try:
            envelope = json.loads(data)
        except ValueError:
            envelope = None
        version = envelope.get("schemaVersion") if isinstance(envelope, dict) else None
        if not isinstance(version, int) or isinstance(version, bool):
            raise MachineDefinitionError("Machine manifest must be an object with schemaVersion.")
        if version != 1:
            raise MachineDefinitionError(f"Unsupported machine profile schema {version}; expected 1.")
        try:
            definition = codable.decode(MachineDefinition, data)
        except Exception as e:  # noqa: BLE001
            raise MachineDefinitionError(f"Invalid machine manifest: {e}") from None
        definition.validate()
        total = len(data)
        for asset in definition.assets:
            if asset.path == "manifest.json":
                raise MachineDefinitionError("The manifest cannot also be an asset.")
            file = _checked_file(asset.path, root, MAXIMUM_ASSET_BYTES)
            total += file.lstat().st_size
            if total > MAXIMUM_PACKAGE_BYTES:
                raise MachineDefinitionError("Machine package exceeds 500 MiB.")
            if _fingerprint(file) != asset.sha256.lower():
                raise MachineDefinitionError(f"Asset '{asset.path}' does not match its SHA-256 fingerprint. Re-export the package after changing its assets.")
        return MachineDefinitionPackage(definition, root)

    @staticmethod
    def install(source_path: Path, library: Path) -> "MachineDefinitionPackage":
        """Copies declared assets only. An installed ID/revision can't be overwritten with different data."""
        source = MachineDefinitionPackage.load(source_path)
        Path(library).mkdir(parents=True, exist_ok=True)
        library = Path(library).resolve()
        d = source.definition
        destination = library / f"{d.id}-r{d.revision}"
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink():
                raise MachineDefinitionError("Installed machine location is a symbolic link; choose a regular machine library directory.")
            installed = MachineDefinitionPackage.load(destination)
            if installed.definition != d:
                raise MachineDefinitionError(f"{d.name} revision {d.revision} is already installed with different data. Give the changed profile a new revision.")
            return installed
        staging = library / f".import-{str(uuid.uuid4()).upper()}"
        staging.mkdir()
        try:
            for rel in ["manifest.json"] + [a.path for a in d.assets]:
                original = _checked_file(rel, source.root, MAXIMUM_MANIFEST_BYTES if rel == "manifest.json" else MAXIMUM_ASSET_BYTES)
                copy = staging / rel
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, copy)
            MachineDefinitionPackage.load(staging)  # catches source changes between inspection and copying
            os.replace(staging, destination)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        return MachineDefinitionPackage.load(destination)


def _checked_file(relative: str, root: Path, maximum_bytes: int) -> Path:
    parts = relative.split("/")
    if (not relative or relative.startswith("/") or "\\" in relative or ":" in relative
            or any(ord(ch) < 32 for ch in relative) or not all(p and p not in (".", "..") for p in parts)):
        raise MachineDefinitionError(f"Unsafe package path '{relative}'. Use package-relative file paths without '..'.")
    current = root
    for index, part in enumerate(parts):
        current = current / part
        try:
            st = current.lstat()
        except OSError:
            raise MachineDefinitionError(f"Package file '{relative}' is missing or unreadable.") from None
        if stat.S_ISLNK(st.st_mode):
            raise MachineDefinitionError(f"Package path '{relative}' contains a symbolic link; include the actual asset.")
        if index < len(parts) - 1:
            if not stat.S_ISDIR(st.st_mode):
                raise MachineDefinitionError(f"Package path '{relative}' contains a non-directory.")
        else:
            if not stat.S_ISREG(st.st_mode):
                raise MachineDefinitionError(f"Package asset '{relative}' must be a regular file.")
            if not 0 < st.st_size <= maximum_bytes:
                raise MachineDefinitionError(f"Package asset '{relative}' is empty or exceeds its size limit.")
    if not str(Path(os.path.normpath(current))).startswith(str(root) + os.sep):
        raise MachineDefinitionError("Package asset escapes its folder.")
    return current


def _fingerprint(path: Path) -> str:
    h = hashlib.sha256()
    count = 0
    with open(path, "rb") as f:
        while chunk := f.read(1_048_576):
            count += len(chunk)
            if count > MAXIMUM_ASSET_BYTES:
                raise MachineDefinitionError("Machine asset grew beyond its size limit while importing.")
            h.update(chunk)
    return h.hexdigest()
