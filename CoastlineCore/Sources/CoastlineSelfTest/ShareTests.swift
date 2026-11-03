import ZIPFoundation
import CoastlineCore
import Foundation

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-test-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let shareTests: [TestCase] = [
    TestCase(name: "projectTravelsWithItsPart") {
        let src = try scratch("src"), dst = try scratch("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let cad = src.appendingPathComponent("cad")
        try FileManager.default.createDirectory(at: cad, withIntermediateDirectories: true)
        let part = cad.appendingPathComponent("bracket.step")
        try "ISO-10303-21;".write(to: part, atomically: true, encoding: .utf8)
        let project = src.appendingPathComponent("Bracket.coastline")
        try #"{"version":1,"partPath":"\#(part.path)","operations":[],"tuning":{"pace":0.1}}"#.write(to: project, atomically: true, encoding: .utf8)
        let zip = src.appendingPathComponent("Bracket.zip")
        try ProjectShare.exportProject(project, to: zip)

        guard case .project(let opened)? = try ProjectShare.unpack(zip, into: dst) else { throw TestFailure(description: "not a project") }
        try expectEqual(opened.lastPathComponent, "Bracket.coastline")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: opened)) as? [String: Any]
        let path = json?["partPath"] as? String ?? ""
        try expectEqual(path, opened.deletingLastPathComponent().appendingPathComponent("bracket.step").path)
        try expectEqual(try String(contentsOfFile: path, encoding: .utf8), "ISO-10303-21;")
        try expectEqual((json?["tuning"] as? [String: Any])?["pace"] as? Double, 0.1)
    },

    TestCase(name: "jobFolderTravelsAsIs") {
        let src = try scratch("job"), dst = try scratch("jobdst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let folder = src.appendingPathComponent("my-job")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("programs"), withIntermediateDirectories: true)
        try #"{"id":"my-job"}"#.write(to: folder.appendingPathComponent("job.json"), atomically: true, encoding: .utf8)
        try "G0 X0".write(to: folder.appendingPathComponent("programs/a.nc"), atomically: true, encoding: .utf8)
        let zip = src.appendingPathComponent("my-job.zip")
        try ProjectShare.exportJob(folder, to: zip)
        guard case .job(let job)? = try ProjectShare.unpack(zip, into: dst) else { throw TestFailure(description: "not a job") }
        try expectEqual(try String(contentsOf: job.appendingPathComponent("programs/a.nc"), encoding: .utf8), "G0 X0")
        try expectThrows { try ProjectShare.exportJob(src, to: src.appendingPathComponent("x.zip")) }
    },

    TestCase(name: "otherZipsAreNotProjects") {
        let src = try scratch("other"), dst = try scratch("otherdst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let folder = src.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let zip = src.appendingPathComponent("photos.zip")
        try FileManager.default.zipItem(at: folder, to: zip)
        try expect(try ProjectShare.unpack(zip, into: dst) == nil)
    },
]
