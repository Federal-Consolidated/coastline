"""Small shared helpers (Swift: Support/Locked.swift, GRBL/GRBLText.swift)."""

from __future__ import annotations

import time


def monotonic_now() -> float:
    """Monotonic time in seconds, used for the GRBL idle/timeout logic."""
    return time.monotonic()


def sleep_ms(milliseconds: float) -> None:
    if milliseconds > 0:
        time.sleep(milliseconds / 1000)


def leading_integer(s: str) -> int | None:
    """The integer at the start of `s` (after whitespace, an optional sign), like C's `stol`."""
    s = s.lstrip()
    digits = ""
    for i, c in enumerate(s):
        if c.isascii() and c.isdigit():
            digits += c
        elif i == 0 and c in "+-":
            digits += c
        else:
            break
    try:
        return int(digits)
    except ValueError:
        return None


def parse_double(s: str) -> float | None:
    """Swift `Double(String)`: the whole string must be a number (no surrounding spaces)."""
    if not s or s != s.strip():
        return None
    try:
        value = float(s)
    except ValueError:
        return None
    lowered = s.lower()
    if lowered.startswith(("0x", "-0x", "+0x")) or "_" in s:
        return None
    return value


def parse_int(s: str) -> int | None:
    """Swift `Int(String)`: optional sign and digits only."""
    if not s:
        return None
    body = s[1:] if s[0] in "+-" else s
    if not body or not all(c.isascii() and c.isdigit() for c in body):
        return None
    return int(s)


def cpp_float(value: float) -> str:
    """`std::to_string(float)` / `%f`: 6 decimals."""
    return "%f" % value
