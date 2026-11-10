import CryptoKit
import Foundation

/// A portable stock, cutting-tool and material library (`.coastlib`, JSON).
/// Geometry uses the declared length unit; material values always use the explicit SI-derived units below.
public struct ResourceLibraryPackage: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public struct Units: Codable, Equatable, Sendable {
        public var length: String
        public var feed: String
        public var density: String
        public var surfaceSpeed: String
        public var specificCuttingForce: String

        public init(length: String = "mm", feed: String = "mm/min", density: String = "g/cm3",
                    surfaceSpeed: String = "m/min", specificCuttingForce: String = "N/mm2") {
            self.length = length; self.feed = feed; self.density = density
            self.surfaceSpeed = surfaceSpeed; self.specificCuttingForce = specificCuttingForce
        }
        public static let millimeters = Units()
        public static let inches = Units(length: "in", feed: "in/min")
    }

    public var schemaVersion = Self.currentSchema
    public var name: String
    public var units: Units
    public var stock: [StockItem]
    public var tools: [Tool]
    public var materials: [Material]
    /// Import notes, including dimensions inferred by the Fusion importer.
    public var warnings: [String] = []

    public init(name: String, stock: [StockItem] = [], tools: [Tool] = [], materials: [Material] = [],
                units: Units = .millimeters) {
        self.name = name; self.stock = stock; self.tools = tools; self.materials = materials; self.units = units
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, name, units, stock, tools, materials, warnings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        name = try c.decode(String.self, forKey: .name)
        units = try c.decode(Units.self, forKey: .units)
        stock = try c.decodeIfPresent([StockItem].self, forKey: .stock) ?? []
        tools = try c.decodeIfPresent([Tool].self, forKey: .tools) ?? []
        materials = try c.decodeIfPresent([Material].self, forKey: .materials) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// Exports selected rows and every material used by their stock. nil selects all rows of that kind.
    public static func exporting(_ inventory: Inventory, name: String, stockIDs: Set<UUID>? = nil,
                                 toolIDs: Set<UUID>? = nil, materialIDs: Set<String>? = nil) throws -> Self {
        let stock = inventory.stock.filter { stockIDs?.contains($0.id) ?? true }.map(inventory.resolvedStock)
        let tools = inventory.tools.filter { toolIDs?.contains($0.id) ?? true }
        var materials = inventory.materials.filter { materialIDs?.contains($0.id) ?? (MaterialLibrary.material(id: $0.id) == nil) }
        for item in stock {
            guard let material = item.material else {
                throw ResourceLibraryImport.ImportError.invalid(["Stock \(item.sizeDescription) has no material definition for \(item.materialID)."])
            }
            if let existing = materials.first(where: { $0.id == material.id }), existing != material {
                throw ResourceLibraryImport.ImportError.invalid(["Stock uses a different saved definition of \(material.name). Export it separately or select the current material first."])
            }
            if !materials.contains(where: { $0.id == material.id }) { materials.append(material) }
        }
        return try Self(name: name, stock: stock, tools: tools, materials: materials).canonicalized()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(canonicalized())
    }

    /// Normalizes lengths and rejects malformed packages before a merge can change inventory.
    public func canonicalized() throws -> Self {
        guard schemaVersion == Self.currentSchema else {
            throw ResourceLibraryImport.ImportError.invalid(["Unsupported library format \(schemaVersion); this app supports format \(Self.currentSchema)."])
        }
        guard units == .millimeters || units == .inches else {
            throw ResourceLibraryImport.ImportError.invalid(["Unsupported or inconsistent units. Use mm with mm/min, or in with in/min; materials use g/cm3, m/min and N/mm2."])
        }
        var result = self
        if units == .inches {
            result.warnings.append("Converted inch dimensions and feeds to millimetres and mm/min. Material values retain their declared SI-derived units.")
            result.stock = stock.map { item in
                var s = item; s.sizeX *= 25.4; s.sizeY *= 25.4; s.sizeZ *= 25.4; return s
            }
            result.tools = tools.map { item in
                var t = item
                t.diameter *= 25.4; t.shankDiameter *= 25.4; t.fluteLength *= 25.4
                t.stickout *= 25.4; t.overallLength *= 25.4; t.cornerRadius *= 25.4; t.tipDiameter *= 25.4
                t.threadPitch = t.threadPitch.map { $0 * 25.4 }; t.cuttingDistance *= 25.4
                t.presets = t.presets.map { preset in
                    var p = preset
                    p.feed *= 25.4; p.plungeFeed *= 25.4; p.rampFeed *= 25.4
                    p.stepdown = p.stepdown.map { $0 * 25.4 }; p.stepover = p.stepover.map { $0 * 25.4 }
                    return p
                }
                return t
            }
        }
        result.units = .millimeters
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Give the library a name.") }
        if Set(stock.map(\.id)).count != stock.count { problems.append("The library contains duplicate stock IDs.") }
        if Set(tools.map(\.id)).count != tools.count { problems.append("The library contains duplicate tool IDs.") }
        if Set(materials.map(\.id)).count != materials.count { problems.append("The library contains duplicate material IDs.") }
        for item in result.stock { problems += ResourceLibraryValidation.issues(for: item).map { "Stock \(item.sizeDescription): \($0)" } }
        for item in result.tools { problems += ResourceLibraryValidation.issues(for: item).map { "\(item.name): \($0)" } }
        for material in result.materials { problems += material.validationIssues.map { "\(material.name): \($0)" } }
        guard problems.isEmpty else { throw ResourceLibraryImport.ImportError.invalid(problems) }
        return result
    }
}

