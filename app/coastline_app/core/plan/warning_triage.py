"""Sorts an operation's engine warnings into real warnings and notes the plan already handles
("too big for X" when a later, smaller tool is there for exactly that). Port of Plan/WarningTriage.swift."""

from __future__ import annotations

from ..feeds import OperationKind as K


def split(warnings: list[str], k: int, planned: list) -> tuple[list[str], list[str]]:
    if not 0 <= k < len(planned):
        return list(warnings), []
    d = planned[k].tool.diameter

    def smaller_later(kinds, after: bool = True) -> bool:
        return any((j > k if after else j != k) and planned[j].operation.kind in kinds and planned[j].tool.diameter < d - 1e-6
                   for j in range(len(planned)))

    keep, notes = [], []
    for w in warnings:
        if "too narrow to rough with this" in w:
            handled = smaller_later({K.ADAPTIVE, K.CONTOUR})
        elif "too narrow for the ⌀" in w:
            # Floors a smaller end mill reaches (its floor pass, or its pocket roughing).
            handled = smaller_later({K.FLOOR, K.ADAPTIVE}, after=False)
        elif "is too big to bore it" in w:
            handled = smaller_later({K.BORE, K.DRILL}, after=False)
        else:
            handled = False
        (notes if handled else keep).append(w)
    return keep, notes
