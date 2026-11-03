import Foundation
import ZIPFoundation

/// Sharing a project as one `.zip`: a planned project (its `.coastline` file with the part file
/// beside it) or a G-code job (its folder: job.json, programs, models). Importing a shared zip
/// finds which it is.
public enum ProjectShare {
    public enum Content: Equatable, Sendable {
        /// A `.coastline` project; its part file is beside it and its part path points there.
        case project(URL)
        /// A job folder (it holds job.json).
        case job(URL)
    }

    public enum ShareError: Error, CustomStringConvertible {
        case notAProject(String)
        case missingPart(String)

        public var description: String {
            switch self {
            case .notAProject(let name): "\(name) is not a Coastline project."
            case .missingPart(let path): "The project's part file isn't there any more: \(path)"
            }
        }
    }

    /// A planned project: the `.coastline` file and its part, in a folder named after the
    /// project. The part path becomes the bare file name (Coastline looks beside the project).
    public static func exportProject(_ project: URL, to zip: URL) throws {
        let data = try Data(contentsOf: project)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShareError.notAProject(project.lastPathComponent)
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("coastline-share-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(project.deletingPathExtension().lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let path = json["partPath"] as? String {
            let part = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: part.path) else { throw ShareError.missingPart(path) }
            try fm.copyItem(at: part, to: folder.appendingPathComponent(part.lastPathComponent))
            json["partPath"] = part.lastPathComponent
        }
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: folder.appendingPathComponent(project.lastPathComponent))
        try? fm.removeItem(at: zip)
        try fm.zipItem(at: folder, to: zip, shouldKeepParent: true)
    }

    /// A G-code job: its folder as it is.
    public static func exportJob(_ folder: URL, to zip: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("job.json").path) else {
            throw ShareError.notAProject(folder.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.zipItem(at: folder, to: zip, shouldKeepParent: true)
    }

    /// Unpacks a zip into `folder` (made new) and says what it holds: a job folder or a project
    /// (its part path set to the part beside it). Nil: neither (an old `.dd` package, say).
    public static func unpack(_ zip: URL, into folder: URL) throws -> Content? {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: folder)
        // The content sits at the top or one folder down (zipped with its parent folder).
        var places = [folder]
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        places += top.filter { $0.lastPathComponent != "__MACOSX" && $0.hasDirectoryPath }
        for place in places where fm.fileExists(atPath: place.appendingPathComponent("job.json").path) {
            return .job(place)
        }
        for place in places {
            let files = (try? fm.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? []
            guard let project = files.first(where: { $0.pathExtension == "coastline" }) else { continue }
            try pointPartBeside(project)
            return .project(project)
        }
        return nil
    }

    /// Sets the project's part path to the part file next to it, if it is there.
    public static func pointPartBeside(_ project: URL) throws {
        let data = try Data(contentsOf: project)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["partPath"] as? String else { return }
        let beside = project.deletingLastPathComponent().appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        guard FileManager.default.fileExists(atPath: beside.path) else { return }
        json["partPath"] = beside.path
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: project)
    }
}
