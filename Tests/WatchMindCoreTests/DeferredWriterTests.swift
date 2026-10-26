import XCTest
@testable import WatchMindCore

final class DeferredWriterTests: XCTestCase {
    enum Failure: Error { case unavailable, diskFull }
    func testLockDefersWithoutWritingAndUnlockFlushesLatestSnapshot() throws {
        var writer = DeferredWriter<String>()
        var persisted: [String] = []
        XCTAssertFalse(try writer.save("first", isAvailable: { false }, write: { persisted.append($0) }))
        XCTAssertFalse(try writer.save("latest", isAvailable: { false }, write: { persisted.append($0) }))
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertTrue(writer.hasPending)
        XCTAssertTrue(try writer.flush(isAvailable: { true }, write: { persisted.append($0) }))
        XCTAssertEqual(persisted, ["latest"])
        XCTAssertFalse(writer.hasPending)
    }
    func testLockDuringWriteRetainsDataWithoutPermanentFailure() throws {
        var writer = DeferredWriter<Int>()
        var available = true
        XCTAssertFalse(try writer.save(42, isAvailable: { available }, write: { _ in
            available = false; throw Failure.unavailable
        }))
        XCTAssertTrue(writer.hasPending)
        var saved: Int?
        XCTAssertTrue(try writer.flush(isAvailable: { true }, write: { saved = $0 }))
        XCTAssertEqual(saved, 42)
    }
    func testRealStorageErrorIsNotMisreportedAsLock() {
        var writer = DeferredWriter<Int>()
        XCTAssertThrowsError(try writer.save(42, isAvailable: { true }, write: { _ in throw Failure.diskFull }))
        XCTAssertTrue(writer.hasPending)
    }
    func testRepeatedUnlockDoesNotDuplicatePersistence() throws {
        var writer = DeferredWriter<Int>()
        var writes = 0
        try writer.save(1, isAvailable: { true }, write: { _ in writes += 1 })
        try writer.flush(isAvailable: { true }, write: { _ in writes += 1 })
        XCTAssertEqual(writes, 1)
    }
}
