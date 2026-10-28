"""Synthetic core JSON capacity probe; not an iPhone performance or storage test.
Run scripts/check.sh first. Output numbers describe this executor only.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
swift = os.environ.get('SWIFT_BIN', 'swift')
swiftc = str(Path(swift).with_name('swiftc')) if '/' in swift else 'swiftc'
environment = dict(os.environ, CLANG_MODULE_CACHE_PATH='/tmp/watchmind-capacity-clang-cache')
build = Path(subprocess.check_output([swift, 'build', '--show-bin-path'], cwd=root, env=environment, text=True).strip())
objects = sorted((build / 'WatchMindCore.build').glob('*.swift.o'))
assert objects, 'Run scripts/check.sh first'
source = r'''
import Foundation
import WatchMindCore
@main struct Capacity {
    static func main() throws {
        let days = Int(CommandLine.arguments[1])!
        let minutes = Int(CommandLine.arguments[2])!
        let begin = Date(timeIntervalSince1970: 1800000000)
        var archive = JournalArchive()
        // One continuous recording/day, 120 Speech word segments/minute, 7-day heart cap.
        for day in 0..<days {
            let start = begin.addingTimeInterval(Double(day) * 86400)
            var event = Episode(trigger: .init(date: start, bpm: 90, baseline: 70), status: .ready)
            event.captureStarted = start; event.captureEnded = start.addingTimeInterval(Double(minutes * 60))
            event.segments = (0..<(minutes * 120)).map { .init(text: "conversation", offset: Double($0) / 2, duration: 0.45) }
            event.transcript = event.segments.map(\.text).joined(separator: " ")
            archive.episodes.append(event)
        }
        archive.heartPoints = (0..<60000).map { .init(sample: .init(date: begin.addingTimeInterval(Double($0) * 5), bpm: 76), baseline: 75) }
        let start = Date()
        let data = try JSONEncoder().encode(archive)
        let encoded = Date()
        let decoded = try JSONDecoder().decode(JournalArchive.self, from: data)
        let end = Date()
        precondition(decoded.episodes.count == days && decoded.heartPoints.count == 60000)
        let report: [String: Any] = ["recordings": days, "minutes_per_recording": minutes,
            "word_segments": days * minutes * 120, "heart_points": 60000, "archive_bytes": data.count,
            "encode_ms": encoded.timeIntervalSince(start) * 1000, "decode_ms": end.timeIntervalSince(encoded) * 1000,
            "scope": "Synthetic core JSON; no audio, metrics, AI history, file I/O or iPhone profiling"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
'''
with tempfile.TemporaryDirectory(prefix='watchmind-capacity-') as temporary:
    target = Path(temporary)
    (target / 'Capacity.swift').write_text(source)
    subprocess.run([swiftc, '-parse-as-library', '-O', '-swift-version', '5', '-I', str(build / 'Modules'), str(target / 'Capacity.swift'),
                    *map(str, objects), '-o', str(target / 'capacity')], cwd=root, env=environment, check=True, timeout=90)
    for days, minutes in [(7, 30), (30, 60)]:
        result = subprocess.check_output([str(target / 'capacity'), str(days), str(minutes)], cwd=root, env=environment, text=True, timeout=90)
        print(json.dumps(json.loads(result), ensure_ascii=False, sort_keys=True))