/// Validation for resource files and the corresponding stock/tool editors. Machine fit is a separate check.
public enum ResourceLibraryValidation {
    public static func issues(for stock: StockItem) -> [String] {
        var issues: [String] = []
        if stock.materialID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Choose a material.") }
        if ![stock.sizeX, stock.sizeY].allSatisfy({ $0.isFinite && $0 > 0 }) ||
            !stock.sizeZ.isFinite || (stock.shape == .roundBar ? stock.sizeZ < 0 : stock.sizeZ <= 0) {
            issues.append("Stock dimensions must be finite and positive (round-bar Z may be zero).")
        }
        if stock.quantity < 0 { issues.append("Quantity cannot be negative.") }
        if let cost = stock.unitCost, !cost.isFinite || cost < 0 { issues.append("Cost must be finite and nonnegative.") }
        if let axis = stock.extrusionAxis, !(0 ... 2).contains(axis) { issues.append("Extrusion axis must be X, Y or Z.") }
        if let material = stock.materialSnapshot {
            if material.id != stock.materialID { issues.append("The embedded material does not match the stock's material ID.") }
            issues += material.validationIssues
        }
        return issues
    }

    public static func issues(for tool: Tool) -> [String] {
        var issues: [String] = []
        if tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Give the tool a name.") }
        let draft = tool.requiresSpecificationReview
        if ![tool.diameter, tool.shankDiameter, tool.fluteLength, tool.stickout, tool.overallLength].allSatisfy({ $0.isFinite && (draft ? $0 >= 0 : $0 > 0) }) {
            issues.append("Tool diameters and lengths must be finite and positive.")
        }
        if tool.overallLength > 0 && (tool.fluteLength > tool.overallLength || tool.stickout > tool.overallLength) { issues.append("Flute length and stickout cannot exceed overall length.") }
        if draft ? tool.flutes < 0 : tool.flutes <= 0 { issues.append("The number of flutes must be positive.") }
        if tool.coating == .unspecified && !draft { issues.append("Confirm the tool's coating, including uncoated if applicable.") }
        if tool.toolMaterial == .unspecified && !draft { issues.append("Confirm the tool's cutting material.") }
        if let fields = tool.unconfirmedSpecifications,
           fields.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append("Unconfirmed specifications must identify the missing measurements.")
        }
        if !tool.cornerRadius.isFinite || tool.cornerRadius < 0 || tool.cornerRadius > tool.diameter / 2 { issues.append("Corner radius must be between zero and half the tool diameter.") }
        if !tool.tipDiameter.isFinite || tool.tipDiameter < 0 || tool.tipDiameter > tool.diameter { issues.append("Tip diameter must fit inside the tool diameter.") }
        if let angle = tool.angle, !angle.isFinite || angle <= 0 || angle > 180 { issues.append("Tool angle must be between zero and 180 degrees.") }
        if let pitch = tool.threadPitch, !pitch.isFinite || pitch <= 0 { issues.append("Thread pitch must be positive and finite.") }
        if tool.quantity < 0 { issues.append("Quantity cannot be negative.") }
        if let cost = tool.unitCost, !cost.isFinite || cost < 0 { issues.append("Cost must be finite and nonnegative.") }
        if ![tool.cuttingMinutes, tool.cuttingDistance].allSatisfy({ $0.isFinite && $0 >= 0 }) { issues.append("Tool usage cannot be negative or nonfinite.") }
        for preset in tool.presets {
            if !preset.rpm.isFinite || preset.rpm <= 0 || ![preset.feed, preset.plungeFeed, preset.rampFeed].allSatisfy({ $0.isFinite && $0 >= 0 }) {
                issues.append("Preset \(preset.name) needs a positive spindle speed and finite, nonnegative feeds.")
            }
            if [preset.stepdown, preset.stepover].compactMap({ $0 }).contains(where: { !$0.isFinite || $0 <= 0 }) { issues.append("Preset \(preset.name) depths must be finite and positive.") }
        }
        return issues
    }
}

