"""Decorative textures, cut like engraving: the patterns of a watchmaker's rose engine and
straight-line engine. Port of Plan/Texture.swift. Lines are spaced `pitch` apart, clipped to a
circle or a rectangle centred on the engraving's position and turned by its angle."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from ..geometry import swift_round


class Pattern(Enum):
    SUNBURST = "sunburst"  # straight rays from the centre, optionally waving
    BARLEYCORN = "barleycorn"  # concentric rose rings, each turned half a lobe from the last
    FLINQUE = "flinque"  # parallel waves across the area
    CLOUS_DE_PARIS = "clousDeParis"  # two sets of straight grooves at right angles
    SPIRAL = "spiral"  # one Archimedean spiral out from the centre
    ROSETTE = "rosette"  # circles of the same size round the centre, overlapping into petals

    @property
    def title(self) -> str:
        return {"sunburst": "Sunburst (soleil)", "barleycorn": "Barleycorn (grain d'orge)", "flinque": "Flinqué waves",
                "clousDeParis": "Clous de Paris (hobnail)", "spiral": "Spiral (escargot)", "rosette": "Rosette"}[self.value]

    @property
    def waves(self) -> bool:
        return self in (Pattern.SUNBURST, Pattern.BARLEYCORN, Pattern.FLINQUE, Pattern.ROSETTE)


class Region(Enum):
    CIRCLE = "circle"
    RECTANGLE = "rectangle"


@dataclass
class Texture:
    pattern: Pattern
    region: Region = Region.CIRCLE
    width: float = 16.0  # the circle's diameter, or the rectangle's size along Y
    height: float = 16.0  # the rectangle's size up X
    pitch: float = 0.6  # between neighbouring lines, mm
    amplitude: float = 0.4  # how far the waves swing (mm; sunburst: degrees)
    lobes: int = 12

    @staticmethod
    def preset(p: Pattern) -> "Texture":
        if p is Pattern.SUNBURST:
            return Texture(p, pitch=0.5, amplitude=0, lobes=0)
        if p is Pattern.BARLEYCORN:
            return Texture(p, pitch=0.5, amplitude=0.35, lobes=18)
        if p is Pattern.FLINQUE:
            return Texture(p, Region.RECTANGLE, 20, 12, 0.5, 0.3, 6)
        if p is Pattern.CLOUS_DE_PARIS:
            return Texture(p, Region.RECTANGLE, 20, 12, 0.8, 0, 0)
        if p is Pattern.SPIRAL:
            return Texture(p, pitch=0.5, amplitude=0, lobes=0)
        return Texture(p, pitch=0.6, amplitude=3, lobes=0)

    @property
    def size(self) -> tuple[float, float]:
        return (self.width, self.width) if self.region is Region.CIRCLE else (self.width, self.height)

    def lines(self) -> list[list[tuple[float, float]]]:
        """The pattern's lines in its own frame (centred on 0, u along, v up), clipped to the region."""
        pitch = max(self.pitch, 0.05)
        r = max(self.width, 0.5) / 2
        half = (max(self.width, 0.5) / 2, max(self.width if self.region is Region.CIRCLE else self.height, 0.5) / 2)
        reach = r if self.region is Region.CIRCLE else math.hypot(*half)
        step = 0.1
        raw: list[list[tuple[float, float]]] = []
        amplitude, lobes = self.amplitude, self.lobes

        def circle(c, radius, wave=lambda t: 0.0):
            n = max(math.ceil(2 * math.pi * radius / step), 24)
            out = []
            for k in range(n + 1):
                t = 2 * math.pi * k / n
                rr = radius + wave(t)
                out.append((c[0] + rr * math.cos(t), c[1] + rr * math.sin(t)))
            return out

        P = self.pattern
        if P is Pattern.SUNBURST:
            rays = max(int(swift_round(2 * math.pi * reach / pitch)), 8)
            r0 = max(reach * 0.06, 0.4)
            for k in range(rays):
                a0 = 2 * math.pi * k / rays
                n = max(math.ceil((reach - r0) / step), 2)
                line = []
                for i in range(n + 1):
                    rr = r0 + (reach - r0) * i / n
                    a = a0 + amplitude * math.pi / 180 * math.sin(max(lobes, 1) * 2 * math.pi * rr / reach)
                    line.append((rr * math.cos(a), rr * math.sin(a)))
                raw.append(line)
        elif P is Pattern.BARLEYCORN:
            n = max(lobes, 3)
            radius = max(pitch, 2.5 * amplitude)
            ring = 0
            while radius - amplitude <= reach:
                phase = (ring % 2) * math.pi / n
                raw.append(circle((0.0, 0.0), radius, lambda t, phase=phase: amplitude * math.cos(n * t + phase)))
                radius += pitch
                ring += 1
        elif P is Pattern.FLINQUE:
            waves = float(max(lobes, 1))
            v = -reach
            while v <= reach:
                n = max(math.ceil(2 * reach / step), 2)
                line = []
                for i in range(n + 1):
                    u = -reach + 2 * reach * i / n
                    line.append((u, v + amplitude * math.sin(2 * math.pi * waves * (u + reach) / (2 * half[0]))))
                raw.append(line)
                v += pitch
        elif P is Pattern.CLOUS_DE_PARIS:
            for a in (math.pi / 4, -math.pi / 4):
                d = (math.cos(a), math.sin(a))
                nrm = (-d[1], d[0])
                off = -reach
                while off <= reach:
                    n = max(math.ceil(2 * reach / step), 2)
                    line = []
                    for i in range(n + 1):
                        s = -reach + 2 * reach * i / n
                        line.append((nrm[0] * off + d[0] * s, nrm[1] * off + d[1] * s))
                    raw.append(line)
                    off += pitch
        elif P is Pattern.SPIRAL:
            turns = reach / pitch
            n = max(math.ceil(math.pi * reach * turns / step), 24)
            line = []
            for i in range(n + 1):
                t = 2 * math.pi * turns * i / n
                rr = pitch * t / (2 * math.pi)
                line.append((rr * math.cos(t), rr * math.sin(t)))
            raw.append(line)
        else:  # rosette
            offset = min(max(amplitude, pitch), reach * 0.9)
            radius = reach - offset
            count = max(int(swift_round(2 * math.pi * offset / pitch)), 6)
            for k in range(count):
                a = 2 * math.pi * k / count
                raw.append(circle((offset * math.cos(a), offset * math.sin(a)), radius))

        def inside(p) -> bool:
            if self.region is Region.CIRCLE:
                return math.hypot(p[0], p[1]) <= r + 1e-9
            return abs(p[0]) <= half[0] + 1e-9 and abs(p[1]) <= half[1] + 1e-9

        out = []
        for line in raw:  # each line split where it leaves the region (pieces under 4 points dropped)
            run = []
            for p in line:
                if inside(p):
                    run.append(p)
                elif run:
                    if len(run) > 3:
                        out.append(run)
                    run = []
            if len(run) > 3:
                out.append(run)
        return out
