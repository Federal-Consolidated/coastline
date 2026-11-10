"""Named features from quiddity (Apache-2.0, https://github.com/pzfreo/quiddity): what each
group of faces is, with its sizes, to name DFM findings ("Slot 16.9 x 31 mm").

quiddity reads the STEP file itself, so this needs the file's path, not an imported part. Its
face numbers are the STEP file's face order, the same TopExp order the engine's import and
analysis use (checked on the DFM coupon and a 177-face part). Recognition can take tens of
seconds on a busy part: the app runs it in its own engine process, once per file.
"""

from __future__ import annotations

import json
import time

# Families that name a machined feature. The rest (plates, step levels, section recesses,
# blends, patterns, ...) describe the stock or group other features: no names from them.
_SKIP = {"plates", "step_levels", "risers", "section_recesses", "section_passages", "freeform_surfaces",
         "blends", "fillets", "flats", "polygonal_stock", "thin_wall_bodies", "sheet_metal_bodies",
         "hole_patterns", "slot_patterns", "pocket_patterns", "circular_face_patterns",
         "gusset_rib_patterns", "repeating_radial_profiles", "prismatic_pockets"}


def _mm(v) -> str:
    """To 0.01 mm, without trailing zeros: 6.35, 16.89, 31."""
    return f"{round(float(v) + 1e-9, 2):.2f}".rstrip("0").rstrip(".")


def label(family: str, p: dict) -> str | None:
    """A short name with the sizes that tell features apart, or None to leave it unnamed."""
    if family in _SKIP:
        return None
    num = lambda k: p.get(k) if isinstance(p.get(k), (int, float)) else None  # noqa: E731
    if family == "holes" and num("diameter"):
        kind = {"through": "Through hole", "drill_point": "Drilled hole"}.get(p.get("bottom"), "Hole")
        return f"{kind} ⌀{_mm(p['diameter'])} mm"
    if family in ("slots", "rectangular_blind_slots", "round_bottom_blind_slots") and num("width") and num("length"):
        return f"Slot {_mm(p['width'])} x {_mm(p['length'])} mm"
    if family == "pockets" and num("width") and num("length"):
        return f"Pocket {_mm(p['width'])} x {_mm(p['length'])} mm"
    if family == "chamfers" and num("leg1"):
        return f"Chamfer {_mm(p['leg1'])} mm"
    if family == "modelled_thread_refusals":
        return "Modelled thread"
    words = family.replace("_", " ")
    return (words[:-1] if words.endswith("s") else words).capitalize()


def recognise(path: str) -> dict:
    """{"available", "version", "seconds", "features": [{family, label, faces}]} for a STEP file;
    available False when quiddity isn't installed or can't read the file (with "error")."""
    try:
        import quiddity
    except ImportError:
        return {"available": False, "features": [], "error": "quiddity is not installed"}
    start = time.monotonic()
    try:
        doc = json.loads(quiddity.recognise(str(path)))["document"]
    except Exception as e:  # a file it refuses: no names, the check carries on without them
        return {"available": False, "features": [], "error": str(e)}
    out = []
    for r in doc.get("records", []):
        name = label(r.get("family", ""), r.get("parameters") or {})
        faces = [int(f) for f in r.get("faces", [])]
        if name and faces:
            out.append({"family": r["family"], "label": name, "faces": faces})
    return {"available": True, "version": quiddity.__version__, "seconds": round(time.monotonic() - start, 3),
            "features": out}
