"""Tools and stock sizes Coastline can recommend that aren't owned yet (quantity 0). Port of
Inventory/ToolCatalog.swift and StockCatalog.swift; the entries are data/tool_catalog.json and
data/stock_catalog.json, exported from the Swift catalogs."""

from __future__ import annotations

from functools import lru_cache

from .. import codable, data


def _catalog_id(prefix: str, n: int) -> str:
    return f"{prefix}-0000-4000-8000-{n:012d}"


class ToolCatalog:
    SOURCE = "Coastline suggestion"
    VERSION = 6  # bumped when tools are added: inventories that saw an older catalog get the new ones
    RETIRED = {_catalog_id("C0A57100", n) for n in (7, 8, 9)}

    @staticmethod
    @lru_cache(maxsize=1)
    def _suggestions():
        from .items import Tool
        return tuple(codable.from_json(Tool, d) for d in data.load("tool_catalog.json"))

    @staticmethod
    def suggestions():
        return [t.copy() for t in ToolCatalog._suggestions()]


class StockCatalog:
    SOURCE = "Coastline suggestion · standard size"
    VERSION = 2
    CUT_LENGTH = 150.0

    @staticmethod
    @lru_cache(maxsize=1)
    def _suggestions():
        from .items import StockItem
        return tuple(codable.from_json(StockItem, d) for d in data.load("stock_catalog.json"))

    @staticmethod
    def suggestions():
        return [s.copy() for s in StockCatalog._suggestions()]

    @staticmethod
    def basic_bookend_blanks():
        """The reviewed Bookend's 2-inch square section, 4" and 6" long (catalog 16, 17)."""
        ids = {_catalog_id("C0A57200", 16), _catalog_id("C0A57200", 17)}
        return [s for s in StockCatalog.suggestions() if s.id in ids]
