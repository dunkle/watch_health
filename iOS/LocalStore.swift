import Foundation
import WatchMindCore

typealias Archive = JournalArchive

final class LocalStore {
    let directory: URL
    let file: URL
    private let archiveStore: ArchiveFileStore
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("WatchMind", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(resource)
        archiveStore = try ArchiveFileStore(directory: directory)
        file = archiveStore.file
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("chunk-") && url.pathExtension == "m4a" {
            try FileManager.default.removeItem(at: url)
        }
    }
    func load() throws -> Archive { try archiveStore.load() }
    func save(_ archive: Archive) throws { try archiveStore.save(archive) }
    func metadataByteCount() throws -> Int64 { try archiveStore.metadataByteCount() }
    func availableCapacity() throws -> Int64? {
        try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".m4a") }
    func deleteAudio(_ name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".m4a") else { return }
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