public enum ResourceLibraryImport {
    public enum ConflictPolicy: String, CaseIterable, Sendable { case keepExisting, replaceExisting, addAsCopy }
    public enum Kind: String, Sendable { case stock, tool, material }
    public enum Action: String, Sendable { case add, keep, replace, copy }
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let name: String
        public let action: Action
        public let detail: String
        public let quantity: Int?
        public let dimensions: String?

        init(id: String, kind: Kind, name: String, action: Action, detail: String,
             quantity: Int? = nil, dimensions: String? = nil) {
            self.id = id; self.kind = kind; self.name = name; self.action = action; self.detail = detail
            self.quantity = quantity; self.dimensions = dimensions
        }
    }
    public struct Preview: Equatable, Sendable {
        public let inventory: Inventory
        public let rows: [Row]
        public let warnings: [String]
        public var addedCount: Int { rows.filter { $0.action == .add }.count }
        public var replacedCount: Int { rows.filter { $0.action == .replace }.count }
        public var keptCount: Int { rows.filter { $0.action == .keep }.count }
        public var copiedCount: Int { rows.filter { $0.action == .copy }.count }
    }
    public enum ImportError: Error, LocalizedError, CustomStringConvertible {
        case invalid([String])
        public var description: String { switch self { case .invalid(let issues): issues.joined(separator: "\n") } }
        public var errorDescription: String? { description }
    }

    public static func load(_ url: URL) throws -> ResourceLibraryPackage {
        if url.pathExtension.lowercased() == "tools" {
            return try fusionPackage(ToolLibraryImport.load(url), name: url.deletingPathExtension().lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["data"] != nil, root["schemaVersion"] == nil {
            return try fusionPackage(ToolLibraryImport.parse(data, sourceName: url.lastPathComponent), name: url.deletingPathExtension().lastPathComponent)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ResourceLibraryPackage {
        try JSONDecoder().decode(ResourceLibraryPackage.self, from: data).canonicalized()
    }

    private static func fusionPackage(_ result: ToolLibraryImport.Result, name: String) throws -> ResourceLibraryPackage {
        guard !result.tools.isEmpty else { throw ImportError.invalid(["No supported cutting tools were found."] + result.skipped) }
        var package = ResourceLibraryPackage(name: name, tools: result.tools)
        package.warnings = result.warnings + result.skipped.map { "Skipped: \($0)" }
        return try package.canonicalized()
    }

    /// Pure transaction: no caller-owned inventory is mutated until it accepts this complete preview.
    public static func prepare(_ incoming: ResourceLibraryPackage, into inventory: Inventory,
                               policy: ConflictPolicy = .keepExisting) throws -> Preview {
        let package = try incoming.canonicalized()
        var merged = inventory
        var rows: [Row] = []
        var warnings = package.warnings
        var remappedMaterials: [String: String] = [:]
        var candidates = package.materials
        // An embedded stock definition also makes a custom material portable by itself.
        for stock in package.stock {
            guard let embedded = stock.materialSnapshot else { continue }
            if let material = candidates.first(where: { $0.id == embedded.id }) {
                guard material == embedded else { throw ImportError.invalid(["Stock and library disagree about material \(embedded.id)."] ) }
            } else { candidates.append(embedded) }
        }
        for material in candidates {
            let existing = merged.material(id: material.id)
            let builtin = MaterialLibrary.material(id: material.id) != nil
            var value = material
            let action: Action
            var detail = "New material"
            if let existing {
                if existing == material || policy == .keepExisting {
                    action = .keep; detail = existing == material ? "Already installed" : "Keep your existing material"
                    if existing != material { warnings.append("\(material.name): stock will use your existing material definition.") }
                } else if policy == .addAsCopy || builtin {
                    value.id = "custom-" + String(stableDigest("material-copy:" + (try canonicalString(material))).prefix(24))
                    remappedMaterials[material.id] = value.id
                    guard !candidates.contains(where: { $0.id == value.id }) else {
                        throw ImportError.invalid(["The copied material ID for \(material.name) conflicts with another incoming material."])
                    }
                    if let priorCopy = merged.material(id: value.id) {
                        guard priorCopy == value else { throw ImportError.invalid(["The saved copy of \(material.name) has a different definition. Keep the existing material or give the edited copy a new ID before importing another copy."]) }
                        action = .keep; detail = "Copy already installed"
                    }
                    else { action = .copy; detail = builtin ? "Built-in material kept; install a custom copy" : "Install a separate material"; merged.customMaterials = (merged.customMaterials ?? []) + [value] }
                    if builtin && policy == .replaceExisting { warnings.append("\(material.name) is built in. A custom copy will be installed instead of changing it.") }
                } else {
                    action = .replace; detail = "Replace material definition"
                    if let i = merged.customMaterials?.firstIndex(where: { $0.id == material.id }) { merged.customMaterials?[i] = material }
                }
            } else {
                action = .add
                merged.customMaterials = (merged.customMaterials ?? []) + [material]
            }
            rows.append(Row(id: "material:\(material.id)", kind: .material, name: material.name, action: action, detail: detail))
        }
        for original in package.stock {
            var stock = original
            if let existing = merged.stock.first(where: { $0.id == stock.id }), policy == .keepExisting {
                let name = (merged.material(id: existing.materialID)?.name ?? existing.material?.name ?? existing.materialID) + " · " + existing.sizeDescription
                rows.append(Row(id: "stock:\(original.id)", kind: .stock, name: name, action: .keep,
                                detail: "Keep your existing stock and quantity", quantity: existing.quantity, dimensions: existing.sizeDescription))
                continue
            }
            stock.materialID = remappedMaterials[stock.materialID] ?? stock.materialID
            guard let material = merged.material(id: stock.materialID) else {
                throw ImportError.invalid(["Stock \(stock.sizeDescription) needs material \(stock.materialID), which is not in this library or your installed materials."])
            }
            stock.materialSnapshot = material
            let existing = merged.stock.firstIndex { $0.id == stock.id }
            var action: Action = .add
            var detail = "New stock"
            if let i = existing {
                if policy == .keepExisting || merged.stock[i] == stock {
                    action = .keep; detail = "Keep your existing stock and quantity"
                } else if policy == .replaceExisting {
                    stock.quantity = merged.stock[i].quantity; stock.location = merged.stock[i].location
                    merged.stock[i] = stock; action = .replace; detail = "Replace stock definition; keep quantity and location"
                } else {
                    stock.id = stableID("stock-copy:" + (try canonicalString(stock)))
                    guard !package.stock.contains(where: { $0.id == stock.id }) else {
                        throw ImportError.invalid(["A copied stock ID conflicts with another incoming stock entry."])
                    }
                    if let priorCopy = merged.stock.first(where: { $0.id == stock.id }) {
                        var definition = priorCopy; definition.quantity = stock.quantity; definition.location = stock.location
                        guard definition == stock else { throw ImportError.invalid(["The saved stock copy has a different definition. Keep the existing stock or give the edited copy a new ID before importing another copy."]) }
                        action = .keep; detail = "Copy already installed"
                    }
                    else { merged.stock.append(stock); action = .copy; detail = "Install separate stock" }
                }
            } else { merged.stock.append(stock) }
            if let path = stock.modelPath, !path.isEmpty { warnings.append("\(stock.sizeDescription): its printed-blank CAD file is referenced, not included in this library.") }
            let installed = merged.stock.first(where: { $0.id == stock.id }) ?? stock
            rows.append(Row(id: "stock:\(original.id)", kind: .stock, name: material.name, action: action, detail: detail,
                            quantity: installed.quantity, dimensions: installed.sizeDescription))
        }
        for original in package.tools {
            var tool = original
            var action: Action = .add
            var detail = "New tool"
            if let i = merged.tools.firstIndex(where: { $0.id == tool.id }) {
                if policy == .keepExisting || merged.tools[i] == tool {
                    action = .keep; detail = "Keep your existing tool and quantity"
                } else if policy == .replaceExisting {
                    tool.quantity = merged.tools[i].quantity; tool.condition = merged.tools[i].condition
                    tool.cuttingMinutes = merged.tools[i].cuttingMinutes; tool.cuttingDistance = merged.tools[i].cuttingDistance
                    merged.tools[i] = tool; action = .replace; detail = "Replace tool definition; keep quantity, condition and usage"
                } else {
                    tool.id = stableID("tool-copy:" + (try canonicalString(tool)))
                    guard !package.tools.contains(where: { $0.id == tool.id }) else {
                        throw ImportError.invalid(["The copied tool ID for \(tool.name) conflicts with another incoming tool."])
                    }
                    if let priorCopy = merged.tools.first(where: { $0.id == tool.id }) {
                        var definition = priorCopy
                        definition.quantity = tool.quantity; definition.condition = tool.condition
                        definition.cuttingMinutes = tool.cuttingMinutes; definition.cuttingDistance = tool.cuttingDistance
                        guard definition == tool else { throw ImportError.invalid(["The saved copy of \(tool.name) has a different definition. Keep the existing tool or give the edited copy a new ID before importing another copy."]) }
                        action = .keep; detail = "Copy already installed"
                    }
                    else { merged.tools.append(tool); action = .copy; detail = "Install a separate tool" }
                }
            } else { merged.tools.append(tool) }
            let installed = merged.tools.first(where: { $0.id == tool.id }) ?? tool
            let dimensions = "⌀\(Length.mm(installed.diameter)) · shank \(Length.mm(installed.shankDiameter)) · flute \(Length.mm(installed.fluteLength)) · stickout \(Length.mm(installed.stickout)) mm"
            rows.append(Row(id: "tool:\(original.id)", kind: .tool, name: installed.name, action: action, detail: detail,
                            quantity: installed.quantity, dimensions: dimensions))
        }
        return Preview(inventory: merged, rows: rows, warnings: Array(Set(warnings)).sorted())
    }

    static func canonicalString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func stableDigest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func stableID(_ value: String) -> UUID {
        let hex = Array(stableDigest(value).prefix(32))
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return UUID(uuidString: ranges.map { String(hex[$0]) }.joined(separator: "-"))!
    }
}
