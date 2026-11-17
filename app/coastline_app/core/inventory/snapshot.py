"""The resource definitions a job was planned with. Port of Inventory/JobResourceSnapshot.swift.
Ownership stays in the local inventory; changing library geometry does not rewrite a job."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

from .items import StockItem, Tool


@dataclass
class JobResourceSnapshot:
    stock: StockItem | None = None
    tools: list[Tool] = field(default_factory=list)

    @staticmethod
    def make(stock: StockItem | None = None, tools: list[Tool] | None = None) -> "JobResourceSnapshot":
        seen, unique = set(), []
        for t in tools or []:
            if t.id not in seen:
                seen.add(t.id)
                unique.append(t)
        return JobResourceSnapshot(stock, unique)

    def capture_tools(self, ids: set[str], inventory: list[Tool]) -> None:
        seen = set()
        kept = []
        for t in self.tools:
            if t.id in ids and t.id not in seen:
                seen.add(t.id)
                kept.append(t)
        self.tools = kept
        for tid in sorted(ids):
            if not any(t.id == tid for t in self.tools):
                tool = next((t for t in inventory if t.id == tid), None)
                if tool is not None:
                    self.tools.append(copy.deepcopy(tool))

    def planning_inventory(self, inventory):
        result = inventory.copy()
        for saved in self.tools:
            tool = copy.deepcopy(saved)
            index = next((i for i, t in enumerate(result.tools) if t.id == saved.id), None)
            if index is not None:
                owned = result.tools[index]
                tool.quantity, tool.condition = owned.quantity, owned.condition
                tool.cutting_minutes, tool.cutting_distance = owned.cutting_minutes, owned.cutting_distance
                result.tools[index] = tool
            else:
                tool.quantity = 0
                result.tools.append(tool)
        return result
