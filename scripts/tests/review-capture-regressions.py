"""Adversarial capture audit of actual AppModel orchestration with platform stand-ins.

Run after scripts/check.sh (or build the core first):
    SWIFT_BIN=/path/to/swift python3 scripts/tests/review-capture-regressions.py

This is intentionally outside check.sh: a red result records an unresolved review
finding, not an expected product behavior. It exits 1 if any correctness invariant
fails. It never accesses Apple APIs, user recordings, real secrets, or the network.
The only stand-in adaptation lets a transcription return a chosen partial result.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = os.environ.get("SWIFT_BIN", "swift")
SWIFTC = str(Path(SWIFT).with_name("swiftc")) if "/" in SWIFT else "swiftc"
environment = dict(os.environ)
environment.setdefault("CLANG_MODULE_CACHE_PATH", "/tmp/watchmind-review-capture-clang")
environment.setdefault("XDG_CACHE_HOME", "/tmp/watchmind-review-capture-cache")

HARNESS = r'''
import Foundation
import WatchMindCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main struct CaptureReview {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ passed: Bool, _ name: String, observed: String) {
        checks += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL"): \(name); observed: \(observed)")
    }
    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<30 { await Task.yield() }
    }
    @MainActor static func reset(_ archive: Archive = Archive()) {
        LocalStore.archive = archive
        LocalStore.failSave = false; LocalStore.failDelete = false; LocalStore.deletedNames = []
        UIApplication.shared.isProtectedDataAvailable = true
        ScenarioDefaults.store.set(false, forKey: "cleanupNewRecordings")
        ScenarioDefaults.store.set(false, forKey: "filterQuietAudio")
        ScenarioDefaults.store.set(false, forKey: "deferHeavyWork")
    }
    static func owner() -> Episode {
        let began = Date().addingTimeInterval(-130)
        var item = Episode(trigger: .init(date: began, bpm: 100, baseline: 70), status: .partial)
        item.audioName = "audit-fixture.m4a"
        item.captureStarted = began; item.captureEnded = began.addingTimeInterval(90)
        item.recordingParts = [.init(audioName: "audit-fixture.m4a", startedAt: began, endedAt: began.addingTimeInterval(90))]
        item.transcript = "fixture first chunk"
        item.segments = [.init(text: item.transcript, offset: 0, duration: 10)]
        item.fileTranscripts = [.init(audioName: "audit-fixture.m4a", text: item.transcript, segments: item.segments)]
        return item
    }
    @MainActor static func main() async throws {
        defer { ScenarioDefaults.store.removePersistentDomain(forName: ScenarioDefaults.name) }
        // Retry succeeds in the second chunk but fails in the previously successful first chunk.
        do {
            let item = owner(); reset(Archive(episodes: [item]))
            let model = AppModel()
            AudioCapture.latest!.craftedResult = .init(text: "fixture second chunk", segments: [.init(text: "fixture second chunk", offset: 45, duration: 10)], failedChunks: 1, duration: 90, spans: [(0..<45, .failed), (45..<90, .recognized)])
            await model.retry(item)
            let saved = model.episodes[0].transcript
            let oldPresent = saved.contains("fixture first chunk"), newPresent = saved.contains("fixture second chunk")
            check(oldPresent && newPresent, "a partial retry preserves earlier successful chunks in the same file", observed: "old-present=\(oldPresent), new-present=\(newPresent)")
        }
        // A transient disk failure must offer a recovery write and an independent recovery export.
        do {
            reset(Archive(episodes: [owner()]))
            let model = AppModel()
            LocalStore.failSave = true; _ = model.save()
            LocalStore.failSave = false; model.setForeground(true)
            check(model.canWriteArchive, "saving can recover after transient storage failure is resolved", observed: "can-write=\(model.canWriteArchive)")
            let exportAvailable = (try? model.exportTextArchive()) != nil
            check(exportAvailable, "in-memory private records can be exported for recovery after a storage failure", observed: "export-available=\(exportAvailable)")
        }
        // Admission checks must precede both curve writes and the current-owner linking shortcut.
        for invalidValue in [true, false] {
            reset()
            let model = AppModel(); await model.start()
            WatchReceiver.latest?.onTrigger?(.init(date: Date(), bpm: 110, baseline: 70))
            guard model.recordingID != nil else { fatalError("Audit fixture could not create a recording") }
            let entries = model.episodes.count, points = model.heartPoints.count
            WatchReceiver.latest?.onTrigger?(.init(date: Date().addingTimeInterval(invalidValue ? 0 : 120), bpm: invalidValue ? 1e300 : 110, baseline: 70))
            let noMutation = model.episodes.count == entries && model.heartPoints.count == points
            check(noMutation, invalidValue ? "an invalid heart value cannot enter a linked event or curve" : "a future trigger cannot enter a linked event or curve", observed: "entry-delta=\(model.episodes.count - entries), point-delta=\(model.heartPoints.count - points)")
            model.stopRecording(); await settle(); model.stop()
        }
        // Delete I/O must not remove audio while leaving a durable archive that still references it.
        do {
            let item = owner(); reset(Archive(episodes: [item]))
            let model = AppModel()
            LocalStore.failSave = true; model.delete(item); LocalStore.failSave = false
            let audioDeleted = LocalStore.deletedNames.contains("audit-fixture.m4a")
            let durableReference = LocalStore.archive.episodes.contains { $0.id == item.id }
            check(!(audioDeleted && durableReference), "a failed deletion write leaves a recoverable consistent archive/audio state", observed: "audio-deleted=\(audioDeleted), durable-reference=\(durableReference)")
        }
        print("Capture audit: \(checks - failures)/\(checks) invariants passed. Platform stand-ins do not validate Apple APIs.")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

build = subprocess.check_output([SWIFT, "build", "--show-bin-path"], cwd=ROOT,
                                env=environment, text=True).strip()
objects = sorted((Path(build) / "WatchMindCore.build").glob("*.swift.o"))
if not objects:
    raise SystemExit("Core objects are missing. Run scripts/check.sh with SWIFT_BIN first.")

standins = (ROOT / "scripts/tests/appmodel/PlatformDoubles.swift").read_text()
needle = "    var partialTranscription = false"
assert needle in standins, "The transcription stand-in changed; update this audit adapter."
standins = standins.replace(needle, "    var craftedResult: TranscriptionResult?\n" + needle)
needle = "        lastFilter = filterQuiet"
assert needle in standins, "The transcription stand-in changed; update this audit adapter."
standins = standins.replace(needle, "        if let craftedResult { return craftedResult }\n" + needle)
model = (ROOT / "iOS/AppModel.swift").read_text().replace("import SwiftUI", "import Foundation")
model = model.replace("import AVFoundation", "").replace("UserDefaults.standard", "ScenarioDefaults.store")
with tempfile.TemporaryDirectory(prefix="watchmind-review-capture-") as folder:
    target = Path(folder)
    (target / "AppModel.swift").write_text(model)
    (target / "PlatformDoubles.swift").write_text(standins)
    (target / "Audit.swift").write_text(HARNESS)
    command = [SWIFTC, "-swift-version", "5", "-I", str(Path(build) / "Modules"),
               str(target / "PlatformDoubles.swift"), str(target / "AppModel.swift"),
               str(ROOT / "iOS/AppModel+Journal.swift"), str(target / "Audit.swift"),
               *map(str, objects), "-o", str(target / "audit")]
    subprocess.run(command, cwd=ROOT, env=environment, check=True, timeout=90)
    result = subprocess.run([str(target / "audit")], cwd=ROOT, env=environment, timeout=30)
    raise SystemExit(result.returncode)
