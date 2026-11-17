"""Built-in catalog data, exported once from the Swift app's catalogs as JSON (coastline_app/data)."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


@lru_cache(maxsize=None)
def load(name: str):
    return json.loads((DATA_DIR / name).read_text(encoding="utf-8"))
