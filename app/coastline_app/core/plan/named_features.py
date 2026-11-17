"""What a group of the part's faces is, with its sizes ("Slot 16.89 x 31 mm"), from the engine's
"recognise" call. Names for DFM findings only. Port of Plan/NamedFeatures.swift."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass
class NamedFeature:
    family: str
    label: str
    faces: list[int]

    @staticmethod
    def name(faces, features: list["NamedFeature"]) -> str | None:
        """A feature with at least half its faces among these that is also at least a third of
        them (a small pocket doesn't name a whole side); the largest share first, then the one
        sharing the most. None when none does."""
        s = set(faces)
        if not s:
            return None
        best = None
        for f in features:
            if not f.faces:
                continue
            n = sum(1 for k in f.faces if k in s)
            share = n / len(f.faces)
            if not (n > 0 and share >= 0.5 and 3 * n >= len(s)):
                continue
            if best is None or (share, n) > (best[0], best[1]):
                best = (share, n, f.label)
        return best[2] if best else None


def recognise(engine, path: Path) -> list[NamedFeature] | None:
    """Named features of a STEP file (the engine doesn't need it imported). None when recognition
    isn't available. Slow on busy parts: call it on an engine of its own."""
    result, _ = engine.call("recognise", {"path": str(path)})
    if result.get("available") is not True:
        return None
    out = []
    for f in result.get("features") or []:
        family, label = f.get("family"), f.get("label")
        if not isinstance(family, str) or not isinstance(label, str):
            continue
        faces = [int(v) for v in f.get("faces") or [] if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if faces:
            out.append(NamedFeature(family, label, faces))
    return out
