"""Imports Autodesk Fusion tool libraries (`.tools`, a zip containing `tools.json`; or a bare
`.json`). Port of Inventory/ToolLibraryImport.swift."""

from __future__ import annotations

import json
import math
import re
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from ..units import Length
from .checks import ResourceLibraryValidation
from .items import Coating, Tool, ToolKind, ToolMaterial, ToolPreset


class UnreadableLibrary(Exception):
    def __init__(self, why: str) -> None:
        super().__init__(f"Couldn't read the tool library: {why}")


@dataclass
class ImportResult:
    tools: list[Tool]
    skipped: list[str]  # entries that were skipped, with the reason
    warnings: list[str] = field(default_factory=list)  # defaults inferred from incomplete geometry


_KINDS = {"flat end mill": ToolKind.FLAT_END_MILL, "ball end mill": ToolKind.BALL_END_MILL,
          "bull nose end mill": ToolKind.BULL_NOSE_END_MILL, "radius mill": ToolKind.BULL_NOSE_END_MILL,
          "chamfer mill": ToolKind.CHAMFER_MILL, "dovetail mill": ToolKind.CHAMFER_MILL,
          "engrave": ToolKind.ENGRAVER, "engrave mill": ToolKind.ENGRAVER, "tapered mill": ToolKind.ENGRAVER,
          "drill": ToolKind.DRILL, "spot drill": ToolKind.SPOT_DRILL, "center drill": ToolKind.SPOT_DRILL,
          "thread mill": ToolKind.THREAD_MILL, "face mill": ToolKind.FACE_MILL}


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


