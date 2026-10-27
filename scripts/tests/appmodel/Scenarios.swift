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
        print("AppModel stand-in scenarios passed. Apple SDK, audio routing and device behavior are NOT validated.")
    }
}
