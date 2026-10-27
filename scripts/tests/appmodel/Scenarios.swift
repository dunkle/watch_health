import Foundation
import WatchMindCore

@main struct AppModelScenarios {
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
    @MainActor static func makeRecording() async -> (AppModel, AudioCapture) {
        LocalStore.archive = Archive(); LocalStore.failSave = false; LocalStore.deletedNames = []
        UIApplication.shared.isProtectedDataAvailable = true
        let model = AppModel()
        await model.start()
        WatchReceiver.latest?.onTrigger?(.init(date: Date(), bpm: 110, baseline: 70))
        precondition(model.recordingID != nil && model.busy && !model.recordingPaused)
        return (model, AudioCapture.latest!)
    }
    @MainActor static func notification(_ name: Notification.Name, _ info: [String: Any] = [:]) async {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
        await settle()
    }
    @MainActor static func main() async {
        // Use an isolated defaults suite to avoid personal preferences changing test behavior.
        defer { ScenarioDefaults.store.removePersistentDomain(forName: ScenarioDefaults.name) }
        ScenarioDefaults.store.set(60, forKey: "recordingMinutes")
        do {
            let (model, audio) = await makeRecording()
            let deadline = model.recovery!.deadline
            model.setForeground(false)
            precondition(model.recordingPaused && model.busy && audio.starts == 1)
            let oldCallback = audio.oldCompletion
            model.setForeground(true)
            precondition(!model.recordingPaused && audio.starts == 2 && model.recovery!.deadline == deadline)
            oldCallback?(.success(.init(url: audio.currentURL, duration: 1)))
            precondition(model.recordingID != nil && !model.recordingPaused, "Old callbacks must not finish a new part")
            precondition(model.currentRecording!.recordingParts!.count == 2)
            model.stopRecording(); await settle()
            precondition(!model.busy && model.recordingID == nil && model.episodes.first!.status == .ready)
            let owner = model.episodes.first!
            model.delete(owner)
            precondition(LocalStore.deletedNames.count == 2 && model.episodes.isEmpty)
            model.stop()
            print("PASS: foreground pause/resume, stale callback, original deadline, multi-part deletion")
        }
        do {
            let (model, audio) = await makeRecording()
            await notification(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(1)])
            model.setForeground(false); model.setForeground(true)
            precondition(model.recordingPaused && audio.starts == 1)
            await notification(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(0), AVAudioSessionInterruptionOptionKey: UInt(0)])
            precondition(model.recordingPaused && audio.starts == 1)
            model.resumeRecording()
            precondition(!model.recordingPaused && audio.starts == 2)
            model.stopRecording(); await settle(); model.stop()
            print("PASS: call without shouldResume requires manual recovery")
        }
        do {
            let (model, audio) = await makeRecording()
            model.setForeground(false)
            await notification(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(1)])
            await notification(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(0), AVAudioSessionInterruptionOptionKey: UInt(1)])
            precondition(model.recordingPaused && audio.starts == 1)
            model.setForeground(true)
            precondition(!model.recordingPaused && audio.starts == 2)
            model.stopRecording(); await settle(); model.stop()
            print("PASS: shouldResume still waits for foreground")
        }
        do {
            let (model, audio) = await makeRecording()
            await notification(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: UInt(2)])
            model.setForeground(false); model.setForeground(true)
            await notification(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(0), AVAudioSessionInterruptionOptionKey: UInt(1)])
            precondition(model.recordingPaused && audio.starts == 1)
            audio.failNextStart = true; model.resumeRecording()
            precondition(model.recordingPaused && model.busy && audio.starts == 1)
            model.setForeground(false); model.setForeground(true)
            precondition(model.recordingPaused && audio.starts == 1, "Failed activation must not auto-retry")
            model.resumeRecording()
            precondition(!model.recordingPaused && audio.starts == 2)
            model.stopRecording(); await settle(); model.stop()
            print("PASS: route change and failed activation stay manually recoverable")
        }
        do {
            let (model, audio) = await makeRecording()
            UIApplication.shared.isProtectedDataAvailable = false
            await notification(UIApplication.protectedDataWillBecomeUnavailableNotification)
            model.setForeground(false)
            precondition(model.recordingPaused && model.storagePaused && audio.starts == 1)
            UIApplication.shared.isProtectedDataAvailable = true
            await notification(UIApplication.protectedDataDidBecomeAvailableNotification)
            precondition(model.recordingPaused && audio.starts == 1)
            model.setForeground(true)
            precondition(!model.recordingPaused && !model.storagePaused && audio.starts == 2)
            model.stopRecording(); await settle(); model.stop()
            print("PASS: locked archive defers writes and unlocked foreground resumes")
        }
        do {
            let (model, audio) = await makeRecording()
            model.setForeground(false); model.stopRecording(); await settle()
            model.setForeground(true)
            precondition(model.recordingID == nil && !model.busy && audio.starts == 1)
            model.stop()
            print("PASS: stop while paused releases operation and cannot resume")
        }
        do {
            let (model, _) = await makeRecording()
            LocalStore.failSave = true
            model.setForeground(false); await settle()
            precondition(!model.busy && model.recordingID == nil && !model.observing)
            LocalStore.failSave = false
            print("PASS: storage failure stops capture without leaking the operation")
        }
        do {
            let (model, audio) = await makeRecording()
            model.stopRecording(); await settle()
            let before = model.episodes.first!
            audio.failTranscription = true
            await model.retry(before)
            precondition(model.episodes.first!.transcript == before.transcript && !before.transcript.isEmpty)
            precondition(!model.busy && model.episodes.first!.status == .failed)
            model.stop()
            print("PASS: failed transcription retry preserves previously saved text")
        }
        do {
            let (model, audio) = await makeRecording()
            let episodeCount = model.episodes.count
            let ownerID = model.recordingID!
            let first = model.markMoment()!
            precondition(audio.starts == 1 && model.episodes.count == episodeCount)
            precondition(model.markers.first!.recordingID == ownerID && LocalStore.archive.markers.count == 1)
            model.updateMarker(first, note: String(repeating: "a", count: 600))
            precondition(model.markers.first!.note.count == 500)
            model.deleteMarker(first)
            precondition(model.episodes.count == episodeCount && LocalStore.deletedNames.isEmpty)
            model.setForeground(false)
            precondition(model.markMoment() == nil, "Background must not create UI markers")
            model.setForeground(true)
            await notification(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: UInt(2)])
            try? await Task.sleep(for: .milliseconds(5))
            precondition(model.recordingPaused)
            let gapID = model.markMoment()!
            precondition(model.markers.first(where: { $0.id == gapID })!.audioLocation(in: model.episodes) == nil)
            precondition(audio.starts == 2, "Marking in a pause must not open the microphone")
            model.stopRecording(); await settle()
            precondition(model.markMoment() == nil)
            let restored = AppModel()
            precondition(restored.markers.contains { $0.id == gapID })
            model.delete(model.episodes.first!)
            precondition(model.markers.isEmpty && LocalStore.archive.markers.isEmpty)
            model.stop()
            print("PASS: manual markers persist without fabricated heart events, survive restart, keep gaps and delete safely")
        }
        do {
            let (model, _) = await makeRecording()
            WatchReceiver.latest?.onConnection?(true)
            precondition(model.watchReachable == true && model.lastWatchPacketAt != nil)
            precondition(model.currentRecording!.recordingStage == .running)
            precondition(model.currentRecording!.transcriptionStage == .pending)
            model.stopRecording(); await settle()
            precondition(model.transcriptionID == nil && model.episodes.first!.transcriptionStage == .complete)
            model.loadDemo()
            precondition(!model.visibleMarkers.isEmpty && model.visibleMarkers.allSatisfy(\.isDemo))
            model.exitDemo()
            precondition(model.visibleMarkers.isEmpty)
            model.stop()
            print("PASS: processing state and Watch receipt are distinct; demo manual markers stay isolated")
        }
        do {
            LocalStore.archive = Archive(); LocalStore.failSave = false
            let start = Date().addingTimeInterval(-120)
            var owner = Episode(trigger: .init(date: start, bpm: 110, baseline: 70), status: .recording)
            owner.captureStarted = start; owner.audioName = "interrupted.m4a"
            owner.recordingParts = [.init(audioName: "interrupted.m4a", startedAt: start)]
            let marker = MomentMarker(date: start.addingTimeInterval(10), recordingID: owner.id)
            LocalStore.archive = Archive(episodes: [owner], markers: [marker])
            let model = AppModel()
            precondition(model.markers.first!.audioLocation(in: model.episodes) == nil)
            await model.retry(model.episodes.first!)
            precondition(model.markers.first!.audioLocation(in: model.episodes)?.offset == 10)
            precondition(model.episodes.first!.recordingStage == .complete)
            precondition(!model.busy)
            model.stop()
            print("PASS: retry recovers unknown audio end from measured file duration after termination")
        }
        print("AppModel stand-in scenarios passed. Apple SDK, audio routing and device behavior are NOT validated.")
    }
}
