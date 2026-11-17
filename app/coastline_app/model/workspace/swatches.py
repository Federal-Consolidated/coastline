"""A colour that reads as the material (Theme.swift: Material.Family.swatch, Material.swatch), sRGB 0–1."""

FAMILY = {"aluminium": (0.78, 0.80, 0.83), "copperAlloy": (0.85, 0.66, 0.32), "steel": (0.52, 0.54, 0.57),
          "stainless": (0.70, 0.72, 0.75), "titanium": (0.55, 0.58, 0.68), "plastic": (0.93, 0.93, 0.90),
          "printedResin": (0.45, 0.47, 0.50), "wax": (0.30, 0.62, 0.48)}
BY_ID = {"copper-c110": (0.80, 0.45, 0.30), "bronze-c932": (0.72, 0.52, 0.30), "bronze-c510": (0.72, 0.52, 0.30),
         "nickel-silver-c752": (0.80, 0.80, 0.74), "fl-standard": (0.85, 0.88, 0.92), "fl-castable-wax-40": (0.45, 0.62, 0.85),
         "fl-tough-2000": (0.40, 0.42, 0.45), "wax-machinable": (0.25, 0.45, 0.80)}


def swatch(material) -> tuple[float, float, float]:
    return BY_ID.get(material.id) or FAMILY[material.family.value]


def swatch_hex(material) -> str:
    r, g, b = swatch(material) if material is not None else (0.5, 0.5, 0.5)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))
