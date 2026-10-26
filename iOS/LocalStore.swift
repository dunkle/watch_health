import Foundation
import WatchMindCore

struct Archive: Codable {
    var version = 1
    var episodes: [Episode] = []
    var reports: [DailyReport] = []
}

final class LocalStore {
    let directory: URL
    let file: URL
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("WatchMind", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(resource)
        file = directory.appendingPathComponent("archive.json")
    }
    func load() throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else { return Archive() }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }
    func save(_ archive: Archive) throws {
        try JSONEncoder().encode(archive).write(to: file, options: [.atomic, .completeFileProtection])
    }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".m4a") }
    func deleteAudio(_ name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".m4a") else { return }
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
