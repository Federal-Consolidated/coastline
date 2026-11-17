"""JSON the way Swift's Codable writes it, so files saved by the Swift app open here and the
other way round.

Conventions (Swift's synthesized Codable + JSONEncoder defaults):
- property names are the keys: snake_case fields map to camelCase (`json_key` overrides);
- nil optionals are left out (encodeIfPresent); missing keys decode to the field default;
- enums with raw values encode as the raw value;
- `ClosedRange<Double>` encodes as `[lower, upper]` (`Range` here);
- `Date` encodes as seconds since 2001-01-01 (or ISO 8601 where the Swift code asks for it);
- dictionaries with String or Int keys are JSON objects; other key types are flat
  `[key, value, key, value]` arrays (`SwiftDict` marks those);
- doubles print as Swift does: whole numbers without `.0`.

Types with their own `to_json()` / `from_json(data)` use them.
"""

from __future__ import annotations

import dataclasses
import datetime as _dt
import json
import math
import types
import typing
from dataclasses import MISSING, dataclass, field
from enum import Enum
from typing import Any

SWIFT_EPOCH = _dt.datetime(2001, 1, 1, tzinfo=_dt.timezone.utc)


# Swift spells these in capitals inside a name (`materialID`, `spindleRPM`, `modelSHA256`).
ACRONYMS = {"id": "ID", "ids": "IDs", "rpm": "RPM", "sha256": "SHA256", "url": "URL", "uuid": "UUID", "wcs": "WCS", "dfm": "DFM"}


def camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(ACRONYMS.get(p) or (p[:1].upper() + p[1:]) for p in rest)


def jfield(default: Any = MISSING, *, key: str | None = None, default_factory: Any = MISSING, skip: bool = False,
           iso_date: bool = False, always: bool = False, compare: bool = True):
    """A dataclass field with JSON options: `key` (JSON name), `skip` (not encoded/decoded),
    `iso_date` (Date as ISO 8601), `always` (encode even when None, as `null`)."""
    meta = {"key": key, "skip": skip, "iso_date": iso_date, "always": always}
    if default_factory is not MISSING:
        return field(default_factory=default_factory, metadata=meta, compare=compare)
    return field(default=default, metadata=meta, compare=compare)


@dataclass(frozen=True)
class Range:
    """`ClosedRange<Double>`: lower…upper, encoded `[lower, upper]`."""

    lower: float
    upper: float

    def __contains__(self, v: float) -> bool:
        return self.lower <= v <= self.upper

    def clamp(self, v: float) -> float:
        return min(max(v, self.lower), self.upper)

    def to_json(self) -> list:
        return [self.lower, self.upper]

    @staticmethod
    def from_json(data) -> "Range":
        return Range(float(data[0]), float(data[1]))


class SwiftDict(dict):
    """A dictionary Swift encodes as a flat `[key, value, …]` array (non-String/Int keys)."""


class DecodeError(ValueError):
    pass


# ---------------------------------------------------------------- encode

