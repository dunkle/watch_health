"""Reproduce confirmed release-review defects in the actual core (intentionally red).

This audit is excluded from check.sh until its production defects are fixed. It creates
an isolated temporary Swift package whose Sources symlink points at the repository's
actual WatchMindCore. No copied/fake core implementation, Apple SDK, or network is used.

Run: SWIFT_BIN=/path/to/swift python3 scripts/tests/review-health-regressions.py
A nonzero result means at least one release invariant remains broken. Tests assert
expected product behavior, rather than accepting a known defect as successful behavior.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = os.environ.get('SWIFT_BIN', 'swift')
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WatchMindHealthReleaseAudit", defaultLocalization: "en",
    products: [.library(name: "WatchMindCore", targets: ["WatchMindCore"])],
    targets: [.target(name: "WatchMindCore", resources: [.process("Resources")]),
              .testTarget(name: "ReleaseHealthAudit", dependencies: ["WatchMindCore"])],
    swiftLanguageModes: [.v5])
'''
TESTS = r'''
import XCTest
@testable import WatchMindCore

final class ReleaseHealthAudit: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testAssessmentUsesComparableSources() {
        var own: [MetricReading] = []
        for day in 1...7 {
            let date = now.addingTimeInterval(-Double(day) * 86400)
            own += [.init(kind: .hrv, value: 50, date: date, source: "Watch"),
                    .init(kind: .oxygen, value: 98, date: date, source: "Watch")]
        }
        own += [.init(kind: .hrv, value: 50, date: now, source: "Watch"),
                .init(kind: .oxygen, value: 98, date: now, source: "Watch"),
                .init(kind: .sleepScore, value: 80, date: now, source: "local")]
        let other = (1...7).map { MetricReading(kind: .hrv, value: 200,
            date: now.addingTimeInterval(-Double($0) * 86400), source: "Other device") }
        let trigger = Trigger(date: now, bpm: 120, baseline: 100)
        let before = ContextAlgorithm.assess(trigger, readings: own)
        let after = ContextAlgorithm.assess(trigger, readings: own + other)
        print("AUDIT source mixing: score \(before.score) -> \(after.score), coverage \(after.coverage)")
        XCTAssertEqual(after.score, before.score, accuracy: 0.001,
            "An incompatible source must not manufacture a personal HRV deviation or important event")
    }
    func testMinimumFiveDaysUsesCalendarDaysAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = ISO8601DateFormatter()
        let today = formatter.date(from: "2026-03-16T04:00:00Z")! // Mar16 midnight EDT
        // Mar1 23:30 EST lies outside the previous14 calendar days beginning Mar2 midnight.
        let dates = ["2026-03-02T04:30:00Z", "2026-03-03T17:00:00Z", "2026-03-04T17:00:00Z",
                     "2026-03-05T17:00:00Z", "2026-03-06T17:00:00Z"].map { formatter.date(from: $0)! }
        let readings = dates.map { MetricReading(kind: .hrv, value: 50, date: $0, source: "Watch") }
        let baseline = ContextAlgorithm.baseline(.hrv, readings: readings, before: today, calendar: calendar)
        print("AUDIT DST: four valid history days plus one outside-day sample produced baseline \(String(describing: baseline))")
        XCTAssertNil(baseline, "The15th calendar day must not fake the minimum five valid history days")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='watchmind-health-release-audit-') as directory:
    target = Path(directory)
    (target / 'Sources').mkdir()
    (target / 'Sources/WatchMindCore').symlink_to(ROOT / 'Sources/WatchMindCore', target_is_directory=True)
    (target / 'Tests/ReleaseHealthAudit').mkdir(parents=True)
    (target / 'Package.swift').write_text(PACKAGE)
    (target / 'Tests/ReleaseHealthAudit/Audit.swift').write_text(TESTS)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(target / 'clang-cache'),
                       XDG_CACHE_HOME=str(target / 'cache'))
    command = [SWIFT, 'test', '--package-path', str(target), '--scratch-path', str(target / 'build'),
               '--cache-path', str(target / 'cache'), '--config-path', str(target / 'config'),
               '--security-path', str(target / 'security'), '-j', '4']
    result = subprocess.run(command, cwd=ROOT, env=environment, text=True, capture_output=True, timeout=180)
    output = result.stdout + result.stderr
    if 'Executed 2 tests' not in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    for line in output.splitlines():
        if 'AUDIT ' in line or ': error:' in line or 'Executed 2 tests' in line:
            print(line)
    print('Intentional release-invariant audit; it is not part of the green baseline check.sh suite.')
    raise SystemExit(result.returncode)
