"""Adversarial release audit of actual AI review evidence code.

Standalone regression for the two reviewed defects. Assertions describe required
user behavior; it returns zero only when both invariants hold.
Run scripts/check.sh first to build core objects, then:
    SWIFT_BIN=/path/to/swift python3 scripts/tests/review-ai-regressions.py
No Apple SDK, real model, key, or external network is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
swift = os.environ.get("SWIFT_BIN", "swift")
swiftc = str(Path(swift).with_name("swiftc")) if "/" in swift else "swiftc"
build = Path(os.environ["WATCHMIND_CORE_BUILD"]) if "WATCHMIND_CORE_BUILD" in os.environ else Path(subprocess.check_output([swift, "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
objects = sorted((build / "WatchMindCore.build").glob("*.swift.o"))
if not objects:
    raise SystemExit("Build the core with scripts/check.sh first.")

HARNESS = r'''
import Foundation
import WatchMindCore

@main struct Audit {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var owner = Episode(trigger: .init(date: start, bpm: 85, baseline: 70), status: .ready)
        owner.captureStarted = start
        owner.captureEnded = start.addingTimeInterval(300)
        owner.segments = [.init(text: "hello", offset: 0.1, duration: 0.2)]
        var failures = 0

        // The UI offers 0.1-second selection; the actual wire snapshot must retain it.
        let precise = AIReviewSelection(recordingID: owner.id, start: start.addingTimeInterval(0.1),
                                        end: start.addingTimeInterval(0.2), includeHeart: false)
        let evidence = try AIReviewEvidence.build(selection: precise, episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        let payload = try JSONSerialization.jsonObject(with: Data(try evidence.preview.utf8)) as! [String: Any]
        let selection = payload["selection"] as! [String: Any]
        if selection["start"] as? String == selection["end"] as? String {
            print("FAIL AI-R01: distinct 0.1-second range becomes identical start/end in transmitted JSON: \(selection["start"]!)")
            failures += 1
        } else {
            print("PASS AI-R01: selected subsecond timestamps remain distinct on the wire")
        }

        // Speech returns timed words; 120 words/minute is an ordinary speaking rate.
        // The composer selects 300 seconds by default. This default must be usable
        // without silently removing words or signals (e.g. by compact representation).
        owner.segments = (0..<600).map { .init(text: "hello", offset: Double($0) * 0.5, duration: 0.3) }
        let hearts = (0..<60).map {
            HeartPoint(sample: .init(date: start.addingTimeInterval(Double($0) * 5), bpm: 80), baseline: 70)
        }
        let ordinary = AIReviewSelection(recordingID: owner.id, start: start, end: start.addingTimeInterval(300))
        do {
            let snapshot = try AIReviewEvidence.build(selection: ordinary, episodes: [owner], heartPoints: hearts, metrics: [], isDemo: false)
            let text = snapshot.transcript.map(\.text).joined(separator: " ")
            let retainedWords = text.split(whereSeparator: { $0.isWhitespace }).count
            if retainedWords != 600 || snapshot.heartPoints.count != 60 {
                print("FAIL AI-R02: default five-minute input silently lost supplied evidence")
                failures += 1
            } else {
                print("PASS AI-R02: default five-minute ordinary speech retains all 600 words and 60 heart samples")
            }
        } catch {
            print("FAIL AI-R02: default five-minute ordinary speech cannot reach analysis: \(error)")
            failures += 1
        }
        if failures > 0 { exit(1) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="watchmind-ai-audit-") as temporary:
    target = Path(temporary)
    source = target / "Audit.swift"
    source.write_text(HARNESS)
    command = [swiftc, "-swift-version", "5", "-module-cache-path", str(target / "module-cache"),
               "-I", str(build / "Modules"), "-parse-as-library", str(source), *map(str, objects),
               "-o", str(target / "audit")]
    subprocess.run(command, cwd=ROOT, check=True, timeout=90)
    result = subprocess.run([str(target / "audit")], cwd=ROOT, timeout=30)
raise SystemExit(result.returncode)
