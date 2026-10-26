import XCTest
@testable import WatchMindCore

final class LifecycleTests: XCTestCase {
    func testPermissionWaitReservesSingleOperation() throws {
        var slot = OperationSlot()
        let first = try XCTUnwrap(slot.begin())
        XCTAssertNil(slot.begin(), "A second tap must not enter while awaiting permission")
        XCTAssertTrue(slot.finish(first))
        XCTAssertNotNil(slot.begin())
    }
    func testCancellationInvalidatesPermissionCompletion() throws {
        var slot = OperationSlot()
        let cancelled = try XCTUnwrap(slot.begin())
        slot.cancel()
        XCTAssertFalse(slot.owns(cancelled))
        let next = try XCTUnwrap(slot.begin())
        XCTAssertFalse(slot.finish(cancelled), "Old defer must not clear a new start")
        XCTAssertTrue(slot.owns(next))
    }
    func testDuplicateAndLateCompletionsCannotReleaseNewWork() throws {
        var slot = OperationSlot()
        let old = try XCTUnwrap(slot.begin())
        XCTAssertTrue(slot.finish(old))
        XCTAssertFalse(slot.finish(old))
        let current = try XCTUnwrap(slot.begin())
        XCTAssertFalse(slot.finish(old))
        XCTAssertTrue(slot.owns(current))
    }
    func testWorkoutCannotRestartUntilSavingCompletes() throws {
        var workout = WorkoutLifecycle()
        let id = try XCTUnwrap(workout.begin())
        XCTAssertNil(workout.begin())
        XCTAssertTrue(workout.started(id))
        XCTAssertTrue(workout.stop(id))
        XCTAssertEqual(workout.phase, .stopping)
        XCTAssertNil(workout.begin(), "EndCollection/finishWorkout is still in flight")
        XCTAssertFalse(workout.started(id), "Late beginCollection must not undo stopping")
        XCTAssertTrue(workout.finish(id))
        XCTAssertNotNil(workout.begin())
    }
    func testOldWorkoutCallbacksCannotEndNewSession() throws {
        var workout = WorkoutLifecycle()
        let old = try XCTUnwrap(workout.begin())
        XCTAssertTrue(workout.finish(old))
        let current = try XCTUnwrap(workout.begin())
        XCTAssertFalse(workout.finish(old))
        XCTAssertFalse(workout.stop(old))
        XCTAssertFalse(workout.started(old))
        XCTAssertTrue(workout.started(current))
        XCTAssertEqual(workout.phase, .running)
    }
    func testFailedStartupAllowsFreshWorkout() throws {
        var workout = WorkoutLifecycle()
        let id = try XCTUnwrap(workout.begin())
        XCTAssertTrue(workout.finish(id))
        XCTAssertEqual(workout.phase, .idle)
        XCTAssertNotNil(workout.begin())
    }
}