class ToolLibraryImport:
    @staticmethod
    def load(path: Path) -> ImportResult:
        if path.suffix.lower() == ".json":
            data = path.read_bytes()
        else:
            try:
                archive = zipfile.ZipFile(path)
            except (zipfile.BadZipFile, OSError) as e:
                raise UnreadableLibrary(f"not a zip archive ({e})") from None
            entry = next((n for n in archive.namelist() if n.lower().endswith("tools.json")), None)
            if entry is None:
                raise UnreadableLibrary("no tools.json inside")
            data = archive.read(entry)
        return ToolLibraryImport.parse(data, path.name)

    @staticmethod
    def parse(data: bytes, source_name: str) -> ImportResult:
        from .resource_library import canonical_string, stable_id
        try:
            root = json.loads(data)
        except ValueError:
            root = None
        if not isinstance(root, dict) or not isinstance(root.get("data"), list):
            raise UnreadableLibrary("unexpected JSON layout")
        tools: list[Tool] = []
        skipped: list[str] = []
        warnings: list[str] = []
        converted_inches = False
        for e in root["data"]:
            if not isinstance(e, dict):
                continue
            type_name = e.get("type") if isinstance(e.get("type"), str) else "?"
            description = (e.get("description") if isinstance(e.get("description"), str) else "").strip(" ")
            kind = _KINDS.get(type_name.lower())
            if kind is None:
                skipped.append(f"{type_name} {description}: not a cutting tool Coastline uses")
                continue
            g = e.get("geometry") if isinstance(e.get("geometry"), dict) else {}
            unit = (e.get("unit") if isinstance(e.get("unit"), str) else "").lower()
            if unit in ("inches", "inch", "in"):
                scale = 25.4
            elif unit in ("millimeters", "millimetres", "millimeter", "millimetre", "mm"):
                scale = 1.0
            else:
                skipped.append(f"{type_name} {description}: missing or unsupported units {unit}")
                continue

            def length(key: str) -> float | None:
                v = _num(g.get(key))
                return None if v is None else v * scale

            diameter = length("DC")
            if diameter is None or not math.isfinite(diameter) or diameter <= 0:
                skipped.append(f"{type_name} {description}: no diameter")
                continue
            vendor = (e.get("vendor") if isinstance(e.get("vendor"), str) else "").strip(" ")
            product = (e.get("product-id") if isinstance(e.get("product-id"), str) else "").strip(" ")
            post = e.get("post-process") if isinstance(e.get("post-process"), dict) else {}
            number = post.get("number") if isinstance(post.get("number"), int) and not isinstance(post.get("number"), bool) else None
            flute_length = length("LCF")
            if flute_length is None:
                flute_length = diameter * 2
            stickout = length("LB")
            if stickout is None:
                stickout = length("assemblyGaugeLength")
            if stickout is None:
                stickout = flute_length + 5
            raw_flutes = _num(g.get("NOF"))
            if raw_flutes is not None and not (math.isfinite(raw_flutes) and 0 < raw_flutes <= 2147483647 and float(round(raw_flutes)) == raw_flutes):
                skipped.append(f"{type_name} {description}: invalid flute count")
                continue
            bmc = e.get("BMC") if isinstance(e.get("BMC"), str) else None
            overall = length("OAL")
            angle = _num(g.get("TA"))
            if angle is None:
                angle = _num(g.get("SIG"))
            tool = Tool.make(
                ToolLibraryImport.display_name(vendor, product, description, kind, diameter), kind, diameter,
                length("SFDM") if length("SFDM") is not None else diameter,
                int(raw_flutes) if raw_flutes is not None else 2, flute_length, stickout,
                overall if overall is not None else stickout + 20,
                vendor=vendor, part_number=product,
                product_link=e.get("product-link") if isinstance(e.get("product-link"), str) else "",
                corner_radius=length("RE") or 0.0, angle=angle, tip_diameter=length("tip-diameter") or 0.0,
                tool_material=ToolLibraryImport.tool_material(bmc),
                coating=Coating.TIN if (bmc or "").lower() == "ti coated" else ToolLibraryImport.coating(description),
                intended_for=description,
                source=f"Fusion library {source_name}" + (f", T{number}" if number is not None else ""))
            tool.presets = ToolLibraryImport.presets(e, scale)
            guid = e.get("guid") if isinstance(e.get("guid"), str) else None
            if guid is not None and guid.strip():
                normalized = guid.strip("{} ").lower()
                try:
                    tool.id = str(uuid.UUID(normalized)).upper() if _uuid_like(normalized) else stable_id("fusion-guid:" + normalized)
                except ValueError:
                    tool.id = stable_id("fusion-guid:" + normalized)
            else:
                identity = tool.copy()
                identity.id = "00000000-0000-0000-0000-000000000000"
                identity.source, identity.presets, identity.product_link = "", [], ""
                identity.intended_for = description if not product else ""
                tool.id = stable_id("fusion-tool:" + canonical_string(identity))
            problems = ResourceLibraryValidation.tool_issues(tool)
            if problems:
                skipped.append(f"{tool.name}: " + " ".join(problems))
                continue
            inferred = []
            if length("SFDM") is None:
                inferred.append("shank diameter")
            if length("LCF") is None:
                inferred.append("flute length")
            if length("LB") is None and length("assemblyGaugeLength") is None:
                inferred.append("stickout")
            if length("OAL") is None:
                inferred.append("overall length")
            if raw_flutes is None:
                inferred.append("flute count")
            if inferred:
                warnings.append(f"{tool.name}: inferred {', '.join(inferred)}; check these dimensions before cutting.")
            if any(t.id == tool.id for t in tools):
                skipped.append(f"{tool.name}: repeated tool identity in this Fusion library")
                continue
            tools.append(tool)
            if scale == 25.4:
                converted_inches = True
        if converted_inches:
            warnings.append("Converted Fusion inch tool dimensions and feeds to millimetres and mm/min.")
        return ImportResult(tools, skipped, warnings)

    @staticmethod
    def kind(fusion_type: str) -> ToolKind | None:
        return _KINDS.get(fusion_type.lower())

    @staticmethod
    def tool_material(bmc: str | None) -> ToolMaterial:
        b = (bmc or "").lower()
        return ToolMaterial.HSS if b == "hss" else ToolMaterial.COBALT if b == "cobalt" else ToolMaterial.CARBIDE

    @staticmethod
    def coating(description: str) -> Coating:
        """Vendors often name the coating in the description (whole words: "cutting" contains "tin")."""
        words = set(w for w in re.split(r"[^a-z]+", description.lower()) if w)
        for word, c in (("altin", Coating.ALTIN), ("tialn", Coating.TIALN), ("alcrn", Coating.ALCRN), ("zrn", Coating.ZRN),
                        ("dlc", Coating.DLC), ("tin", Coating.TIN)):
            if word in words:
                return c
        return Coating.NONE

    @staticmethod
    def display_name(vendor: str, product: str, description: str, kind: ToolKind, diameter: float) -> str:
        fraction = Length.inch_fraction(diameter) if diameter < 9.223372036854776e18 / 64 else None
        size = fraction or f"{Length.mm(diameter)} mm"
        what = f"{size} {kind.title.lower()}"
        maker = " ".join(p for p in (vendor, product) if p)
        return f"{what} · {maker}" if maker else what

    @staticmethod
    def presets(e: dict, scale: float) -> list[ToolPreset]:
        start = e.get("start-values") if isinstance(e.get("start-values"), dict) else {}
        items = start.get("presets") if isinstance(start.get("presets"), list) else []
        out = []
        for p in items:
            if not isinstance(p, dict):
                continue
            n = _num(p.get("n"))
            if n is None:
                continue

            def feed(key: str) -> float:
                return (_num(p.get(key)) or 0.0) * scale

            stepdown = _num(p.get("stepdown")) if p.get("use-stepdown") is True else None
            stepover = _num(p.get("stepover")) if p.get("use-stepover") is True else None
            out.append(ToolPreset(p.get("name") if isinstance(p.get("name"), str) else "Preset", n, feed("v_f"),
                                  feed("v_f_plunge"), feed("v_f_ramp"),
                                  None if stepdown is None else stepdown * scale, None if stepover is None else stepover * scale))
        return out


def _uuid_like(s: str) -> bool:
    return re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", s) is not None
