import XCTest
@testable import WatchMindCore

final class ArchiveFileStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watchmind-store-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func episode(_ text: String = "A real source snapshot", offset: Double = 0) -> Episode {
        var episode = Episode(trigger: .init(date: Date(timeIntervalSince1970: 1_800_000_000 + offset), bpm: 90, baseline: 70), status: .ready)
        episode.transcript = text; episode.segments = [.init(text: text, offset: 0, duration: 5)]
        episode.audioName = episode.id.uuidString + ".m4a"
        return episode
    }
    private func blobs() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("archive-blobs").path))
    }
    private func manifest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("archive.json"))) as? [String: Any])
    }

    func testLegacyMigrationIsDeferredUntilSaveAndRoundTripsAllCollections() throws {
        let item = episode()
        var archive = JournalArchive(episodes: [item], heartPoints: [.init(sample: .init(date: item.trigger.date, bpm: 90))], pendingAudioDeletions: ["old.m4a"])
        archive.markers = [.init(date: item.trigger.date, recordingID: item.id, note: "quoted")]
        archive.journal.people = [.init(name: "Friend", isDemo: false)]
        archive.metrics = [.init(kind: .hrv, value: 40, date: item.trigger.date, source: "Watch")]
        let legacy = try JSONEncoder().encode(archive)
        try legacy.write(to: directory.appendingPathComponent("archive.json"))
        let store = try ArchiveFileStore(directory: directory)
        let loaded = try store.load()
        XCTAssertEqual(try Data(contentsOf: store.file), legacy, "Loading never changes the legacy file")
        try store.save(loaded)
        XCTAssertEqual(try manifest()["format"] as? String, "watchmind-sharded-json")
        let restored = try ArchiveFileStore(directory: directory).load()
        XCTAssertEqual(restored.episodes.first?.transcript, item.transcript)
        XCTAssertEqual(restored.markers.first?.note, "quoted")
        XCTAssertEqual(restored.journal.people.first?.name, "Friend")
        XCTAssertEqual(restored.metrics.first?.value, 40)
        XCTAssertEqual(restored.pendingAudioDeletions, ["old.m4a"])
    }

    func testUnchangedSaveAndMarkerEditReuseLargeImmutableRecords() throws {
        var item = episode(String(repeating: "word ", count: 7200))
        item.segments = (0..<7200).map { .init(text: "word", offset: Double($0) / 2, duration: 0.4) }
        var archive = JournalArchive(episodes: [item], heartPoints: (0..<9000).map { .init(sample: .init(date: item.trigger.date.addingTimeInterval(Double($0)), bpm: 80)) })
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(archive)
        let before = try blobs()
        try store.save(archive)
        XCTAssertEqual(store.lastStatistics.newBlobCount, 0)
        XCTAssertEqual(try blobs(), before)
        archive.markers.append(.init(date: item.trigger.date, recordingID: item.id, note: "new mark"))
        try store.save(archive)
        XCTAssertEqual(store.lastStatistics.newBlobCount, 1, "Only the small marker component changes")
        XCTAssertLessThan(store.lastStatistics.newBlobBytes, 1024)
        let next = try blobs()
        XCTAssertEqual(before.intersection(next).count, before.count - 1)
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().episodes.first?.segments.count, 7200)
    }

    func testEpisodeMutationRewritesOnlyChangedRecordAndRemovesDeletedContent() throws {
        let first = episode("private first"), second = episode("private second", offset: 5)
        var archive = JournalArchive(episodes: [first, second])
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(archive)
        let initial = try manifest()["episodes"] as! [String]
        archive.episodes[1].transcript = "changed second"; try store.save(archive)
        let updated = try manifest()["episodes"] as! [String]
        XCTAssertEqual(initial[0], updated[0]); XCTAssertNotEqual(initial[1], updated[1])
        XCTAssertFalse(try blobs().contains(initial[1]))
        archive.episodes.removeFirst(); try store.save(archive)
        XCTAssertFalse(try blobs().contains(initial[0]))
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().episodes.first?.transcript, "changed second")
    }

    func testFailureBeforeManifestKeepsOldArchiveAndNextSavePrunesOrphans() throws {
        let item = episode("old"), archive = JournalArchive(episodes: [item])
        var fail = false
        let store = try ArchiveFileStore(directory: directory) { point in
            if fail && point == .beforeManifestCommit { throw CocoaError(.fileWriteOutOfSpace) }
        }
        _ = try store.load(); try store.save(archive)
        var changed = archive; changed.episodes[0].transcript = "not yet committed"
        fail = true; XCTAssertThrowsError(try store.save(changed))
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().episodes.first?.transcript, "old")
        fail = false; try store.save(changed)
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().episodes.first?.transcript, "not yet committed")
        let references = try manifest()
        let expected = Set((references["episodes"] as! [String]) + (references["heartChunks"] as! [String]) + (references["reviews"] as! [String]) + Array((references["components"] as! [String: String]).values))
        XCTAssertEqual(try blobs(), expected)
    }

    func testInterruptedInitialMigrationReclaimsOrphansBeforeAllocatingAgain() throws {
        let archive = JournalArchive(episodes: [episode("legacy private text")])
        let legacy = try JSONEncoder().encode(archive)
        try legacy.write(to: directory.appendingPathComponent("archive.json"))
        let interrupted = try ArchiveFileStore(directory: directory) { point in
            if point == .beforeManifestCommit { throw CocoaError(.fileWriteOutOfSpace) }
        }
        _ = try interrupted.load()
        XCTAssertThrowsError(try interrupted.save(archive))
        XCTAssertEqual(try Data(contentsOf: interrupted.file), legacy)
        XCTAssertFalse(try blobs().isEmpty)
        var firstAllocation: Int?
        let blobsURL = directory.appendingPathComponent("archive-blobs")
        let recovered = try ArchiveFileStore(directory: directory) { point in
            if point == .beforeBlobWrite, firstAllocation == nil {
                firstAllocation = try FileManager.default.contentsOfDirectory(atPath: blobsURL.path).count
            }
        }
        _ = try recovered.load(); try recovered.save(archive)
        XCTAssertEqual(firstAllocation, 0, "Reclaim pre-commit records before needing more disk space")
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().episodes.first?.transcript, "legacy private text")
    }

    func testCleanupFailureLeavesCommittedReferencesAndRetriesIdempotently() throws {
        var fail = false
        let store = try ArchiveFileStore(directory: directory) { point in
            if fail && point == .beforeOrphanRemoval { throw CocoaError(.fileWriteNoPermission) }
        }
        _ = try store.load()
        var archive = JournalArchive(episodes: [episode("old private text")]); try store.save(archive)
        archive.episodes = []; fail = true; XCTAssertThrowsError(try store.save(archive))
        XCTAssertTrue(try ArchiveFileStore(directory: directory).load().episodes.isEmpty, "Committed metadata never rolls back to deleted content")
        fail = false; try store.save(archive)
        XCTAssertEqual(store.lastStatistics.newBlobCount, 0)
        for name in try blobs() {
            let data = try Data(contentsOf: store.blobsDirectory.appendingPathComponent(name))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("old private text"))
        }
    }

    func testMissingOrCorruptBlobAndManifestFailClosedWithoutOverwrite() throws {
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(JournalArchive(episodes: [episode()]))
        let index = try manifest(), name = (index["episodes"] as! [String])[0]
        try FileManager.default.removeItem(at: store.blobsDirectory.appendingPathComponent(name))
        let disk = try Data(contentsOf: store.file)
        let broken = try ArchiveFileStore(directory: directory)
        XCTAssertThrowsError(try broken.load())
        XCTAssertThrowsError(try broken.save(JournalArchive()))
        XCTAssertEqual(try Data(contentsOf: store.file), disk)
        try Data("{bad".utf8).write(to: store.file)
        let corrupt = try ArchiveFileStore(directory: directory)
        XCTAssertThrowsError(try corrupt.load())
        XCTAssertThrowsError(try corrupt.save(JournalArchive()))
        XCTAssertEqual(try Data(contentsOf: store.file), Data("{bad".utf8))
    }

    func testPathTraversalAndSymlinkReferencesAreRejected() throws {
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(JournalArchive(episodes: [episode()]))
        var index = try manifest()
        index["episodes"] = ["../private.json"]
        try JSONSerialization.data(withJSONObject: index).write(to: store.file)
        XCTAssertThrowsError(try ArchiveFileStore(directory: directory).load())
        index["episodes"] = [UUID().uuidString + ".json"]
        let name = (index["episodes"] as! [String])[0]
        let target = directory.appendingPathComponent("outside-private.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.blobsDirectory.appendingPathComponent(name), withDestinationURL: target)
        try JSONSerialization.data(withJSONObject: index).write(to: store.file)
        XCTAssertThrowsError(try ArchiveFileStore(directory: directory).load())
    }

    func testMissingManifestWithRetainedRecordsFailsClosedAndPreservesAllBlobs() throws {
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(JournalArchive(episodes: [episode("must not be discarded")]))
        let retained = try blobs()
        try FileManager.default.removeItem(at: store.file)
        let reopened = try ArchiveFileStore(directory: directory)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertThrowsError(try reopened.save(JournalArchive()))
        XCTAssertEqual(try blobs(), retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }

    func testMissingManifestIsNewOnlyWhenRecordDirectoryIsTrulyEmpty() throws {
        let blobs = directory.appendingPathComponent("archive-blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let empty = try ArchiveFileStore(directory: directory)
        XCTAssertTrue(try empty.load().episodes.isEmpty)
        let retained = blobs.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{\"private\":\"uncommitted source\"}".utf8).write(to: retained)
        let uncertain = try ArchiveFileStore(directory: directory)
        XCTAssertThrowsError(try uncertain.load())
        XCTAssertThrowsError(try uncertain.save(JournalArchive()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testReusedRecordDisappearingAfterLoadCannotCommitANewManifest() throws {
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load()
        var archive = JournalArchive(episodes: [episode()]); try store.save(archive)
        let initial = try Data(contentsOf: store.file)
        let name = (try manifest()["episodes"] as! [String])[0]
        try FileManager.default.removeItem(at: store.blobsDirectory.appendingPathComponent(name))
        archive.markers.append(.init(date: Date(), recordingID: archive.episodes[0].id))
        XCTAssertThrowsError(try store.save(archive))
        XCTAssertEqual(try Data(contentsOf: store.file), initial)
    }

    func testDanglingManifestSymlinkIsNotTreatedAsAnEmptyArchive() throws {
        let file = directory.appendingPathComponent("archive.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent.json"))
        let store = try ArchiveFileStore(directory: directory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(JournalArchive()))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), directory.appendingPathComponent("absent.json").path)
    }

    func testAppendingHeartsReusesCompletedPagesAndReportsMetadataSize() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var archive = JournalArchive(heartPoints: (0..<8200).map { .init(sample: .init(date: start.addingTimeInterval(Double($0)), bpm: 80)) })
        let store = try ArchiveFileStore(directory: directory)
        _ = try store.load(); try store.save(archive)
        let pages = try manifest()["heartChunks"] as! [String]
        archive.heartPoints.append(.init(sample: .init(date: start.addingTimeInterval(8201), bpm: 81)))
        try store.save(archive)
        let after = try manifest()["heartChunks"] as! [String]
        XCTAssertEqual(Array(pages.prefix(2)), Array(after.prefix(2)))
        XCTAssertNotEqual(pages.last, after.last)
        XCTAssertGreaterThan(try store.metadataByteCount(), Int64(try Data(contentsOf: store.file).count))
        XCTAssertEqual(try ArchiveFileStore(directory: directory).load().heartPoints.count, 8201)
    }
}