def to_json(value: Any, iso_date: bool = False) -> Any:
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)  # numpy scalars print as np.float64(...) otherwise
    if type(value).__module__ == "numpy":
        return to_json(value.tolist(), iso_date)
    if hasattr(value, "to_json") and not isinstance(value, type):
        return value.to_json()
    if isinstance(value, _dt.datetime):
        return date_to_json(value, iso_date)
    if dataclasses.is_dataclass(value):
        out = {}
        for f in dataclasses.fields(value):
            meta = f.metadata
            if meta.get("skip"):
                continue
            v = getattr(value, f.name)
            if v is None and not meta.get("always"):
                continue
            out[meta.get("key") or camel(f.name)] = to_json(v, meta.get("iso_date", False))
        return out
    if isinstance(value, SwiftDict):
        flat = []
        for k, v in value.items():
            flat += [to_json(k), to_json(v, iso_date)]
        return flat
    if isinstance(value, dict):
        return {str(to_json(k)): to_json(v, iso_date) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [to_json(v, iso_date) for v in value]
    raise TypeError(f"cannot encode {type(value).__name__}")


def date_to_json(d: _dt.datetime, iso: bool = False):
    if d.tzinfo is None:
        d = d.replace(tzinfo=_dt.timezone.utc)
    if iso:
        return d.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return (d - SWIFT_EPOCH).total_seconds()


def date_from_json(data) -> _dt.datetime:
    if isinstance(data, (int, float)):
        return SWIFT_EPOCH + _dt.timedelta(seconds=float(data))
    text = str(data).replace("Z", "+00:00")
    return _dt.datetime.fromisoformat(text)


# ---------------------------------------------------------------- decode

_hints_cache: dict[type, dict[str, Any]] = {}


def _hints(cls: type) -> dict[str, Any]:
    hints = _hints_cache.get(cls)
    if hints is None:
        import sys
        module = sys.modules.get(cls.__module__)
        hints = typing.get_type_hints(cls, globalns=vars(module) if module else None)
        _hints_cache[cls] = hints
    return hints


def from_json(tp: Any, data: Any) -> Any:
    """Decodes `data` as type `tp` (a dataclass, Enum, Range, list[...], dict[...], X | None…)."""
    if tp is Any or tp is None:
        return data
    origin = typing.get_origin(tp)
    if origin in (typing.Union, types.UnionType):
        args = [a for a in typing.get_args(tp) if a is not type(None)]
        if data is None:
            return None
        if len(args) == 1:
            return from_json(args[0], data)
        for a in args:
            try:
                return from_json(a, data)
            except (DecodeError, TypeError, ValueError, KeyError):
                continue
        raise DecodeError(f"no union member of {tp} matches {data!r}")
    if origin in (list, typing.List):
        (item,) = typing.get_args(tp) or (Any,)
        if not isinstance(data, list):
            raise DecodeError(f"expected a list for {tp}, got {type(data).__name__}")
        return [from_json(item, d) for d in data]
    if origin in (set, frozenset):
        (item,) = typing.get_args(tp) or (Any,)
        return origin(from_json(item, d) for d in data)
    if origin is tuple:
        args = typing.get_args(tp)
        if len(args) == 2 and args[1] is Ellipsis:
            return tuple(from_json(args[0], d) for d in data)
        return tuple(from_json(a, d) for a, d in zip(args, data))
    if origin in (dict, typing.Dict) or (isinstance(origin, type) and issubclass(origin, dict)):
        kt, vt = typing.get_args(tp) or (Any, Any)
        if isinstance(origin, type) and issubclass(origin, SwiftDict):
            if not isinstance(data, list) or len(data) % 2:
                raise DecodeError("expected a flat key/value array")
            return SwiftDict((from_json(kt, data[i]), from_json(vt, data[i + 1])) for i in range(0, len(data), 2))
        if not isinstance(data, dict):
            raise DecodeError(f"expected an object for {tp}")
        return {_key(kt, k): from_json(vt, v) for k, v in data.items()}
    if tp is float:
        if isinstance(data, bool) or not isinstance(data, (int, float)):
            if isinstance(data, str) and data in ("nan", "inf", "-inf"):
                return float(data)
            raise DecodeError(f"expected a number, got {data!r}")
        return float(data)
    if tp is int:
        if isinstance(data, bool) or not isinstance(data, (int, float)) or (isinstance(data, float) and not data.is_integer()):
            raise DecodeError(f"expected an integer, got {data!r}")
        return int(data)
    if tp is bool:
        if not isinstance(data, bool):
            raise DecodeError(f"expected a bool, got {data!r}")
        return data
    if tp is str:
        if not isinstance(data, str):
            raise DecodeError(f"expected a string, got {data!r}")
        return data
    if tp is _dt.datetime:
        return date_from_json(data)
    if isinstance(tp, type):
        if issubclass(tp, Enum):
            try:
                return tp(data)
            except ValueError as e:
                raise DecodeError(str(e)) from None
        custom = tp.__dict__.get("from_json")
        if custom is not None:
            return tp.from_json(data)
        if dataclasses.is_dataclass(tp):
            return decode_dataclass(tp, data)
    raise DecodeError(f"cannot decode {tp}")


def _key(kt: Any, k: str):
    if kt is int:
        return int(k)
    if isinstance(kt, type) and issubclass(kt, Enum):
        return kt(k)
    return k


def decode_dataclass(cls: type, data: Any):
    if not isinstance(data, dict):
        raise DecodeError(f"expected an object for {cls.__name__}, got {type(data).__name__}")
    hints = _hints(cls)
    kwargs = {}
    for f in dataclasses.fields(cls):
        if not f.init:
            continue
        meta = f.metadata
        if meta.get("skip"):
            continue
        key = meta.get("key") or camel(f.name)
        if key in data and data[key] is not None:
            try:
                kwargs[f.name] = from_json(hints[f.name], data[key])
            except DecodeError as e:
                raise DecodeError(f"{cls.__name__}.{key}: {e}") from None
        elif f.default is MISSING and f.default_factory is MISSING:
            tp = hints[f.name]
            if _is_optional(tp):
                kwargs[f.name] = None
            else:
                raise DecodeError(f"{cls.__name__}: missing key {key!r}")
    return cls(**kwargs)


def _is_optional(tp: Any) -> bool:
    return typing.get_origin(tp) in (typing.Union, types.UnionType) and type(None) in typing.get_args(tp)


# ---------------------------------------------------------------- JSON text

def _swift_number(v: float) -> str:
    v = float(v)  # numpy scalars repr as np.float64(...)
    if math.isnan(v) or math.isinf(v):
        raise ValueError("Swift's JSONEncoder refuses non-finite numbers")
    if v.is_integer() and abs(v) < 1e16:
        return str(int(v))
    return repr(v)


def dumps(value: Any, *, pretty: bool = False, sort_keys: bool = True, escape_slashes: bool = False) -> str:
    """Encodes plain JSON data (already `to_json`-ed) as Swift's JSONEncoder would print it."""
    out: list[str] = []
    indent_unit = "  "

    def s(text: str) -> str:
        encoded = json.dumps(text, ensure_ascii=False)
        return encoded.replace("/", "\\/") if escape_slashes else encoded

    def emit(v: Any, depth: int) -> None:
        if v is None:
            out.append("null")
        elif v is True:
            out.append("true")
        elif v is False:
            out.append("false")
        elif isinstance(v, int):
            out.append(str(int(v)))
        elif isinstance(v, float):
            out.append(_swift_number(v))
        elif isinstance(v, str):
            out.append(s(v))
        elif isinstance(v, dict):
            items = sorted(v.items()) if sort_keys else list(v.items())
            if not items:
                out.append("{\n\n" + indent_unit * depth + "}" if pretty else "{}")
                return
            out.append("{")
            for i, (k, item) in enumerate(items):
                if i:
                    out.append(",")
                if pretty:
                    out.append("\n" + indent_unit * (depth + 1))
                out.append(s(str(k)) + (" : " if pretty else ":"))
                emit(item, depth + 1)
            if pretty:
                out.append("\n" + indent_unit * depth)
            out.append("}")
        elif isinstance(v, (list, tuple)):
            if not v:
                out.append("[\n\n" + indent_unit * depth + "]" if pretty else "[]")
                return
            out.append("[")
            for i, item in enumerate(v):
                if i:
                    out.append(",")
                if pretty:
                    out.append("\n" + indent_unit * (depth + 1))
                emit(item, depth + 1)
            if pretty:
                out.append("\n" + indent_unit * depth)
            out.append("]")
        else:
            raise TypeError(f"not JSON data: {type(v).__name__}")

    emit(value, 0)
    return "".join(out)


def encode(value: Any, *, pretty: bool = False, sort_keys: bool = True, escape_slashes: bool = False) -> bytes:
    return dumps(to_json(value), pretty=pretty, sort_keys=sort_keys, escape_slashes=escape_slashes).encode()


def decode(tp: Any, text: bytes | str) -> Any:
    return from_json(tp, json.loads(text))
