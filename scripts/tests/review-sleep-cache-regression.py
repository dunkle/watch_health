"""Reproduce stale derived sleep revisions in the actual AppModel (intentionally red).

Run after building the core, with the same SWIFT_BIN as scripts/check.sh. This is
an audit regression excluded from check.sh until the defect is fixed. It compiles
the actual AppModel and Journal extension with platform stand-ins, and extracts
the actual sleep-to-MetricReading mapping from HealthSource.swift. No Apple SDK,
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

# Reuse the actual native derivation, including its ID policy. The probe should stop
# reproducing if the ID is fixed, as well as if the AppModel merge policy is fixed.
health_source = (ROOT / 'iOS/HealthSource.swift').read_text()
marker = 'result += SleepScorer.estimates(intervals).map {'
start = health_source.index(marker) + len(marker)
end = health_source.index('\n            }', start)
derive = 'SleepScorer.estimates(intervals).map {' + health_source[start:end] + '\n}'

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
                let rows = NATIVE_DERIVATION
                if destination == 0 { partial += rows } else { final += rows }
            }
        }
        LocalStore.archive = Archive(metrics: partial)
        HealthSource.rows = final
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
'''.replace('NATIVE_DERIVATION', derive)

with tempfile.TemporaryDirectory(prefix='watchmind-sleep-release-audit-') as directory:
    target = Path(directory)
    model = (ROOT / 'iOS/AppModel.swift').read_text().replace('import SwiftUI', 'import Foundation').replace('import AVFoundation', '').replace('UserDefaults.standard', 'ScenarioDefaults.store')
    (target / 'AppModel.swift').write_text(model)
    doubles = (ROOT / 'scripts/tests/appmodel/PlatformDoubles.swift').read_text()
    stub = 'func context(authorize: Bool) async throws -> [MetricReading] { [] }'
    assert doubles.count(stub) == 1, 'Update the HealthSource fixture adapter after platform-double changes.'
    doubles = doubles.replace(stub, 'static var rows: [MetricReading] = []\n    func context(authorize: Bool) async throws -> [MetricReading] { Self.rows }')
    (target / 'PlatformDoubles.swift').write_text(doubles)
    (target / 'ReleaseAudit.swift').write_text(harness)
    command = [SWIFTC, '-swift-version', '5', '-module-cache-path', str(target / 'module-cache'),
               '-I', str(build / 'Modules'), str(target / 'PlatformDoubles.swift'),
               str(target / 'AppModel.swift'), str(target / 'ReleaseAudit.swift'),
               str(ROOT / 'iOS/AppModel+Journal.swift'), *map(str, objects), '-o', str(target / 'audit')]
    subprocess.run(command, cwd=ROOT, check=True, timeout=90)
    result = subprocess.run([str(target / 'audit')], cwd=ROOT, timeout=30)
    print('Actual AppModel with platform stand-ins; not Apple HealthKit validation. Intentional release audit, excluded from check.sh.')
    raise SystemExit(result.returncode)
