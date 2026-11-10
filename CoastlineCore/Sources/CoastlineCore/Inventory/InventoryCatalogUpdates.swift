import Foundation

extension Inventory {
    /// Install newly published suggestions once, without replacing any existing item.
    /// A quantity-zero item can still contain the user's measurements or buying notes.
    /// Version markers also preserve a user's removal of a suggestion between updates.
    @discardableResult
    public mutating func installCatalogUpdates() -> Bool {
        var changed = false
        if toolSuggestionsAdded != true || (toolSuggestionsVersion ?? 1) < ToolCatalog.version {
            var have = Set(tools.map(\.id))
            tools += ToolCatalog.suggestions.filter { have.insert($0.id).inserted }
            tools.removeAll { ToolCatalog.retired.contains($0.id) && $0.isSuggestion }
            toolSuggestionsAdded = true
            toolSuggestionsVersion = ToolCatalog.version
            changed = true
        }
        if (stockSuggestionsVersion ?? 0) < StockCatalog.version {
            var have = Set(stock.map(\.id))
            stock += StockCatalog.suggestions.filter { have.insert($0.id).inserted }
            stockSuggestionsVersion = StockCatalog.version
            changed = true
        }
        return changed
    }
}
