import AppKit
import CoastlineCore
import Foundation
import UniformTypeIdentifiers

/// One Import and one Export for every kind of project. A planned project is a `.coastline`
/// file (and its part); a G-code project is a job folder (job.json, programs, models). Shared,
/// either is one `.zip` (ProjectShare).
extension AppModel {
    /// Imported planned projects: Application Support/Coastline/Projects/<name>/ (the
    /// `.coastline` file with its part beside it). G-code projects go to JobsModel.userFolder.
    static var projectsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coastline/Projects")
    }

    static let gcodeExtensions = ["nc", "gcode", "ngc", "tap", "cnc"]

    func importProjectsInteractively() {
        let panel = NSOpenPanel()
        panel.title = "Import a Project"
        panel.message = "A Coastline project (.coastline or a shared .zip), an older .dd or .crproj job, a job folder, or G-code files."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ([.coastlineProject, .zip, .folder]
            + (["dd", "crproj"] + Self.gcodeExtensions).compactMap { UTType(filenameExtension: $0) })
        guard panel.runModal() == .OK else { return }
        importProjects(panel.urls)
    }

    /// Sorts what was chosen (or dropped) by kind. G-code files open the New Project from
    /// G-code sheet, which asks for the tool and the work offset.
    func importProjects(_ urls: [URL]) {
        let gcode = urls.filter { Self.gcodeExtensions.contains($0.pathExtension.lowercased()) }
        for url in urls where !gcode.contains(url) {
            switch url.pathExtension.lowercased() {
            case "coastline":
                page = .projects
                projectsPick = "project:" + url.path
                Self.addRecent(url)
            case "zip": importZip(url)
            case "dd", "crproj":
                jobs.importDD(url)
                pickSelectedJob()
            default:
                if url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.appendingPathComponent("job.json").path) {
                    jobs.addJobFolder(url)
                    pickSelectedJob()
                } else {
                    jobs.lastError = "\(url.lastPathComponent) is not a project Coastline can import."
                }
            }
        }
        if !gcode.isEmpty {
            page = .projects
            jobs.pendingGCode = gcode.sorted { $0.lastPathComponent < $1.lastPathComponent }
            jobs.showNewJob = true
        }
    }

    /// A shared project or job, or an older package zipped.
    private func importZip(_ url: URL) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("coastline-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        do {
            switch try ProjectShare.unpack(url, into: staging) {
            case .job(let folder)?:
                jobs.addJobFolder(folder)
                pickSelectedJob()
            case .project(let file)?:
                // Its own folder (the part beside it), named after the project, never over another.
                let name = file.deletingPathExtension().lastPathComponent
                try fm.createDirectory(at: Self.projectsFolder, withIntermediateDirectories: true)
                var dest = Self.projectsFolder.appendingPathComponent(name)
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    dest = Self.projectsFolder.appendingPathComponent("\(name) \(n)")
                    n += 1
                }
                try fm.moveItem(at: file.deletingLastPathComponent(), to: dest)
                let project = dest.appendingPathComponent(file.lastPathComponent)
                try ProjectShare.pointPartBeside(project)  // it moved with its folder
                Self.addRecent(project)
                page = .projects
                projectsPick = "project:" + project.path
            case nil:
                jobs.importDD(url)  // an older .dd package sent as a zip
                pickSelectedJob()
            }
        } catch {
            jobs.lastError = "Couldn't import \(url.lastPathComponent): \(error)"
        }
    }

    private func pickSelectedJob() {
        page = .projects
        if let folder = jobs.selection { projectsPick = "job:" + folder.path }
    }

    // MARK: Export

    /// A planned project as one zip to share: the `.coastline` file and its part.
    func exportProjectInteractively(_ project: URL) {
        guard let zip = askForZip(project.deletingPathExtension().lastPathComponent) else { return }
        do {
            try ProjectShare.exportProject(project, to: zip)
            status = "Exported \(zip.lastPathComponent)"
        } catch {
            errorMessage = "Couldn't export: \(error)"
        }
    }

    /// A G-code project (job folder) as one zip to share.
    func exportJobInteractively(_ entry: JobsModel.Entry) {
        guard let zip = askForZip(entry.job.title) else { return }
        do {
            try ProjectShare.exportJob(entry.folder, to: zip)
            status = "Exported \(zip.lastPathComponent)"
        } catch {
            jobs.lastError = "Couldn't export: \(error)"
        }
    }

    /// File ▸ Export Project…: the open project, saved first so the zip has what is on screen.
    func exportOpenProject() {
        if projectURL == nil || projectDirty { saveProjectInteractively() }
        guard let url = projectURL, !projectDirty else { return }
        exportProjectInteractively(url)
    }

    private func askForZip(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Project"
        panel.message = "One .zip file to share. Import it in Coastline on another Mac."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = name + ".zip"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
