import Foundation
import ZIPFoundation

/// Imports Autodesk Fusion tool libraries (`.tools`, a zip containing `tools.json`; or a bare
/// `.json`). The machine ships its aluminium and steel/titanium libraries in this format.
public enum ToolLibraryImport {
    public struct Result: Sendable {
        public var tools: [Tool]
        /// Entries that were skipped, with the reason (e.g. holders, probes, unknown types).
        public var skipped: [String]
        /// Defaults inferred from incomplete Fusion geometry, for review before installation.
        public var warnings: [String] = []
    }

    public enum ImportError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case .unreadable(let why): "Couldn't read the tool library: \(why)" }
        }
    }

    public static func load(_ url: URL) throws -> Result {
        let json: Data
        if url.pathExtension.lowercased() == "json" {
            json = try Data(contentsOf: url)
        } else {
            let archive: Archive
            do { archive = try Archive(url: url, accessMode: .read) } catch {
                throw ImportError.unreadable("not a zip archive (\(error))")
            }
            guard let entry = archive.first(where: { $0.path.lowercased().hasSuffix("tools.json") }) else {
                throw ImportError.unreadable("no tools.json inside")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            json = data
        }
        return try parse(json, sourceName: url.lastPathComponent)
    }

    public static func parse(_ json: Data, sourceName: String) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw ImportError.unreadable("unexpected JSON layout")
        }
        var tools: [Tool] = []
        var skipped: [String] = []
        var warnings: [String] = []
        var convertedInches = false
        for e in entries {
            let typeName = e["type"] as? String ?? "?"
            let description = (e["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let kind = kind(for: typeName) else {
                skipped.append("\(typeName) \(description): not a cutting tool Coastline uses")
                continue
            }
            let g = e["geometry"] as? [String: Any] ?? [:]
            // Fusion stores lengths in the library's unit ("inches" or "millimeters").
            let unit = (e["unit"] as? String ?? "").lowercased()
            let scale: Double
            switch unit {
            case "inches", "inch", "in": scale = 25.4
            case "millimeters", "millimetres", "millimeter", "millimetre", "mm": scale = 1
            default:
                skipped.append("\(typeName) \(description): missing or unsupported units \(unit)")
                continue
            }
            func len(_ key: String) -> Double? { (g[key] as? Double).map { $0 * scale } }
            guard let diameter = len("DC"), diameter.isFinite, diameter > 0 else {
                skipped.append("\(typeName) \(description): no diameter")
                continue
            }
            let vendor = (e["vendor"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let product = (e["product-id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let number = (e["post-process"] as? [String: Any])?["number"] as? Int
            let fluteLength = len("LCF") ?? diameter * 2
            let stickout = len("LB") ?? len("assemblyGaugeLength") ?? fluteLength + 5
            let rawFlutes = (g["NOF"] as? NSNumber)?.doubleValue
            guard rawFlutes == nil || (rawFlutes!.isFinite && rawFlutes! > 0 && rawFlutes! <= Double(Int32.max) && rawFlutes!.rounded() == rawFlutes!) else {
                skipped.append("\(typeName) \(description): invalid flute count")
                continue
            }

            var tool = Tool(
                name: displayName(vendor: vendor, product: product, description: description, kind: kind, diameter: diameter),
                kind: kind,
                vendor: vendor,
                partNumber: product,
                productLink: e["product-link"] as? String ?? "",
                diameter: diameter,
                shankDiameter: len("SFDM") ?? diameter,
                flutes: rawFlutes.map(Int.init) ?? 2,
                fluteLength: fluteLength,
                stickout: stickout,
                overallLength: len("OAL") ?? stickout + 20,
                cornerRadius: len("RE") ?? 0,
                angle: (g["TA"] as? Double) ?? (g["SIG"] as? Double),
                tipDiameter: len("tip-diameter") ?? 0,
                toolMaterial: toolMaterial(e["BMC"] as? String),
                // Fusion's body material "ti coated" means TiN-coated carbide.
                coating: (e["BMC"] as? String)?.lowercased() == "ti coated" ? .tiN : coating(in: description),
                intendedFor: description,
                source: "Fusion library \(sourceName)" + (number.map { ", T\($0)" } ?? "")
            )
            tool.presets = presets(e, scale: scale)
            // Fusion GUIDs are stable across exports, filenames and cutting-data edits.
            // For vendors without a GUID, normalized geometry gives repeatable identities.
            if let guid = e["guid"] as? String, !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normalized = guid.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).lowercased()
                tool.id = UUID(uuidString: normalized) ?? ResourceLibraryImport.stableID("fusion-guid:" + normalized)
            } else {
                var identity = tool
                identity.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                identity.source = ""; identity.presets = []; identity.productLink = ""
                // The generated display name already includes the vendor and part number.
                // Keep the description only for uncatalogued tools of otherwise identical geometry.
                identity.intendedFor = product.isEmpty ? description : ""
                tool.id = ResourceLibraryImport.stableID("fusion-tool:" + (try ResourceLibraryImport.canonicalString(identity)))
            }
            let problems = ResourceLibraryValidation.issues(for: tool)
            guard problems.isEmpty else {
                skipped.append("\(tool.name): " + problems.joined(separator: " "))
                continue
            }
            var inferred: [String] = []
            if len("SFDM") == nil { inferred.append("shank diameter") }
            if len("LCF") == nil { inferred.append("flute length") }
            if len("LB") == nil && len("assemblyGaugeLength") == nil { inferred.append("stickout") }
            if len("OAL") == nil { inferred.append("overall length") }
            if rawFlutes == nil { inferred.append("flute count") }
            if !inferred.isEmpty { warnings.append("\(tool.name): inferred \(inferred.joined(separator: ", ")); check these dimensions before cutting.") }
            if tools.contains(where: { $0.id == tool.id }) {
                skipped.append("\(tool.name): repeated tool identity in this Fusion library")
                continue
            }
            tools.append(tool)
            if scale == 25.4 { convertedInches = true }
        }
        if convertedInches { warnings.append("Converted Fusion inch tool dimensions and feeds to millimetres and mm/min.") }
        return Result(tools: tools, skipped: skipped, warnings: warnings)
    }

    static func kind(for fusionType: String) -> Tool.Kind? {
        switch fusionType.lowercased() {
        case "flat end mill": .flatEndMill
        case "ball end mill": .ballEndMill
        case "bull nose end mill", "radius mill": .bullNoseEndMill
        case "chamfer mill", "dovetail mill": .chamferMill
        case "engrave", "engrave mill", "tapered mill": .engraver
        case "drill": .drill
        case "spot drill", "center drill": .spotDrill
        case "thread mill": .threadMill
        case "face mill": .faceMill
        default: nil
        }
    }

    static func toolMaterial(_ bmc: String?) -> Tool.ToolMaterial {
        switch bmc?.lowercased() {
        case "hss": .hss
        case "cobalt": .cobalt
        default: .carbide
        }
    }

    /// Fusion has no coating field, but vendors often name it in the description.
    static func coating(in description: String) -> Tool.Coating {
        // Whole words only: "cutting" contains "tin".
        let words = Set(description.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let table: [(String, Tool.Coating)] = [("altin", .alTiN), ("tialn", .tiAlN), ("alcrn", .alCrN),
                                               ("zrn", .zrN), ("dlc", .dlc), ("tin", .tiN)]
        return table.first { words.contains($0.0) }?.1 ?? .none
    }

    static func displayName(vendor: String, product: String, description: String, kind: Tool.Kind, diameter: Double) -> String {
        // Avoid an integer conversion overflow in inch-fraction formatting for malformed huge values.
        let fraction = diameter < Double(Int.max) / 64 ? Length.inchFraction(diameter) : nil
        let size = fraction ?? "\(Length.mm(diameter)) mm"
        let what = "\(size) \(kind.title.lowercased())"
        let maker = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        return maker.isEmpty ? what : "\(what) · \(maker)"
    }

    static func presets(_ e: [String: Any], scale: Double) -> [Tool.Preset] {
        let list = (e["start-values"] as? [String: Any])?["presets"] as? [[String: Any]] ?? []
        return list.compactMap { p in
            guard let n = p["n"] as? Double else { return nil }
            func feed(_ key: String) -> Double { ((p[key] as? Double) ?? 0) * scale }  // in/min → mm/min
            return Tool.Preset(
                name: p["name"] as? String ?? "Preset",
                rpm: n,
                feed: feed("v_f"),
                plungeFeed: feed("v_f_plunge"),
                rampFeed: feed("v_f_ramp"),
                stepdown: (p["use-stepdown"] as? Bool ?? false) ? (p["stepdown"] as? Double).map { $0 * scale } : nil,
                stepover: (p["use-stepover"] as? Bool ?? false) ? (p["stepover"] as? Double).map { $0 * scale } : nil
            )
        }
    }
}
