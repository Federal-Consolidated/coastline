"""Small text helpers shared by planning messages (Swift: DFM.mm, DFM.size, DFM.dims)."""

from __future__ import annotations

from ..geometry import swift_round
from ..units import Length


def mm(v: float, step: float = 0.001) -> str:
    """`v` rounded to `step`, as Length.mm prints it."""
    return Length.mm(swift_round(v / step) * step)


def size(d: float) -> str:
    """'1/4"' when it is a common inch size, else '6 mm'."""
    return Length.inch_fraction(d) or f"{mm(d)} mm"


def dims(v) -> str:
    return f"{mm(v[0], 0.1)} x {mm(v[1], 0.1)} x {mm(v[2], 0.1)}"
