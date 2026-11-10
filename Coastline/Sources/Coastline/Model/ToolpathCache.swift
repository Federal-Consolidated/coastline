import CoastlineCore
import CryptoKit
import Foundation

/// Toolpaths from earlier runs, kept on disk (Application Support/Coastline/ToolpathCache). The
/// same request to the engine gives the same result, so a job generated again after a change
/// elsewhere (the app, the workholding, a restart) comes back in seconds instead of minutes.
/// The key holds everything the result depends on: the part file's contents, the operation with
/// its tool, feeds and windows, the setup's transform and stock, the tabs, the machine, and the
/// engine's own code. `COASTLINE_NO_CACHE=1` turns it off (for timing the engine itself).
enum ToolpathDiskCache {
    static let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Coastline/ToolpathCache")
    static var enabled: Bool { ProcessInfo.processInfo.environment["COASTLINE_NO_CACHE"] == nil }
    /// Bump when the stored form changes.
    static let version = 1
    /// Stands in for an operation's id in the key: the id is new each time a plan is chosen.
    static let sameID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// How much the cache may hold before the oldest entries go, bytes.
    static let limit = 1_500_000_000

    struct Entry: Codable {
        var version: Int
        var paths: [SavedResults.Path]
        var tabs: [PlacedTab]
    }

    static func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".toolpaths")
    }

    static func has(_ key: String) -> Bool {
        enabled && FileManager.default.fileExists(atPath: url(for: key).path)
    }

    static func load(_ key: String) -> ([OperationToolpath], [PlacedTab])? {
        guard enabled else { return nil }
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode(Entry.self, from: data), e.version == version else { return nil }
        // Read: the entry is recent again (the oldest go first when the cache is full).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return (e.paths.map(\.toolpath), e.tabs)
    }

    static func store(_ key: String, _ value: ([OperationToolpath], [PlacedTab])) {
        guard enabled else { return }
        let e = Entry(version: version, paths: value.0.map(SavedResults.Path.init), tabs: value.1)
        guard let data = try? JSONEncoder().encode(e) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
        prune()
    }

    /// Keeps the cache under its limit: the entries not read for longest go first.
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(URL, Int, Date)] = files.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (u, size, _) in entries where total > limit * 8 / 10 {
            try? fm.removeItem(at: u)
            total -= size
        }
    }

    /// A fingerprint of the engine's code: a change to any of its files makes every entry stale.
    @MainActor static let engineFingerprint: String = {
        let engine = AppModel.repoRoot.appendingPathComponent("engine/coastline_engine")
        var parts: [String] = []
        if let files = FileManager.default.enumerator(at: engine, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let u as URL in files where ["py", "so", "cpp", "hpp"].contains(u.pathExtension) && !u.path.contains("__pycache__") {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                parts.append("\(u.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        parts.sort()
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    nonisolated(unsafe) private static var fileFingerprints: [String: String] = [:]
    private static let lock = NSLock()

    /// A fingerprint of a part file's contents (hashed once per file and modification date).
    static func fileFingerprint(_ url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let k = "\(url.path)|\(mtime)"
        lock.lock(); let hit = fileFingerprints[k]; lock.unlock()
        if let hit { return hit }
        let digest = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? url.path
        lock.lock(); fileFingerprints[k] = digest; lock.unlock()
        return digest
    }
}
