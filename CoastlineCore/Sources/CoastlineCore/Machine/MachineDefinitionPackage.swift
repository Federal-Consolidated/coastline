import Foundation
import CryptoKit

/// A validated, local, self-contained profile package. Importing it never executes a post,
/// controller command or Fusion script, and never changes the active machine.
public struct MachineDefinitionPackage: Sendable {
    public let definition: MachineDefinition
    public let rootURL: URL
    public var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    public var geometryURL: URL {
        // A loaded package has exactly one geometry asset, enforced before construction.
        rootURL.appendingPathComponent(definition.assets.first { $0.role == .geometry }!.path)
    }
    public var fusionDefinitionURL: URL? {
        definition.assets.first { $0.role == .fusionDefinition }.map { rootURL.appendingPathComponent($0.path) }
    }

    public static let maximumManifestBytes: Int64 = 1_048_576
    public static let maximumAssetBytes: Int64 = 209_715_200
    public static let maximumPackageBytes: Int64 = 524_288_000

    public static func load(from url: URL) throws -> MachineDefinitionPackage {
        guard url.isFileURL else { throw MachineDefinitionError("Select a local machine package folder or manifest.json.") }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MachineDefinitionError("Machine package was not found at '\(url.lastPathComponent)'.")
        }
        if !isDirectory.boolValue && url.lastPathComponent != "manifest.json" {
            throw MachineDefinitionError("Select a machine package folder or its manifest.json. A Fusion .mch alone needs model and calibration data.")
        }
        let root = (isDirectory.boolValue ? url : url.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try checkedFile("manifest.json", in: root, maximumBytes: maximumManifestBytes)
        let handle = try FileHandle(forReadingFrom: manifest)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(maximumManifestBytes) + 1) ?? Data()
        guard data.count <= maximumManifestBytes else { throw MachineDefinitionError("Machine manifest is too large.") }
        // Check the envelope before decoding enums, so future profiles get a useful version message.
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = envelope["schemaVersion"] as? Int else {
            throw MachineDefinitionError("Machine manifest must be an object with schemaVersion.")
        }
        guard version == 1 else { throw MachineDefinitionError("Unsupported machine profile schema \(version); expected 1.") }
        let definition: MachineDefinition
        do { definition = try JSONDecoder().decode(MachineDefinition.self, from: data) }
        catch { throw MachineDefinitionError("Invalid machine manifest: \(error.localizedDescription)") }
        try definition.validate()
        var totalBytes = Int64(data.count)
        for asset in definition.assets {
            guard asset.path != "manifest.json" else { throw MachineDefinitionError("The manifest cannot also be an asset.") }
            let file = try checkedFile(asset.path, in: root, maximumBytes: maximumAssetBytes)
            let attributes = try fm.attributesOfItem(atPath: file.path)
            totalBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard totalBytes <= maximumPackageBytes else { throw MachineDefinitionError("Machine package exceeds 500 MiB.") }
            let hash = try fingerprint(of: file)
            guard hash == asset.sha256.lowercased() else {
                throw MachineDefinitionError("Asset '\(asset.path)' does not match its SHA-256 fingerprint. Re-export the package after changing its assets.")
            }
        }
        return MachineDefinitionPackage(definition: definition, rootURL: root)
    }

    /// Copies declared assets only. An installed ID/revision cannot be overwritten with different data.
    public static func install(from sourceURL: URL, into libraryURL: URL) throws -> MachineDefinitionPackage {
        guard libraryURL.isFileURL else { throw MachineDefinitionError("Machine library must be a local directory.") }
        let source = try load(from: sourceURL), fm = FileManager.default
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let library = libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = library.appendingPathComponent("\(source.definition.id)-r\(source.definition.revision)", isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            guard try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw MachineDefinitionError("Installed machine location is a symbolic link; choose a regular machine library directory.")
            }
            let installed = try load(from: destination)
            guard installed.definition == source.definition else {
                throw MachineDefinitionError("\(source.definition.name) revision \(source.definition.revision) is already installed with different data. Give the changed profile a new revision.")
            }
            return installed
        }
        let staging = library.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for path in ["manifest.json"] + source.definition.assets.map(\.path) {
            let original = try checkedFile(path, in: source.rootURL,
                                           maximumBytes: path == "manifest.json" ? maximumManifestBytes : maximumAssetBytes)
            let copy = staging.appendingPathComponent(path)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: original, to: copy)
        }
        _ = try load(from: staging) // catches source changes between inspection and copying
        try fm.moveItem(at: staging, to: destination)
        return try load(from: destination)
    }

    private static func checkedFile(_ relativePath: String, in root: URL, maximumBytes: Int64) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.contains(":"), !relativePath.unicodeScalars.contains(where: { $0.value < 32 }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MachineDefinitionError("Unsafe package path '\(relativePath)'. Use package-relative file paths without '..'.")
        }
        let fm = FileManager.default
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: current.path) }
            catch { throw MachineDefinitionError("Package file '\(relativePath)' is missing or unreadable.") }
            let type = attributes[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else {
                throw MachineDefinitionError("Package path '\(relativePath)' contains a symbolic link; include the actual asset.")
            }
            if index < components.count - 1 {
                guard type == .typeDirectory else { throw MachineDefinitionError("Package path '\(relativePath)' contains a non-directory.") }
            } else {
                guard type == .typeRegular else { throw MachineDefinitionError("Package asset '\(relativePath)' must be a regular file.") }
                guard let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0, bytes <= maximumBytes else {
                    throw MachineDefinitionError("Package asset '\(relativePath)' is empty or exceeds its size limit.")
                }
            }
        }
        guard current.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw MachineDefinitionError("Package asset escapes its folder.") }
        return current
    }

    private static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            count += Int64(data.count)
            guard count <= maximumAssetBytes else { throw MachineDefinitionError("Machine asset grew beyond its size limit while importing.") }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
