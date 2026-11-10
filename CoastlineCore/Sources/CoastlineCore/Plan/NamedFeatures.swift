import Foundation

/// What a group of the part's faces is, with its sizes ("Slot 16.89 x 31 mm"), from quiddity
/// through the engine's "recognise" call. Names for DFM findings only: the check itself still
/// decides what is wrong. Face numbers are the part's own, the same as `PartAccess`'s.
public struct NamedFeature: Sendable, Equatable, Codable {
    public var family: String
    public var label: String
    public var faces: [Int]

    public init(family: String, label: String, faces: [Int]) {
        (self.family, self.label, self.faces) = (family, label, faces)
    }

    /// The name for a set of faces: a feature with at least half its faces among them that is
    /// also at least a third of them (a small pocket doesn't name a whole side), the largest
    /// share first, then the one sharing the most; nil when none does.
    public static func name(for faces: [Int], in features: [NamedFeature]) -> String? {
        let set = Set(faces)
        guard !set.isEmpty else { return nil }
        var best: (share: Double, count: Int, label: String)?
        for f in features where !f.faces.isEmpty {
            let n = f.faces.filter(set.contains).count
            let share = Double(n) / Double(f.faces.count)
            guard n > 0, share >= 0.5, 3 * n >= set.count else { continue }
            if best == nil || (share, n) > (best!.share, best!.count) { best = (share, n, f.label) }
        }
        return best?.label
    }
}

extension EngineClient {
    /// Named features of a STEP file (by path; the engine doesn't need it imported). nil when
    /// recognition isn't available or the file can't be read: findings keep their own titles.
    /// Slow on busy parts (tens of seconds): call it on an engine of its own.
    public func recognise(path: URL) throws -> [NamedFeature]? {
        let r = try call("recognise", ["path": path.path])
        guard r.result["available"] as? Bool == true else { return nil }
        return (r.result["features"] as? [[String: Any]] ?? []).compactMap { f in
            guard let family = f["family"] as? String, let label = f["label"] as? String else { return nil }
            let faces = (f["faces"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            return faces.isEmpty ? nil : NamedFeature(family: family, label: label, faces: faces)
        }
    }
}
