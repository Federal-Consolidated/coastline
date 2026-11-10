import AppKit
import CoastlineCore
import Foundation
import Observation

/// Profile browsing is separate from the job assignment. "Use for Job" selects the
/// immutable planning snapshot; browsing never changes a physical controller.
@MainActor @Observable
final class MachineProfileLibrary {
    private(set) var packages: [MachineDefinitionPackage] = []
    private(set) var loading = false
    private(set) var libraryIssues: [String] = []
    private(set) var reloadRevision = 0
    var selectedKey: String? {
        didSet { if let selectedKey { UserDefaults.standard.set(selectedKey, forKey: "reviewMachineProfile") } }
    }
    var error: String?
    var message: String?

    var selected: MachineDefinitionPackage? { packages.first { Self.key($0) == selectedKey } }
    nonisolated static func key(_ package: MachineDefinitionPackage) -> String {
        "\(package.definition.id)@\(package.definition.revision)"
    }

    init() {
        selectedKey = UserDefaults.standard.string(forKey: "reviewMachineProfile")
    }

    static var libraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coastline/Machine Profiles", isDirectory: true)
    }

    func reload(select preferred: String? = nil) async {
        if loading {
            // Callers resolving a saved job must join an existing refresh, not read a
            // temporarily empty library and conclude its package is missing.
            while loading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(25)) }
            return
        }
        loading = true
        defer { loading = false }
        let bundled = AppModel.repoRoot.appendingPathComponent("resources/machines", isDirectory: true)
        let installed = Self.libraryURL
        let result = await Task.detached(priority: .userInitiated) {
            var found: [MachineDefinitionPackage] = [], issues: [String] = []
            for folder in [bundled, installed] {
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                do {
                    let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                        do {
                            let package = try MachineDefinitionPackage.load(from: url)
                            if let existing = found.first(where: { Self.key($0) == Self.key(package) }) {
                                if existing.definition != package.definition {
                                    issues.append("\(package.definition.name) revision \(package.definition.revision) conflicts with a bundled profile. Export it with a new revision.")
                                }
                            } else { found.append(package) }
                        } catch { issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                } catch { issues.append("Couldn't read \(folder.lastPathComponent): \(error.localizedDescription)") }
            }
            return (found, issues)
        }.value
        packages = result.0
        libraryIssues = result.1
        let desired = preferred ?? selectedKey
        selectedKey = packages.contains(where: { Self.key($0) == desired }) ? desired : packages.first.map(Self.key)
        reloadRevision += 1
    }

    func importInteractively() {
        let panel = NSOpenPanel()
        panel.title = "Import Machine Profile"
        panel.message = "Choose a Coastline machine profile folder containing manifest.json and its model assets."
        panel.prompt = "Import Profile"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.install(url) }
        }
    }

    func install(_ url: URL) async {
        guard !loading else { return }
        loading = true
        error = nil
        message = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let destination = Self.libraryURL
            let available = packages.map(\.definition)
            let package = try await Task.detached(priority: .userInitiated) {
                let incoming = try MachineDefinitionPackage.load(from: url)
                if let existing = available.first(where: { $0.reference == incoming.definition.reference }),
                   existing != incoming.definition {
                    throw MachineDefinitionError("\(existing.name) revision \(existing.revision) already exists with different data. Export the changed profile with a new revision.")
                }
                return try MachineDefinitionPackage.install(from: url, into: destination)
            }.value
            loading = false
            await reload(select: Self.key(package))
            message = "Imported \(package.definition.name) for digital review."
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }
}
