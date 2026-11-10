import Foundation

extension Inventory {
    /// Give one stock item its own material definition without editing shared cutting data.
    /// The caller commits the returned inventory only after saving it successfully.
    public func customizingStockMaterial(_ material: Material, stockID: UUID,
                                         expectedMaterialID: String) throws -> Inventory {
        guard material.validationIssues.isEmpty else {
            throw ResourceLibraryImport.ImportError.invalid(material.validationIssues)
        }
        let matching = stock.indices.filter { stock[$0].id == stockID }
        guard matching.count == 1, let index = matching.first else {
            throw ResourceLibraryImport.ImportError.invalid(["This stock is no longer available. Select it again before editing its material."])
        }
        guard stock[index].materialID == expectedMaterialID else {
            throw ResourceLibraryImport.ImportError.invalid(["This stock's material changed while you were editing. Reopen its current material before saving."])
        }
        let reserved = Set((customMaterials ?? []).map(\.id))
            .union(stock.map(\.materialID))
            .union(stock.compactMap { $0.materialSnapshot?.id })
        guard MaterialLibrary.material(id: material.id) == nil, !reserved.contains(material.id) else {
            throw ResourceLibraryImport.ImportError.invalid(["Use a new custom material identity for this stock. Existing material definitions must remain unchanged."])
        }
        var next = self
        next.customMaterials = (customMaterials ?? []) + [material]
        next.stock[index].materialID = material.id
        next.stock[index].materialSnapshot = material
        return next
    }
}
