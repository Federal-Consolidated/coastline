import CoastlineCore
import Foundation
import Observation
import SwiftUI

/// The inventory as the UI sees it: loads `Inventory.json`, autosaves edits (debounced) and
/// hands out bindings to individual items for the inspectors.
@MainActor
@Observable
final class InventoryModel {
    private(set) var inventory = Inventory()
    var lastError: String?
    /// True after the starter inventory was created, until the user dismisses the banner.
    var showStarterBanner = false

    let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var loadFailed = false

    init(fileURL: URL = InventoryModel.resolvedURL) {
        self.fileURL = fileURL
        do {
            if var loaded = try InventoryStore.load(from: fileURL) {
                // Install new definitions without replacing the user's measurements,
                // notes or quantities, including tools still marked as not owned.
                if loaded.installCatalogUpdates() { try? InventoryStore.save(loaded, to: fileURL) }
                if loaded.flatKitAdded != true {
                    let have = Set(loaded.fixtures.map(\.kind))
                    loaded.fixtures += Inventory.flatClampingKit.filter { !have.contains($0.kind) }
                    loaded.flatKitAdded = true
                    try? InventoryStore.save(loaded, to: fileURL)
                }
                loaded.stock = loaded.stock.map { loaded.resolvedStock($0) }
                inventory = loaded
            } else {
                inventory = Inventory.starter(toolLibraries: Self.bundledToolLibraries)
                inventory.installCatalogUpdates()
                showStarterBanner = true
                try InventoryStore.save(inventory, to: fileURL)
            }
            if VettedFixtureLibrary.migrate(&inventory, resources: AppModel.repoRoot.appendingPathComponent("resources")) {
                try InventoryStore.save(inventory, to: fileURL)
            }
        } catch {
            loadFailed = true
            lastError = "\(error)"
        }
    }

    /// `COASTLINE_INVENTORY` overrides the location (used by automation so tests don't touch
    /// the real file).
    static var resolvedURL: URL {
        if let path = ProcessInfo.processInfo.environment["COASTLINE_INVENTORY"] {
            return URL(fileURLWithPath: path)
        }
        return InventoryStore.defaultURL
    }

    /// The maker's Fusion libraries shipped with Coastline (`resources/libraries`).
    static var bundledToolLibraries: [URL] {
        let dir = AppModel.repoRoot.appendingPathComponent("resources/libraries")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tools" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Editing

    func update(_ change: (inout Inventory) -> Void) {
        guard !loadFailed else { return }
        change(&inventory)
        inventory.stock = inventory.stock.map { inventory.resolvedStock($0) }
        scheduleSave()
    }

    /// Customize one block without changing a shared material or a saved job's data.
    func customizeStockMaterial(_ material: Material, stockID: UUID, expectedMaterialID: String) throws {
        let next = try inventory.customizingStockMaterial(material, stockID: stockID,
                                                          expectedMaterialID: expectedMaterialID)
        try commitLibrary(next)
    }

    /// Save before publishing the replacement so a failed import leaves memory and disk intact.
    func commitLibrary(_ candidate: Inventory) throws {
        guard !loadFailed else {
            throw ResourceLibraryImport.ImportError.invalid(["The existing inventory could not be loaded. Restore it before importing or replacing library entries."])
        }
        var next = candidate
        next.stock = next.stock.map { next.resolvedStock($0) }
        try InventoryStore.save(next, to: fileURL)
        saveTask?.cancel()
        inventory = next
        lastError = nil
    }

    /// A binding to one item of a list in the inventory, by id. Returns nil if it was deleted.
    func binding<T: Identifiable>(_ list: WritableKeyPath<Inventory, [T]>, id: T.ID) -> Binding<T>? {
        guard let current = inventory[keyPath: list].first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.inventory[keyPath: list].first { $0.id == id } ?? current },
            set: { [weak self] newValue in
                self?.update { inv in
                    if let i = inv[keyPath: list].firstIndex(where: { $0.id == id }) { inv[keyPath: list][i] = newValue }
                }
            }
        )
    }

    func add<T>(_ item: T, to list: WritableKeyPath<Inventory, [T]>) {
        update { $0[keyPath: list].append(item) }
    }

    func remove<T: Identifiable>(_ ids: Set<T.ID>, from list: WritableKeyPath<Inventory, [T]>) {
        update { $0[keyPath: list].removeAll { ids.contains($0.id) } }
    }

    func duplicate<T: Identifiable & Codable>(_ id: T.ID, in list: WritableKeyPath<Inventory, [T]>, newID: (inout T) -> Void) {
        guard var copy = inventory[keyPath: list].first(where: { $0.id == id }) else { return }
        newID(&copy)
        add(copy, to: list)
    }

    func resetToStarter() {
        loadFailed = false
        inventory = Inventory.starter(toolLibraries: Self.bundledToolLibraries)
        inventory.installCatalogUpdates()
        _ = VettedFixtureLibrary.migrate(&inventory, resources: AppModel.repoRoot.appendingPathComponent("resources"))
        saveNow()  // immediately, so Inventory.json.bak holds the replaced inventory
        showStarterBanner = true
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !loadFailed else { return }
        do {
            try InventoryStore.save(inventory, to: fileURL)
            lastError = nil
        } catch {
            lastError = "Couldn't save the inventory: \(error)"
        }
    }

    // MARK: Checks

    func issues(for tool: Tool, machine: MachineProfile) -> [Issue] { InventoryChecks.check(tool, machine: machine, inventory: inventory) }
    func issues(for stock: StockItem, machine: MachineProfile) -> [Issue] { InventoryChecks.check(stock, machine: machine) }

    func worstIssue(for tool: Tool, machine: MachineProfile) -> Issue.Severity? { issues(for: tool, machine: machine).map(\.severity).max() }
    func worstIssue(for stock: StockItem, machine: MachineProfile) -> Issue.Severity? { issues(for: stock, machine: machine).map(\.severity).max() }

    /// Suggested stock was bought: it joins the inventory as owned.
    func markStockOwned(_ ids: Set<StockItem.ID>) {
        update { inv in
            for k in inv.stock.indices where ids.contains(inv.stock[k].id) && inv.stock[k].quantity == 0 {
                let suggested = inv.stock[k].isSuggestion
                inv.stock[k].quantity = 1
                if suggested {
                    inv.stock[k].supplier = ""
                    inv.stock[k].notes = inv.stock[k].notes.replacingOccurrences(of: "Not in your inventory: a standard size. ", with: "")
                }
            }
        }
    }

    /// A suggested tool was bought: it joins the inventory as owned.
    func markOwned(_ id: Tool.ID) {
        update { inv in
            for k in inv.tools.indices where inv.tools[k].id == id && inv.tools[k].quantity <= 0 {
                let suggested = inv.tools[k].isSuggestion
                inv.tools[k].quantity = 1
                if suggested { inv.tools[k].source = "Bought on Coastline's suggestion" }
            }
        }
    }
}
