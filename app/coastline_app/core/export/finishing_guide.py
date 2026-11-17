"""What to do once the part is free: deburring, sanding and polishing, by material.
Port of Export/FinishingGuide.swift."""

from __future__ import annotations


def steps(material) -> list[str]:
    from ..materials import MaterialFamily as F
    family = material.family if material is not None else None
    if family is F.ALUMINIUM:
        return ["File the tab stubs flush, deburr the edges with a deburring blade.",
                "Sand wet 400 → 800 → 1500, then polish with metal polish on a felt wheel. Bead blast instead for a satin look; anodise if you want colour."]
    if family is F.COPPER_ALLOY:
        return ["File the tab stubs, then sand 400 → 1200.",
                "Tripoli then rouge on a buffing wheel, or tumble in steel shot for a bright finish. Lacquer or wax it against tarnish."]
    if family in (F.STEEL, F.STAINLESS):
        return ["Deburr, sand 240 → 600, polish with compound.", "Oil plain steel against rust."]
    if family is F.TITANIUM:
        return ["Deburr gently (titanium burrs are sharp), sand 400 → 1000.", "Anodise for colour if you like."]
    if family is F.PLASTIC:
        return ["Scrape the edges with a sharp blade instead of sanding the burr.", "Sand wet 600 → 1500; only acrylic can be flame-polished."]
    if family is F.WAX:
        return ["Smooth with a warmed tool or a nylon stocking; don't sand (wax clogs).", "Sprue it from the thickest section for casting."]
    if family is F.PRINTED_RESIN:
        return ["Sand wet 400 → 1000; prime and paint, or clear-coat."]
    return []
