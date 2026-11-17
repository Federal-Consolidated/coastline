"""Contour map (M111–M114), M102 expressions and M106 checks. Port of CustomMCodes.swift."""

from __future__ import annotations

import math
import re
import threading
from dataclasses import dataclass, field
from typing import Callable

from .errors import MillError, MillErrorKind as K
from .gcode import GCodeLine, chunk_gcode_line
from .geometry import AXES, Axis, Point3
from .support import parse_double


def _cross(a: Point3, b: Point3) -> Point3:
    return Point3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


@dataclass(frozen=True)
class Plane:
    normal: Point3
    intercept: float

    def z(self, p: Point3) -> float:
        return (self.intercept - self.normal.x * p.x - self.normal.y * p.y) / self.normal.z


class ContourMap:
    """Probed surface points and the Z compensation built from them."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._points: list[Point3] = []
        self._enabled = False
        self._previous_z = ""

    @property
    def is_enabled(self) -> bool:
        with self._lock:
            return self._enabled

    @property
    def points(self) -> list[Point3]:
        with self._lock:
            return list(self._points)

    @property
    def previous_z(self) -> str:
        with self._lock:
            return self._previous_z

    @previous_z.setter
    def previous_z(self, v: str) -> None:
        with self._lock:
            self._previous_z = v

    def add(self, point: Point3) -> bool:
        """Adds a point unless one with the same X/Y exists."""
        with self._lock:
            if any(p.x == point.x and p.y == point.y for p in self._points):
                return False
            self._points.append(point)
            return True

    def enable(self, log) -> None:
        from .serial_connection import LogKind
        if len(self.points) < 3:
            raise MillError(K.M112_FAIL, "M112 Failed. Contour map needs at least 3 points.")
        log.add(LogKind.WRITE, "M112: Contour Adjustment Enabled")
        with self._lock:
            self._enabled = True

    def disable(self, log) -> None:
        from .serial_connection import LogKind
        log.add(LogKind.WRITE, "M113: Contour Adjustment Disabled")
        with self._lock:
            self._enabled = False

    def clear(self, log) -> None:
        from .serial_connection import LogKind
        with self._lock:
            self._points.clear()
        log.add(LogKind.WRITE, "M114: Contour Map Cleared")
        self.disable(log)

    @staticmethod
    def plane(a: Point3, b: Point3, c: Point3) -> Plane | None:
        n = _cross(b - a, c - a)
        if n.x * n.x + n.y * n.y + n.z * n.z == 0:
            return None
        return Plane(n, n.x * a.x + n.y * a.y + n.z * a.z)

    @staticmethod
    def is_surrounded(q: Point3, a: Point3, b: Point3, c: Point3) -> bool:
        ab, bc, ca = _cross(b - a, q - a).z, _cross(c - b, q - b).z, _cross(a - c, q - c).z
        return (ab > 0 and bc > 0 and ca > 0) or (ab < 0 and bc < 0 and ca < 0)

    @staticmethod
    def distance(a: Point3, b: Point3) -> float:
        d = b - a
        return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)

    def offset_plane(self, point: Point3) -> Plane:
        """Plane through the two nearest points and a third, preferring triangles that surround
        the target."""
        pts = self.points
        order = sorted(range(len(pts)), key=lambda i: self.distance(point, pts[i]))
        if len(order) < 3:
            raise MillError(K.M112_FAIL, "Contour map needs at least 3 points.")
        p1, p2 = pts[order[0]], pts[order[1]]
        for prefer_surrounding in (True, False):
            for k in order[2:]:
                p3 = pts[k]
                if prefer_surrounding and not self.is_surrounded(point, p1, p2, p3):
                    continue
                plane = self.plane(p1, p2, p3)
                if plane is not None and plane.normal.z != 0:
                    return plane
        raise MillError(K.M112_FAIL, "No unique plane found. You must have at least three **non-colinear** points stored "
                                     "with M111 for the sender to perform slope adjustment.")

    def transform_absolute_z(self, line: GCodeLine, point: Point3, wcs: Point3) -> str:
        plane = self.offset_plane(point)
        z = (plane.z(point) - wcs.z) + (point.z - wcs.z)
        return self.replace_z(line.original, z)

    def transform_relative_z(self, line: GCodeLine, previous: Point3, nxt: Point3) -> str:
        plane = self.offset_plane(previous)
        depth = nxt.z - previous.z
        return self.replace_z(line.original, depth + plane.z(nxt) - plane.z(previous))

    @staticmethod
    def replace_z(line: str, z: float) -> str:
        """Replace or append ` Z<value>` (truncated to 3 decimals), dropping duplicate X/Y words."""
        text = "%f" % z
        dot = text.find(".")
        if dot >= 0:
            text = text[:dot + 4]
        result, need_z, has_x, has_y = "", True, False, False
        for chunk in chunk_gcode_line(line):
            first = chunk[:1]
            if first == "Z":
                result += " Z" + text
                need_z = False
            elif first == "X":
                if not has_x:
                    has_x = True
                    result += chunk
            elif first == "Y":
                if not has_y:
                    has_y = True
                    result += chunk
            else:
                result += chunk
        if need_z:
            result += " Z" + text
        return result


class WCSExpressionError(Exception):
    pass


class WCSExpression:
    """A small arithmetic evaluator for M102: numbers, `+ - * / % ^`, unary minus, parentheses,
    functions `abs min max sqrt floor ceil round`, and WCS registers like `G54X`."""

    @staticmethod
    def is_register(s: str) -> bool:
        """`[Gg]5[4-9][X-Zx-z]`"""
        return len(s) == 4 and s[0] in "Gg" and s[1] == "5" and s[2] in "456789" and s[3] in "XYZxyz"

    @staticmethod
    def evaluate(text: str, register: Callable[[str], float | None]) -> float:
        p = _Parser(text, register)
        value = p.expression()
        if not p.at_end:
            raise WCSExpressionError()
        return value


class _Parser:
    def __init__(self, text: str, register) -> None:
        self.s, self.register, self.i = text, register, 0

    @property
    def at_end(self) -> bool:
        return self.i >= len(self.s)

    def peek(self) -> str | None:
        return self.s[self.i] if self.i < len(self.s) else None

    def expression(self) -> float:
        value = self.term()
        while self.peek() in ("+", "-"):
            c = self.peek()
            self.i += 1
            rhs = self.term()
            value = value + rhs if c == "+" else value - rhs
        return value

    def term(self) -> float:
        value = self.power()
        while self.peek() in ("*", "/", "%"):
            c = self.peek()
            self.i += 1
            rhs = self.power()
            if c == "*":
                value *= rhs
            elif c == "/":
                value = value / rhs if rhs != 0 else (math.copysign(math.inf, value) if value else math.nan)
            else:
                value = math.fmod(value, rhs) if rhs != 0 else math.nan
        return value

    def power(self) -> float:
        base = self.unary()
        if self.peek() == "^":
            self.i += 1
            return math.pow(base, self.power())
        return base

    def unary(self) -> float:
        if self.peek() == "-":
            self.i += 1
            return -self.unary()
        if self.peek() == "+":
            self.i += 1
            return self.unary()
        return self.primary()

    def primary(self) -> float:
        c = self.peek()
        if c is None:
            raise WCSExpressionError()
        if c == "(":
            self.i += 1
            value = self.expression()
            if self.peek() != ")":
                raise WCSExpressionError()
            self.i += 1
            return value
        if c.isdigit() or c == ".":
            start = self.i
            while self.peek() is not None and (self.peek().isdigit() or self.peek() == "."):
                self.i += 1
            v = parse_double(self.s[start:self.i])
            if v is None:
                raise WCSExpressionError()
            return v
        if self.i + 4 <= len(self.s) and WCSExpression.is_register(self.s[self.i:self.i + 4]):
            name = self.s[self.i:self.i + 4].upper()
            self.i += 4
            v = self.register(name)
            if v is None:
                raise WCSExpressionError()
            return v
        if c.isalpha():
            start = self.i
            while self.peek() is not None and self.peek().isalpha():
                self.i += 1
            name = self.s[start:self.i].lower()
            if self.peek() != "(":
                raise WCSExpressionError()
            self.i += 1
            args = [self.expression()]
            while self.peek() == ",":
                self.i += 1
                args.append(self.expression())
            if self.peek() != ")":
                raise WCSExpressionError()
            self.i += 1
            if len(args) == 1:
                fn = {"abs": abs, "sqrt": math.sqrt, "floor": math.floor, "ceil": math.ceil,
                      "round": lambda v: math.floor(abs(v) + 0.5) * (1 if v >= 0 else -1)}.get(name)
                if fn is not None:
                    try:
                        return float(fn(args[0]))
                    except ValueError:
                        return math.nan
            if name == "min" and len(args) >= 2:
                return min(args)
            if name == "max" and len(args) >= 2:
                return max(args)
            raise WCSExpressionError()
        raise WCSExpressionError()


_REGISTER = re.compile(r"^G5[4-9][xyz]{1,3}$", re.IGNORECASE)


@dataclass
class Comparand:
    number: float = 0.0
    register: str = ""
    axes: list[Axis] = field(default_factory=list)


@dataclass
class M106Check:
    """`M106 G54X > G55X error: Stock too short` and friends."""

    left: Comparand
    op: str
    right: Comparand
    error_message: str

    @staticmethod
    def parse(text: str) -> "M106Check":
        lower = text.lower()
        at = lower.rfind("error")
        statement = text[:at] if at >= 0 else text  # the error clause is optional (a bare comparison is accepted)
        colon = lower.rfind("error:")
        message = text[colon + 6:] if colon >= 0 else ""
        m = re.search(r"[!<>=]=?", statement)
        if m is None:
            raise MillError(K.M106_MALFORMED_TEST)
        op = m.group(0)
        left_text = statement[:m.start()].strip(" \t")
        right_text = statement[m.end():].strip(" \t")
        if not _REGISTER.match(left_text):
            raise MillError(K.M106_MALFORMED_TEST)
        if not (_REGISTER.match(right_text) or parse_double(right_text) is not None):
            raise MillError(K.M106_MALFORMED_TEST)
        return M106Check(_comparand(left_text), op, _comparand(right_text), message)

    def evaluate(self, offsets: list[tuple[str, Point3]]) -> bool:
        def values(c: Comparand) -> dict[Axis, float]:
            p = next((pt for n, pt in offsets if n == c.register), None)
            return {a: (0.0 if p is None else p[a]) for a in c.axes}

        def compare(a: float, b: float) -> bool:
            l, r = a + 1, b + 1  # the original adds 1 to both sides "to fix -0 vs +0"
            ops = {"<": l < r, "<=": l <= r, ">": l > r, ">=": l >= r, "==": l == r, "!=": l != r}
            if self.op not in ops:
                raise MillError(K.M106_MALFORMED_TEST)
            return ops[self.op]

        lv, rv = values(self.left), values(self.right)
        lc, rc = len(self.left.axes), len(self.right.axes)

        def single(c: Comparand, v: dict[Axis, float]) -> float:
            return c.number if not c.axes else v[c.axes[0]]

        if lc <= 1 and rc <= 1:
            return compare(single(self.left, lv), single(self.right, rv))
        if lc == rc:
            if not set(self.left.axes) <= set(self.right.axes):
                raise MillError(K.M106_MALFORMED_TEST)
            return all(compare(lv[a], rv[a]) for a in self.left.axes)
        if lc <= 1:
            l = single(self.left, lv)
            return all(compare(l, rv[a]) for a in self.right.axes)
        if rc <= 1:
            r = single(self.right, rv)
            return all(compare(lv[a], r) for a in self.left.axes)
        raise MillError(K.M106_MALFORMED_TEST)


def _comparand(text: str) -> Comparand:
    number = parse_double(text)
    if number is not None:
        return Comparand(number=number)
    upper = text.upper()
    return Comparand(register=upper[:3], axes=[a for a in AXES if a.value in upper[3:]])
