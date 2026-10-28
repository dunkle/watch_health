"""Reproduce stale derived sleep revisions in the actual AppModel (release regression).

Run after building the core, with the same SWIFT_BIN as scripts/check.sh. This is
a release regression whose assertions remain enabled in the normal checks. It compiles
the actual AppModel and Journal extension with platform stand-ins, and shares
the actual sleep-to-MetricReading derivation used by HealthSource.swift. No Apple SDK,
real HealthKit, network, private data, or previously created /tmp file is required.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = os.environ.get('SWIFT_BIN', 'swift')
SWIFTC = str(Path(SWIFT).with_name('swiftc')) if '/' in SWIFT else 'swiftc'
build = Path(subprocess.check_output([SWIFT, 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
objects = sorted((build / 'WatchMindCore.build').glob('*.swift.o'))
assert objects, 'Build the core with scripts/check.sh before running this release audit.'

# Native HealthSource and this regression share the exact same pure derivation.
health_source = (ROOT / 'iOS/HealthSource.swift').read_text()
assert 'MetricHistory.sleepReadings(sleepResult.intervals)' in health_source

harness = r'''
import Foundation
import WatchMindCore
@main struct ReleaseSleepCacheAudit {
    @MainActor static func main() async {
        defer { ScenarioDefaults.store.removePersistentDomain(forName: ScenarioDefaults.name) }
        let calendar = Calendar.current, today = Calendar.current.startOfDay(for: Date())
        var partial: [MetricReading] = [], final: [MetricReading] = []
        for day in 1...5 {
            let night = calendar.date(byAdding: .day, value: -day, to: today)!
            for (hours, destination) in [(4, 0), (8, 1)] {
                let intervals: [SleepInterval] = [.init(start: night,
                    end: night.addingTimeInterval(Double(hours) * 3600), state: .asleep, source: "Watch")]
                var rows = MetricHistory.sleepReadings(intervals, calendar: calendar)
                if destination == 0 {
                    // A pre-fix archive used a changing end timestamp as the ID.
                    for index in rows.indices { rows[index].id = "sleep-\(rows[index].date.timeIntervalSince1970)"; rows[index].sourceID = nil }
                }
                if destination == 0 { partial += rows } else { final += rows }
            }
        }
        LocalStore.archive = Archive(metrics: partial)
        HealthSource.rows = final
        HealthSource.sleepWindow = DateInterval(start: ContextAlgorithm.historyStart(before: Date()), end: Date())
        let model = AppModel()
        await model.refreshMetrics()
        let samples = model.metrics.filter { $0.kind == .sleepScore }
        let baseline = HealthReview.trend(.sleepScore, readings: samples, at: Date())?.baseline
        print("AUDIT sleep revisions: saved \(samples.count) estimates for5 nights; baseline \(String(describing: baseline)); expected5 latest estimates and100-point baseline.")
        guard samples.count == 5 && baseline == 100 else {
            print("FAIL: obsolete partial-night estimates remain after final HealthKit sync and bias the daily baseline.")
            exit(1)
        }
        print("PASS: final nightly estimates replace partial derived revisions.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='watchmind-sleep-release-audit-') as directory:
    target = Path(directory)
    model = (ROOT / 'iOS/AppModel.swift').read_text().replace('import SwiftUI', 'import Foundation').replace('import AVFoundation', '').replace('UserDefaults.standard', 'ScenarioDefaults.store')
    (target / 'AppModel.swift').write_text(model)
    doubles = (ROOT / 'scripts/tests/appmodel/PlatformDoubles.swift').read_text()
    stub = 'func context(authorize: Bool) async throws -> [MetricReading] { [] }'
    assert doubles.count(stub) == 1, 'Update the HealthSource fixture adapter after platform-double changes.'
    doubles = doubles.replace(stub, 'static var rows: [MetricReading] = []\n    static var sleepWindow: DateInterval?\n    func context(authorize: Bool) async throws -> [MetricReading] { Self.rows }')
    import re
    snapshot = 'func contextSnapshot(authorize: Bool) async throws -> HealthMetricSnapshot { HealthMetricSnapshot(readings: Self.rows, replacingSleepWindow: Self.sleepWindow) }'
    if 'func contextSnapshot(' in doubles:
        doubles, count = re.subn(r'func contextSnapshot\([^)]*\)[^{]*\{[^}]*\}', snapshot, doubles)
        assert count == 1, 'Update the health snapshot fixture after platform-double changes.'
    else:
        doubles = doubles.replace('func context(authorize: Bool) async throws -> [MetricReading] { Self.rows }', 'func context(authorize: Bool) async throws -> [MetricReading] { Self.rows }\n    ' + snapshot)
    (target / 'PlatformDoubles.swift').write_text(doubles)
    (target / 'ReleaseAudit.swift').write_text(harness)
    command = [SWIFTC, '-swift-version', '5', '-module-cache-path', str(target / 'module-cache'),
               '-I', str(build / 'Modules'), str(target / 'PlatformDoubles.swift'),
               str(target / 'AppModel.swift'), str(target / 'ReleaseAudit.swift'),
               str(ROOT / 'iOS/AppModel+Journal.swift'), *map(str, objects), '-o', str(target / 'audit')]
    subprocess.run(command, cwd=ROOT, check=True, timeout=90)
    result = subprocess.run([str(target / 'audit')], cwd=ROOT, timeout=30)
    print('Actual AppModel with platform stand-ins; not Apple HealthKit validation. Release regression: legacy cached revisions must not survive a successful refresh.')
    raise SystemExit(result.returncode)
