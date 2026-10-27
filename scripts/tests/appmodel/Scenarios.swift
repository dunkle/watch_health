import Foundation
import WatchMindCore

@main struct AppModelScenarios {
    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(3))
        for _ in 0..<30 { await Task.yield() }
    }
    @MainActor static func makeRecording(cleanup: Bool = false, lowPower: Bool = false, deferWork: Bool = false) async -> (AppModel, AudioCapture) {
        LocalStore.archive = Archive(); LocalStore.failSave = false; LocalStore.failDelete = false; LocalStore.deletedNames = []
        ScenarioDefaults.store.set(false, forKey: "filterQuietAudio")
        ScenarioDefaults.store.set(cleanup, forKey: "cleanupNewRecordings")
        ScenarioDefaults.store.set(lowPower, forKey: "fakeLowPower")
        ScenarioDefaults.store.set(deferWork, forKey: "deferHeavyWork")
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
        do {
            let (model, _) = await makeRecording()
            model.stopRecording(); await settle()
            let owner = model.episodes.first!
            let clipID = model.saveClip(recordingID: owner.id, at: owner.captureStarted!)!
            model.addPerson("friend"); let person = model.visiblePeople.first!
            model.linkPerson(person.id, clipID: clipID)
            precondition(model.visibleClips.first!.personIDs == [person.id])
            model.addMemory(clipID: clipID, text: "something I confirmed")
            precondition(model.visibleMemories.first!.enabled)
            model.editMemory(model.visibleMemories.first!.id, text: "edited", enabled: true)
            model.renamePerson(person.id, name: "renamed")
            model.episodes[0].segments[0].text = "corrected words"; model.save()
            precondition(!model.visibleClips.first!.confirmed && !model.visibleMemories.first!.enabled)
            let replacementID = model.saveClip(recordingID: owner.id, at: owner.captureStarted!)!
            precondition(replacementID != clipID && model.visibleClips.count == 2)
            model.deletePerson(person.id)
            precondition(model.visibleClips.first!.personIDs.isEmpty && model.episodes.count == 1)
            model.saveReflection("my own reflection"); precondition(model.journal.reflections.count == 1)
            model.saveReflection(""); precondition(model.journal.reflections.isEmpty)
            model.addPlan("a short walk"); model.addPlan("another plan")
            precondition(model.visiblePlans.count == 1)
            let plan = model.visiblePlans.first!; model.checkIn(plan.id, note: "felt comfortable"); model.finishPlan(plan.id)
            precondition(model.visiblePlans.first!.checkIns.count == 1 && !model.visiblePlans.first!.active)
            model.deleteClip(clipID)
            precondition(!model.visibleMemories.first!.enabled && model.visibleClips.count == 1)
            precondition(LocalStore.archive.journal.memories.first!.text == "edited")
            model.stop()
            print("PASS: quotes, manual people, source-bound memory, reflection and single active plan persist correctly")
        }
        do {
            let (model, _) = await makeRecording()
            let marker = model.markMoment()!
            model.stopRecording(); await settle()
            model.episodes[0].trigger.date = Date().addingTimeInterval(-86400)
            precondition(model.dayEvents.isEmpty)
            model.updateMarker(marker, note: "important manual context")
            model.ruleSummary()
            precondition(model.report != nil && model.report!.text.contains("important manual context"))
            precondition(model.report!.evidenceIDs == [marker])
            model.updateMarker(marker, note: "corrected")
            precondition(model.report == nil)
            model.stop()
            print("PASS: manual-only day summaries include evidence and edits invalidate cached reports")
        }
        do {
            let (model, _) = await makeRecording(cleanup: true)
            let id = model.markMoment()!
            model.stopRecording(); await settle()
            precondition(model.episodes.first!.audioPurgedAt != nil && !model.episodes.first!.transcript.isEmpty)
            precondition(!LocalStore.deletedNames.isEmpty && LocalStore.archive.episodes.first!.audioPurgedAt != nil)
            precondition(model.markers.first { $0.id == id }!.audioLocation(in: model.episodes) == nil)
            precondition(!model.journal.processing.isEmpty)
            let before = LocalStore.deletedNames.count
            await model.retry(model.episodes.first!)
            precondition(LocalStore.deletedNames.count == before)
            model.stop()
            print("PASS: opted-in full success cleans audio only after text storage, preserves markers and blocks retranscription")
        }
        do {
            for partial in [false, true] {
                let (model, audio) = await makeRecording(cleanup: true)
                audio.partialTranscription = partial; audio.failTranscription = !partial
                model.stopRecording(); await settle()
                precondition(model.episodes.first!.audioPurgedAt == nil && LocalStore.deletedNames.isEmpty)
                precondition(model.episodes.first!.status == (partial ? .partial : .failed))
                model.stop()
            }
            print("PASS: failed and partially successful transcriptions never clean original audio")
        }
        do {
            let (model, _) = await makeRecording(cleanup: true)
            LocalStore.failDelete = true; model.stopRecording(); await settle()
            precondition(model.episodes.first!.cleanupPending == true && model.episodes.first!.audioPurgedAt == nil)
            precondition(LocalStore.archive.episodes.first!.cleanupPending == true)
            model.cancelCleanup(model.episodes.first!.id)
            precondition(model.episodes.first!.cleanupPending == true, "A cleanup that may have removed files cannot be cancelled as if audio were intact")
            model.stop(); LocalStore.failDelete = false
            let restored = AppModel(); await settle()
            precondition(restored.episodes.first!.audioPurgedAt != nil && !restored.episodes.first!.transcript.isEmpty)
            print("PASS: cleanup failure persists pending intent and restart retries idempotently")
        }
        do {
            let (model, _) = await makeRecording(cleanup: true)
            LocalStore.failSave = true; model.stopRecording(); await settle()
            precondition(LocalStore.deletedNames.isEmpty && model.episodes.first!.audioPurgedAt == nil)
            LocalStore.failSave = false; model.stop()
            print("PASS: storage failure cannot authorize audio cleanup")
        }
        do {
            let (model, _) = await makeRecording(lowPower: true, deferWork: true)
            model.stopRecording(); await settle()
            precondition(model.episodes.first!.status == .deferred && !model.busy && model.transcriptionID == nil)
            await model.retry(model.episodes.first!)
            precondition(model.episodes.first!.status == .ready)
            model.stop()
            print("PASS: low-power automatic work defers and explicit manual retry can proceed")
        }
        do {
            LocalStore.failSave = false; LocalStore.failDelete = false; LocalStore.deletedNames = []
            let date = Date().addingTimeInterval(-200)
            var owner = Episode(trigger: .init(date: date, bpm: 110, baseline: 70), status: .partial)
            owner.captureStarted = date; owner.captureEnded = date.addingTimeInterval(160); owner.audioName = "first.m4a"
            owner.recordingParts = [.init(audioName: "first.m4a", startedAt: date, endedAt: date.addingTimeInterval(60)), .init(audioName: "second.m4a", startedAt: date.addingTimeInterval(100), endedAt: date.addingTimeInterval(160))]
            let old = TranscriptSegment(text: "previous second part", offset: 100, duration: 1)
            owner.segments = [old]; owner.transcript = old.text; owner.fileTranscripts = [.init(audioName: "second.m4a", text: old.text, segments: [old])]
            LocalStore.archive = Archive(episodes: [owner])
            let model = AppModel(); AudioCapture.latest!.failingNames = ["second.m4a"]
            await model.retry(model.episodes.first!)
            precondition(model.episodes.first!.status == .partial)
            precondition(model.episodes.first!.transcript.contains("saved text") && model.episodes.first!.transcript.contains("previous second part"))
            precondition(model.episodes.first!.segments.contains { $0.offset == 100 })
            precondition(LocalStore.deletedNames.isEmpty)
            model.stop()
            print("PASS: partial multi-file retry preserves previously saved text from the failed file")
        }
        do {
            let (model, audio) = await makeRecording(cleanup: true)
            model.filterQuietAudio = true; audio.simulateSkip = true
            model.stopRecording(); await settle()
            precondition(model.episodes.first!.status == .partial && LocalStore.deletedNames.isEmpty)
            precondition(model.coverage.skipped > 0)
            await model.retry(model.episodes.first!)
            precondition(!audio.lastFilter && model.episodes.first!.status == .ready)
            precondition(model.coverage.skipped == 0 && model.episodes.first!.audioPurgedAt != nil)
            model.stop()
            let (marked, markedAudio) = await makeRecording(cleanup: true)
            marked.filterQuietAudio = true; markedAudio.simulateSkip = true
            _ = marked.markMoment()
            marked.stopRecording(); await settle()
            precondition(marked.episodes.first!.status == .ready && !marked.episodes.first!.transcript.isEmpty)
            marked.stop()
            print("PASS: skipped speech candidates retain audio, manual retry disables filtering, manual markers protect nearby audio")
        }
        do {
            LocalStore.failSave = false; LocalStore.failDelete = false; LocalStore.deletedNames = []
            let date = Date().addingTimeInterval(-60)
            var owner = Episode(trigger: .init(date: date, bpm: 110, baseline: 70), status: .ready)
            owner.captureStarted = date; owner.captureEnded = Date(); owner.audioName = "retained.m4a"
            owner.transcript = "confirmed words"; owner.cleanupAfterTranscription = true; owner.cleanupPending = true
            LocalStore.archive = Archive(episodes: [owner])
            let model = AppModel(); model.cancelCleanup(owner.id); await settle()
            precondition(LocalStore.deletedNames.isEmpty && model.episodes.first!.cleanupPending == false)
            precondition(model.episodes.first!.audioPurgedAt == nil)
            model.stop()
            print("PASS: pending cleanup can be cancelled before file deletion starts")
        }
        print("AppModel stand-in scenarios passed. Apple SDK, audio routing and device behavior are NOT validated.")
    }
}
