import SwiftUI
import WatchMindCore
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            receiver.setLanguage(language.rawValue)
            revision += 1
        }
    }
    @Published var avatar: AvatarConfiguration = {
        guard let data = UserDefaults.standard.data(forKey: "avatarConfiguration"),
              let value = try? JSONDecoder().decode(AvatarConfiguration.self, from: data) else { return AvatarConfiguration() }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(avatar) { UserDefaults.standard.set(data, forKey: "avatarConfiguration") } }
    }
    @Published private(set) var recovery: RecordingRecovery?
    var recordingPaused: Bool { recovery?.phase == .paused }
    private var activePartID: UUID?
    private var recordingDeadline: Task<Void, Never>?
    private var systemAudioInterrupted = false
    private var l: Localizer { Localizer(language: language) }
    private func describe(_ error: Error) -> String {
        (error as? AudioCapture.CaptureError)?.message(language: language) ?? l.key(error.localizedDescription)
    }
    @Published var recordingMinutes = {
        let stored = UserDefaults.standard.integer(forKey: "recordingMinutes")
        return stored == 0 ? RecordingPolicy.defaultMinutes : RecordingPolicy.minutes(stored)
    }() {
        didSet { UserDefaults.standard.set(RecordingPolicy.minutes(recordingMinutes), forKey: "recordingMinutes") }
    }
    @Published var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateWakefulness() }
    }
    @Published var heartPoints: [HeartPoint] = []
    @Published var metrics: [MetricReading] = []
    @Published var demoMetrics: [MetricReading] = []
    @Published var refreshingMetrics = false
    @Published var transcriptionCompleted = 0
    @Published var transcriptionTotal = 0
    @Published var episodes: [Episode] = []
    @Published var markers: [MomentMarker] = []
    @Published var journal = JournalCollection()
    @Published var cleanupNewRecordings = UserDefaults.standard.bool(forKey: "cleanupNewRecordings") {
        didSet { UserDefaults.standard.set(cleanupNewRecordings, forKey: "cleanupNewRecordings") }
    }
    @Published var filterQuietAudio = UserDefaults.standard.bool(forKey: "filterQuietAudio") {
        didSet { UserDefaults.standard.set(filterQuietAudio, forKey: "filterQuietAudio") }
    }
    @Published var deferHeavyWork = UserDefaults.standard.bool(forKey: "deferHeavyWork") {
        didSet { UserDefaults.standard.set(deferHeavyWork, forKey: "deferHeavyWork") }
    }
    @Published var audioSensitivity = {
        let value = UserDefaults.standard.integer(forKey: "audioSensitivity")
        return value == 0 ? 3 : min(5, max(1, value))
    }() {
        didSet { UserDefaults.standard.set(min(5, max(1, audioSensitivity)), forKey: "audioSensitivity") }
    }
    private var activeObservationID: UUID?
    @Published var lastMarkedID: UUID?
    @Published var transcriptionID: UUID?
    @Published var watchReachable: Bool?
    @Published var lastWatchPacketAt: Date?
    @Published var summaryDay: Date?
    @Published var summaryFailure: String?
    @Published var reports: [DailyReport] = []
    @Published var observing = false
    @Published var foreground = true
    @Published private var work = OperationSlot()
    @Published var summarizing = false
    @Published var latestBPM: Double?
    @Published var latestSampleAt: Date?
    @Published var error: String?
    @Published var demoMode = false
    @Published var consenting = false
    @Published var recordingID: UUID?
    @Published var playingID: UUID?
    @Published var selectedDay = Date()
    @Published private(set) var storagePaused = false
    private let audio = AudioCapture()
    private let health = HealthSource()
    private let receiver = WatchReceiver()
    private var store: LocalStore?
    private var detector = HeartDetector()
    private var largeDetector = HeartDetector.largeChanges()
    private var lastSeriesSave = Date.distantPast
    private var contextRefresh = OperationSlot()
    private var lastContextRefresh = Date.distantPast
    private var player: AVAudioPlayer?
    private var observationStart: Date?
    private var captureGate = CaptureGate()
    private var starts = OperationSlot()
    private var notificationTokens: [NSObjectProtocol] = []
    private var writable = true
    private var archiveLoaded = false
    private var archiveWriter = DeferredWriter<Archive>()
    private var revision = 0

    var busy: Bool { work.current != nil }
    var canWriteArchive: Bool { writable && archiveLoaded && !storagePaused }
    var visibleMetrics: [MetricReading] { demoMode ? demoMetrics : metrics }
    var dayHeartPoints: [HeartPoint] {
        heartPoints.filter { $0.isDemo == demoMode && Calendar.current.isDate($0.sample.date, inSameDayAs: selectedDay) }
    }
    var currentRecording: Episode? { episodes.first { $0.id == recordingID } }
    func recordingOwner(_ event: Episode) -> Episode? { event.owner(in: episodes) }
    var visible: [Episode] { episodes.filter { $0.isDemo == demoMode } }
    var visibleMarkers: [MomentMarker] { markers.filter { $0.isDemo == demoMode && $0.owner(in: visible) != nil } }
    var hourBuckets: [HourBucket] { HourTimeline.buckets(on: selectedDay, episodes: visible, markers: visibleMarkers) }
    var dayEvents: [Episode] { Insights.events(on: selectedDay, from: visible) }
    var summaryEvidenceIDs: [UUID] {
        dayEvents.map(\.id) + visibleMarkers.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }.map(\.id) + visibleClips.filter { $0.confirmed && Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }.map(\.id)
    }
    var report: DailyReport? {
        reports.last { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) && ($0.evidenceIDs ?? $0.episodeIDs) == summaryEvidenceIDs && ($0.language ?? "zh-Hans") == language.resolved.rawValue }
    }
    init() {
        resumeStorage()
        receiver.onSample = { [weak self] sample in self?.lastWatchPacketAt = Date(); self?.ingest(sample) }
        receiver.onTrigger = { [weak self] trigger in self?.lastWatchPacketAt = Date(); self?.accept(trigger) }
        receiver.onConnection = { [weak self] in self?.watchReachable = $0 }
        receiver.setLanguage(language.rawValue)
        receiver.activate()
        Task { [weak self] in self?.processPendingCleanup() }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.systemAudioInterrupted = true
                    self.pauseRecording(note: "系统音频中断，已保留片段；等待恢复。", automatic: false)
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.systemAudioInterrupted = false
                    self.recovery?.allowAutomaticResume(AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                    self.resumeRecording(automatic: true)
                }
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pauseRecording(note: "音频设备已断开，请确认环境后点击继续录音。", automatic: false, manualOnly: true) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.pauseRecording(note: "系统音频服务已重置，可手动继续录音。", automatic: false, manualOnly: true) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.storagePaused = true
                self?.pauseRecording(note: "设备已锁定，解锁回到应用后可恢复录音。", automatic: self?.recordingPaused == true ? (self?.recovery?.automaticResumeAllowed ?? false) : true)
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.resumeStorage(); self?.resumeRecording(automatic: true) }
        })
    }
    deinit { recordingDeadline?.cancel(); notificationTokens.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Retain dirty state in memory while locked. Never replace an unreadable archive with an empty one.
    private func resumeStorage() {
        guard writable else { return }
        guard UIApplication.shared.isProtectedDataAvailable else { storagePaused = true; return }
        var newlyLoaded = false
        if !archiveLoaded {
            do {
                let store = try LocalStore()
                let archive = try store.load()
                self.store = store; episodes = archive.episodes; reports = archive.reports
                markers = archive.markers.filter { $0.owner(in: archive.episodes) != nil }
                journal = archive.journal; journal.reconcile(episodes: episodes)
                for i in journal.observations.indices where journal.observations[i].end == nil {
                    journal.observations[i].end = journal.observations[i].lastKnownAt
                }
                heartPoints = Array(archive.heartPoints.filter { $0.sample.date >= Date().addingTimeInterval(-7 * 86400) }.suffix(60000))
                metrics = archive.metrics.filter { $0.date >= Date().addingTimeInterval(-14 * 86400) }
                archiveLoaded = true
                for index in episodes.indices where [.recording, .paused, .transcribing].contains(episodes[index].status) {
                    episodes[index].status = .failed
                    episodes[index].note = "上次任务被中断。可手动重试本地转写。"
                }
                newlyLoaded = true
            } catch {
                if !UIApplication.shared.isProtectedDataAvailable { storagePaused = true; return }
                writable = false
                self.error = l("无法读取本地档案，已停止写入以保护原文件：\(describe(error))")
                return
            }
        }
        storagePaused = false
        if newlyLoaded || archiveWriter.hasPending { save() }
    }
    @discardableResult func save() -> Bool {
        journal.reconcile(episodes: episodes)
        if let id = activeObservationID, let i = journal.observations.firstIndex(where: { $0.id == id }) { journal.observations[i].lastKnownAt = Date() }
        // Invalidate in-flight summaries even when disk persistence is deferred.
        revision += 1
        guard writable, archiveLoaded, let store else { return false }
        do {
            let persisted = try archiveWriter.save(Archive(episodes: episodes, reports: reports, heartPoints: heartPoints, metrics: metrics, markers: markers, journal: journal),
                isAvailable: { UIApplication.shared.isProtectedDataAvailable }, write: store.save)
            storagePaused = !persisted
            return persisted
        } catch {
            writable = false; observing = false; starts.cancel(); consenting = false
            health.stop(); stopRecording(); updateWakefulness()
            self.error = l("保存失败，已停止采集以保护数据，请不要退出应用：\(describe(error))")
            return false
        }
    }
    private func modify(_ id: UUID, _ action: (inout Episode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        action(&episodes[index]); reports = []; save()
    }
    func start() async {
        guard writable, archiveLoaded, !storagePaused, !busy, !demoMode, !observing,
              let request = starts.begin() else { return }
        consenting = true
        defer { if starts.finish(request) { consenting = false } }
        guard await audio.permissions() else {
            if starts.owns(request) { error = AudioCapture.CaptureError.permission.message(language: language) }; return
        }
        guard starts.owns(request), !demoMode, writable else { return }
        do {
            detector.reset(); largeDetector.reset(); captureGate.reset()
            let ready = try await health.start(onSample: { [weak self] in self?.ingest($0) }, onError: { [weak self] in self?.error = $0 })
            guard ready, starts.owns(request), !demoMode, writable else { return }
            observationStart = Date(); observing = true
            let window = ObservationWindow(start: Date()); journal.observations.append(window); activeObservationID = window.id
            save(); updateWakefulness()
            Task { await self.refreshMetrics(authorize: false) }
        } catch { if starts.owns(request) { self.error = describe(error) } }
    }
    func stop() {
        starts.cancel(); consenting = false
        if let id = activeObservationID, let i = journal.observations.firstIndex(where: { $0.id == id }) { journal.observations[i].end = Date() }
        activeObservationID = nil
        observing = false; observationStart = nil; health.stop(); detector.reset(); largeDetector.reset(); stopRecording()
        updateWakefulness(); save()
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            // Inactive also covers call UI and Control Center; keep the original session for recovery.
            if !recordingPaused { pauseRecording(note: "应用暂离前台，回到应用后可恢复录音。", automatic: true) }
            save()
        } else { resumeStorage(); resumeRecording(automatic: true); processPendingCleanup() }
        updateWakefulness()
    }
    private func ingest(_ sample: HeartSample) {
        guard observing, !demoMode, sample.bpm.isFinite, (30...240).contains(sample.bpm),
              sample.date >= (observationStart ?? .distantFuture),
              abs(Date().timeIntervalSince(sample.date)) <= 45 else { return }
        if sample.date >= (latestSampleAt ?? .distantPast) { latestBPM = sample.bpm; latestSampleAt = sample.date }
        let baseline = detector.currentBaseline
        let small = detector.ingest(sample), large = largeDetector.ingest(sample)
        appendHeart(sample, baseline: baseline)
        if let trigger = large ?? small { accept(trigger) }
        if Date().timeIntervalSince(lastContextRefresh) > 60 && !refreshingMetrics {
            Task { await self.refreshMetrics(authorize: false) }
        }
    }
    private func accept(_ trigger: Trigger) {
        guard observing, !demoMode, writable, !episodes.contains(where: { $0.id == trigger.id }) else { return }
        guard !episodes.contains(where: { !$0.isDemo && abs($0.trigger.date.timeIntervalSince(trigger.date)) < 2 && abs($0.trigger.bpm - trigger.bpm) < 1 }) else { return }
        appendHeart(.init(date: trigger.date, bpm: trigger.bpm), baseline: trigger.baseline, force: true)
        let assessment = ContextAlgorithm.assess(trigger, readings: metrics)
        let important = trigger.isLargeChange || (assessment.score >= 65 && assessment.coverage >= 0.8)
        if let owner = currentRecording, important, let start = owner.captureStarted, trigger.date >= start {
            var marker = Episode(trigger: trigger, status: .linked, note: "重要变化已关联到同一段录音。")
            marker.linkedRecordingID = owner.id
            marker.assessment = assessment
            episodes.append(marker); reports = []; save(); return
        }
        if busy && !important { return }
        let decision = captureGate.evaluate(trigger, now: Date(), activeSince: observationStart,
            foreground: foreground && UIApplication.shared.isProtectedDataAvailable,
            busy: busy, storageReady: archiveLoaded)
        let canCapture: Bool
        let reason: String
        switch decision {
        case .ignore: return
        case .record: canCapture = true; reason = ""
        case .missed(let message): canCapture = false; reason = message
        }
        var event = Episode(trigger: trigger, status: canCapture ? .recording : .missed,
                            note: canCapture ? "按本次设定时长录音；没有触发前语音。" : reason)
        event.assessment = assessment
        guard canCapture, let store, let operation = work.begin() else {
            episodes.append(event); reports = []; save(); return
        }
        let id = event.id
        recordingID = id; transcriptionCompleted = 0; transcriptionTotal = 0
        updateWakefulness(); player?.stop(); playingID = nil
        event.audioName = store.audioURL(id).lastPathComponent
        event.speechLanguage = language.resolved.rawValue
        event.maximumDuration = RecordingPolicy.duration(minutes: recordingMinutes)
        event.cleanupAfterTranscription = cleanupNewRecordings
        episodes.append(event); reports = []
        guard save() else {
            modify(id) { $0.status = .failed; $0.note = "档案暂不可写，未启动录音；解锁后重试保存。" }
            recordingID = nil; updateWakefulness(); work.finish(operation); return
        }
        do {
            try beginPart(id: id, operation: operation, first: true)
        } catch {
            modify(id) { $0.status = .failed; $0.note = describe(error) }
            recordingID = nil; recovery = nil; updateWakefulness(); work.finish(operation); self.error = describe(error)
        }
    }
    private func beginPart(id: UUID, operation: UUID, first: Bool) throws {
        guard let store else { throw AudioCapture.CaptureError.recording }
        let partID = UUID()
        let url = store.audioURL(first ? id : partID)
        let remaining = first ? (currentRecording?.maximumDuration ?? 3600) : (recovery?.remaining(at: Date()) ?? 0)
        guard remaining > 0 else { stopRecording(); return }
        let start = try audio.start(url: url, maximumDuration: remaining) { [weak self] result in
            self?.partFinished(id: id, partID: partID, operation: operation, result: result)
        }
        activePartID = partID
        if first {
            recovery = RecordingRecovery(startedAt: start, maximumDuration: remaining)
            recordingDeadline?.cancel()
            recordingDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard self?.recordingID == id else { return }
                self?.stopRecording()
            }
        } else { _ = recovery?.resumed(at: start) }
        modify(id) {
            if first { $0.captureStarted = start; $0.recordingParts = [] }
            $0.recordingParts?.append(.init(id: partID, audioName: url.lastPathComponent, startedAt: start))
            $0.status = .recording
            $0.note = first ? "按本次设定时长录音；没有触发前语音。" : "录音已恢复；中断空档没有声音，已保留真实时间轴。"
        }
        updateWakefulness()
    }
    private func partFinished(id: UUID, partID: UUID, operation: UUID, result: Result<AudioCapture.CapturedAudio, Error>) {
        guard recordingID == id, work.owns(operation), activePartID == partID else { return }
        activePartID = nil
        modify(id) { event in
            if let index = event.recordingParts?.firstIndex(where: { $0.id == partID }),
               let start = event.recordingParts?[index].startedAt {
                let end: Date
                switch result {
                case .success(let output): end = start.addingTimeInterval(output.duration)
                case .failure: end = Date()
                }
                event.recordingParts?[index].endedAt = end
            }
        }
        if case .failure(let error) = result {
            if recovery?.phase == .finished { finishRecording(id: id, operation: operation); return }
            recovery?.pause(automatic: false, manualOnly: true)
            modify(id) { $0.status = .paused; $0.note = describe(error) }
            updateWakefulness(); return
        }
        if recordingPaused { return }
        finishRecording(id: id, operation: operation)
    }
    private func pauseRecording(note: String, automatic: Bool, manualOnly: Bool = false) {
        guard let id = recordingID, recovery != nil else { return }
        recovery?.pause(automatic: automatic, manualOnly: manualOnly)
        audio.stop() // The completion saves this part but keeps the session and operation reserved.
        modify(id) { $0.status = .paused; $0.note = note }
        updateWakefulness()
    }
    func resumeRecording(automatic: Bool = false) {
        guard let id = recordingID, let operation = work.current, recordingPaused else { return }
        guard let recovery, recovery.remaining(at: Date()) > 0 else { stopRecording(); return }
        guard recovery.canResume(at: Date(), foreground: foreground,
            storageReady: writable && !storagePaused && UIApplication.shared.isProtectedDataAvailable,
            systemInterrupted: automatic && systemAudioInterrupted, automatic: automatic) else {
            if !automatic { error = l("请在音频中断结束后解锁并回到前台，再继续录音。") }; return
        }
        do { try beginPart(id: id, operation: operation, first: false); systemAudioInterrupted = false }
        catch {
            self.recovery?.pause(automatic: false, manualOnly: true)
            modify(id) { $0.status = .paused; $0.note = "自动续录未成功，请点击继续录音或结束并转写。" }
            if !automatic { self.error = describe(error) }
        }
    }
    func stopRecording() {
        guard let id = recordingID, let operation = work.current else { return }
        recovery?.finish()
        audio.stop()
        // If there is no active part (paused), there is no audio callback to finish the session.
        if recordingID == id { finishRecording(id: id, operation: operation) }
    }
    private func finishRecording(id: UUID, operation: UUID) {
        guard recordingID == id, work.owns(operation) else { return }
        recordingDeadline?.cancel(); recordingDeadline = nil
        recordingID = nil; activePartID = nil; recovery = nil; updateWakefulness()
        modify(id) { $0.captureEnded = Date(); $0.status = .transcribing }
        Task { await self.transcribe(id: id, operation: operation) }
    }
    private func transcribe(id: UUID, operation: UUID, force: Bool = false) async {
        guard work.owns(operation) else { return }
        transcriptionID = id
        defer { if transcriptionID == id { transcriptionID = nil }; work.finish(operation) }
        guard writable, UIApplication.shared.isProtectedDataAvailable else {
            modify(id) { $0.status = .failed; $0.note = "数据暂不可用，未转写；解锁后可手动重试。" }; return
        }
        guard let event = episodes.first(where: { $0.id == id }), event.audioPurgedAt == nil, let store else { return }
        let process = ProcessInfo.processInfo
        if !force && deferHeavyWork && (process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical) {
            modify(id) { $0.status = .deferred; $0.note = "已保留录音，因省电设置延后转写；可在处理中心手动继续。" }; return
        }
        modify(id) { $0.status = .transcribing; $0.transcriptionAttempted = true }
        guard writable else { return }
        let parts: [RecordingPart]
        if let saved = event.recordingParts, !saved.isEmpty { parts = saved }
        else if let name = event.audioName {
            parts = [.init(audioName: name, startedAt: event.captureStarted ?? event.trigger.date)]
        } else { modify(id) { $0.status = .failed }; return }
        var files = Dictionary((event.fileTranscripts ?? []).map { ($0.audioName, $0) }, uniquingKeysWith: { _, b in b })
        if files.isEmpty {
            for (index, part) in parts.enumerated() {
                let lower = part.startedAt.timeIntervalSince(event.captureStarted ?? part.startedAt)
                let upper = index + 1 < parts.count ? parts[index + 1].startedAt.timeIntervalSince(event.captureStarted ?? part.startedAt) : .infinity
                let old = event.segments.filter { $0.offset >= lower && $0.offset < upper }
                if !old.isEmpty || parts.count == 1 { files[part.audioName] = .init(audioName: part.audioName, text: parts.count == 1 ? event.transcript : old.map(\.text).joined(separator: " "), segments: old) }
            }
        }
        var failures = 0, successes = 0, finishedChunks = 0
        var lastFailure: String?
        var recoveredEnds: [UUID: Date] = [:]
        transcriptionCompleted = 0; transcriptionTotal = 0
        for part in parts {
            do {
                let url = store.directory.appendingPathComponent(part.audioName)
                if episodes.first(where: { $0.id == id })?.audioQuality == nil {
                    let sensitivity = audioSensitivity
                    let quality = await Task.detached(priority: .utility) { AudioQuality.analyze(url: url, sensitivity: sensitivity) }.value
                    modify(id) { $0.audioQuality = quality }
                }
                let result = try await audio.transcribe(url: url,
                    language: event.transcriptionLanguage, filterQuiet: filterQuietAudio && !force, sensitivity: audioSensitivity,
                    protectedOffsets: markers.filter { $0.recordingID == id }.map { $0.date.timeIntervalSince(part.startedAt) }
                        + journal.clips.filter { $0.recordingID == id && $0.confirmed }.map { $0.date.timeIntervalSince(part.startedAt) }) { [weak self] done, total in
                        self?.transcriptionCompleted = finishedChunks + done
                        self?.transcriptionTotal = finishedChunks + total
                    }
                journal.processing.removeAll { $0.recordingID == id && $0.audioName == part.audioName }
                journal.processing += result.spans.map { range, outcome in
                    ProcessingSpan(recordingID: id, audioName: part.audioName, start: part.startedAt.addingTimeInterval(range.lowerBound), end: part.startedAt.addingTimeInterval(range.upperBound), outcome: outcome)
                }
                successes += 1; failures += result.failedChunks
                if part.endedAt == nil, result.duration.isFinite, result.duration > 0 {
                    recoveredEnds[part.id] = part.startedAt.addingTimeInterval(result.duration)
                }
                let offset = part.startedAt.timeIntervalSince(event.captureStarted ?? part.startedAt)
                files[part.audioName] = .init(audioName: part.audioName, text: result.text,
                    segments: result.segments.map { .init(text: $0.text, offset: $0.offset + offset, duration: $0.duration) })
            } catch {
                failures += 1; lastFailure = describe(error)
                if let end = part.endedAt, end > part.startedAt {
                    journal.processing.removeAll { $0.recordingID == id && $0.audioName == part.audioName }
                    journal.processing.append(.init(recordingID: id, audioName: part.audioName, start: part.startedAt, end: end, outcome: .failed))
                }
            }
            finishedChunks = max(finishedChunks + 1, transcriptionTotal)
            guard work.owns(operation) else { return }
            // Checkpoint long jobs so a later suspension does not erase all completed text.
            modify(id) {
                if var parts = $0.recordingParts {
                    for index in parts.indices {
                        if let end = recoveredEnds[parts[index].id] { parts[index].endedAt = end }
                    }
                    $0.recordingParts = parts
                    if event.captureEnded == nil { $0.captureEnded = parts.compactMap(\.endedAt).max() }
                }
                // A failed retry must not erase previously saved successful text.
                if successes > 0 {
                    let ordered = parts.compactMap { files[$0.audioName] }
                    $0.fileTranscripts = ordered; $0.transcript = ordered.map(\.text).joined(separator: "\n")
                    $0.segments = ordered.flatMap(\.segments).sorted { $0.offset < $1.offset }
                }
                $0.failedTranscriptionChunks = failures
            }
        }
        let skippedAny = journal.processing.contains { $0.recordingID == id && $0.outcome == .skipped }
        modify(id) {
            $0.status = successes == 0 ? .failed : (failures > 0 || skippedAny ? .partial : .ready)
            $0.note = successes == 0 ? (lastFailure ?? "本地转写未成功，原始录音仍保留，可稍后重试。") : failures > 0 ? "部分片段转写失败，可保留原音频后重试。" : (files.values.allSatisfy { $0.text.isEmpty } ? "未识别到可用语音。" : "本地转写完成。请核对文字，心率变化不等于情绪变化。")
        }
        if skippedAny { modify(id) { $0.note = "部分片段未检出语音而跳过，原音频保留；手动重试会完整识别。" } }
        work.finish(operation)
        if !skippedAny && successes == parts.count && failures == 0 && event.cleanupAfterTranscription == true {
            requestCleanup(id)
        }
    }
    func retry(_ event: Episode) async {
        guard writable, archiveLoaded, !storagePaused, !event.isDemo,
              episodes.contains(where: { $0.id == event.id }), !event.audioNames.isEmpty, event.audioPurgedAt == nil,
              let operation = work.begin() else { return }
        // Reserve before the first suspension; duplicate taps and heart triggers now see busy=true.
        defer { work.finish(operation) }
        guard await audio.permissions() else { error = AudioCapture.CaptureError.permission.message(language: language); return }
        guard work.owns(operation) else { return }
        await transcribe(id: event.id, operation: operation, force: true)
    }
    private func updateWakefulness() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && foreground && (observing || recordingID != nil)
    }
    private func appendHeart(_ sample: HeartSample, baseline: Double?, force: Bool = false) {
        if let index = heartPoints.firstIndex(where: { !$0.isDemo && abs($0.sample.date.timeIntervalSince(sample.date)) < 0.2 }) {
            if force { heartPoints[index] = .init(sample: sample, baseline: baseline) }
            return
        }
        if !force, let last = heartPoints.last(where: { !$0.isDemo }), sample.date.timeIntervalSince(last.sample.date) < 5 { return }
        heartPoints.append(.init(sample: sample, baseline: baseline))
        if force { heartPoints.sort { $0.sample.date < $1.sample.date } }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        heartPoints.removeAll { $0.sample.date < cutoff }
        if heartPoints.count > 60000 { heartPoints.removeFirst(heartPoints.count - 60000) }
        if Date().timeIntervalSince(lastSeriesSave) > 60 { lastSeriesSave = Date(); save() }
    }
    func refreshMetrics(authorize: Bool = true) async {
        guard !refreshingMetrics, !demoMode, let request = contextRefresh.begin() else { return }
        refreshingMetrics = true; lastContextRefresh = Date()
        defer { if contextRefresh.finish(request) { refreshingMetrics = false } }
        do {
            let rows = try await health.context(authorize: authorize)
            guard contextRefresh.owns(request), writable, archiveLoaded else { return }
            var combined = Dictionary(metrics.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for row in rows where row.kind.accepts(row.value) { combined[row.id] = row }
            let recent = combined.values.filter { $0.date >= Date().addingTimeInterval(-14 * 86400) }
            metrics = Dictionary(grouping: recent, by: \.kind).values.flatMap { $0.sorted { $0.date > $1.date }.prefix(500) }.sorted { $0.date < $1.date }
            save()
        } catch { self.error = describe(error) }
    }
    func requestCleanup(_ id: UUID) {
        guard canWriteArchive, !busy, recordingID == nil,
              let event = episodes.first(where: { $0.id == id }), !event.isDemo,
              event.status == .ready, event.cleanupAfterTranscription == true,
              event.audioPurgedAt == nil, !event.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (event.failedTranscriptionChunks ?? 0) == 0 else { return }
        modify(id) { $0.cleanupPending = true }
        processPendingCleanup()
    }
    func processPendingCleanup() {
        guard canWriteArchive, !busy, foreground, recordingID == nil, playingID == nil, let store else { return }
        for event in episodes where event.cleanupPending == true && event.audioPurgedAt == nil && event.status == .ready && event.cleanupAfterTranscription == true && !event.isDemo && !event.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (event.failedTranscriptionChunks ?? 0) == 0 {
            guard save() else { return } // Pending state and transcript must be durable before removing any file.
            if event.cleanupStartedAt == nil {
                modify(event.id) { $0.cleanupStartedAt = Date() }
                guard canWriteArchive else { return }
            }
            do {
                for name in event.audioNames { try store.deleteAudio(name) }
                modify(event.id) { $0.audioPurgedAt = Date(); $0.cleanupPending = false }
                guard canWriteArchive else { return }
            } catch { self.error = l("音频清理未完成，已保留文字和待处理状态：\(describe(error))"); return }
        }
    }
    func cancelCleanup(_ id: UUID) {
        guard canWriteArchive, episodes.first(where: { $0.id == id })?.cleanupStartedAt == nil else { return }
        modify(id) { $0.cleanupPending = false; $0.cleanupAfterTranscription = false }
    }
    func confirm(_ id: UUID, feeling: String) { modify(id) { $0.feeling = feeling } }
    @discardableResult func markMoment() -> UUID? {
        guard writable, archiveLoaded, !storagePaused, foreground, !demoMode,
              let owner = currentRecording, let start = owner.captureStarted,
              recovery?.phase != .finished, Date() >= start else { return nil }
        let marker = MomentMarker(date: Date(), recordingID: owner.id)
        markers.append(marker)
        if save() { lastMarkedID = marker.id; return marker.id }
        // Keep the unsaved marker in memory if protected storage became unavailable.
        return nil
    }
    func updateMarker(_ id: UUID, note: String) {
        guard writable, archiveLoaded, !storagePaused, let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].note = String(note.prefix(500)); reports = []; save()
    }
    func deleteMarker(_ id: UUID) {
        guard writable, archiveLoaded, !storagePaused else { return }
        markers.removeAll { $0.id == id }; reports = []; save()
    }
    func playMarker(_ marker: MomentMarker) {
        guard recordingID == nil, markers.contains(where: { $0.id == marker.id }) else { return }
        if playingID == marker.id { player?.stop(); playingID = nil; return }
        guard marker.owner(in: episodes)?.cleanupPending != true, let location = marker.audioLocation(in: episodes) else {
            error = l("此事件发生在录音中断的空档，没有对应音频。"); return
        }
        playAudio(location, eventID: marker.id)
    }
    func playEvidence(at date: Date, recordingID: UUID, playbackID: UUID) {
        guard self.recordingID == nil, let owner = visible.first(where: { $0.id == recordingID }), owner.cleanupPending != true else { return }
        if playingID == playbackID { player?.stop(); playingID = nil; return }
        guard let location = RecordingTimeline.location(at: date, in: owner) else {
            error = l("此位置没有可播放音频，可能处于空档或原音频已清理。"); return
        }
        playAudio(location, eventID: playbackID)
    }
    func play(_ event: Episode) {
        guard recordingID == nil else { return }
        if playingID == event.id { player?.stop(); playingID = nil; return }
        guard recordingOwner(event)?.audioNames.isEmpty == false, recordingOwner(event)?.audioPurgedAt == nil, recordingOwner(event)?.cleanupPending != true else { return }
        guard let location = event.audioLocation(in: episodes) else {
            error = l("此事件发生在录音中断的空档，没有对应音频。"); return
        }
        playAudio(location, eventID: event.id)
    }
    func playPart(_ part: RecordingPart, eventID: UUID) {
        guard recordingID == nil, episodes.first(where: { $0.id == eventID })?.audioPurgedAt == nil, episodes.first(where: { $0.id == eventID })?.cleanupPending != true else { return }
        playAudio(AudioLocation(audioName: part.audioName, offset: 0), eventID: eventID)
    }
    private func playAudio(_ location: AudioLocation, eventID: UUID) {
        guard let store else { return }
        do {
            player?.stop(); playingID = nil
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: store.directory.appendingPathComponent(location.audioName))
            guard location.offset < next.duration else {
                error = l("该标记超出实际录音范围，未找到对应音频。"); return
            }
            next.currentTime = location.offset
            guard next.play() else { throw AudioCapture.CaptureError.recording }
            player = next; playingID = eventID
        } catch { self.error = describe(error) }
    }
    func delete(_ event: Episode) {
        guard !busy, writable, !storagePaused, archiveLoaded else { return }
        do {
            for name in event.audioNames { try store?.deleteAudio(name) }
            player?.stop(); playingID = nil
            episodes.removeAll { $0.id == event.id || $0.linkedRecordingID == event.id }
            markers.removeAll { $0.recordingID == event.id }; journal.reconcile(episodes: episodes); reports = []; save()
        } catch { self.error = l("删除音频失败：\(describe(error))") }
    }
    func erase() {
        guard !busy, writable, !storagePaused, archiveLoaded else { return }
        stop(); contextRefresh.cancel(); refreshingMetrics = false; player?.stop(); playingID = nil
        do {
            for event in episodes { for name in event.audioNames { try store?.deleteAudio(name) } }
            episodes = []; markers = []; journal = JournalCollection(); lastMarkedID = nil; reports = []; heartPoints = []; metrics = []; demoMetrics = []; save()
        } catch { self.error = l("清除未完成：\(describe(error))") }
    }
    func summarize() async {
        guard !summarizing, !summaryEvidenceIDs.isEmpty, !busy else { return }
        summarizing = true; summaryDay = selectedDay; summaryFailure = nil
        defer { summarizing = false }
        let events = dayEvents; let recordings = visible; let day = selectedDay; let snapshot = revision
        do {
            var report: DailyReport
            if demoMode { report = Insights.report(day: day, events: events, language: language, recordings: recordings, markers: visibleMarkers, clips: visibleClips) }
            else { report = try await LocalIntelligence.summarize(day: day, events: events, language: language.resolved, recordings: recordings, markers: visibleMarkers, clips: visibleClips, memories: visibleMemories.filter { $0.enabled && journal.memoryHasSources($0) }, coverage: coverage) }
            guard revision == snapshot, events.map(\.id) == Insights.events(on: day, from: visible).map(\.id), !busy else { return }
            reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: day) }
            let amount = coverage
            report.text += l("\n覆盖快照：录音 \(Int(amount.recorded)) 秒，成功处理 \(Int(amount.processed)) 秒，失败 \(Int(amount.failed)) 秒，跳过 \(Int(amount.skipped)) 秒；未记录生活保持未知。")
            reports.append(report); save()
        } catch { summaryFailure = describe(error); self.error = l("端侧模型暂不可用：\(describe(error))。可使用规则摘要或稍后重试。") }
    }
    func ruleSummary() {
        guard !summaryEvidenceIDs.isEmpty, !busy, !summarizing else { return }
        summaryFailure = nil; summaryDay = selectedDay
        reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
        var report = Insights.report(day: selectedDay, events: dayEvents, language: language, recordings: visible, markers: visibleMarkers, clips: visibleClips)
        let amount = coverage
        report.text += l("\n覆盖快照：录音 \(Int(amount.recorded)) 秒，成功处理 \(Int(amount.processed)) 秒，失败 \(Int(amount.failed)) 秒，跳过 \(Int(amount.skipped)) 秒；未记录生活保持未知。")
        reports.append(report); save()
    }
    func loadDemo() {
        guard !busy, archiveLoaded else { return }
        stop(); contextRefresh.cancel(); refreshingMetrics = false; demoMode = true; selectedDay = Date()
        episodes.removeAll(where: { $0.isDemo }); markers.removeAll { $0.isDemo }; heartPoints.removeAll { $0.isDemo }
        journal.clips.removeAll { $0.isDemo }; journal.people.removeAll { $0.isDemo }; journal.memories.removeAll { $0.isDemo }
        journal.reflections.removeAll { $0.isDemo }; journal.plans.removeAll { $0.isDemo }
        demoMetrics = MetricKind.allCases.enumerated().map { index, kind in
            MetricReading(kind: kind, value: [98, 45, 35, 48, 65, 82, 3, 34.2][index], date: Date(), source: "demo")
        }
        for seconds in stride(from: -6000, through: 0, by: 20) {
            let value = 76 + 8 * sin(Double(seconds) / 130) + 3 * cos(Double(seconds) / 47)
            heartPoints.append(.init(sample: .init(date: Date().addingTimeInterval(Double(seconds)), bpm: value), baseline: 76, isDemo: true))
        }
        let texts = [l("今天要讲这个方案，我有点紧张，先把重点说清楚。"), l("刚散步回来，和朋友聊得很开心。"), l("今天有点累了，今晚早点休息。") ]
        for index in 0..<3 {
            let date = Date().addingTimeInterval(Double(index - 3) * 1800)
            var event = Episode(trigger: Trigger(date: date, bpm: Double(103 + index * 5), baseline: 74), status: .ready, note: "模拟数据，不来自传感器或真实录音。", isDemo: true)
            event.captureStarted = date.addingTimeInterval(1); event.captureEnded = date.addingTimeInterval(20)
            event.assessment = ContextAlgorithm.assess(event.trigger, readings: demoMetrics)
            event.transcript = texts[index]
            event.speechLanguage = language.resolved.rawValue
            event.segments = [.init(text: texts[index], offset: 0, duration: 8)]
            heartPoints.append(.init(sample: .init(date: date, bpm: event.trigger.bpm), baseline: 74, isDemo: true))
            episodes.append(event)
        }
        if let owner = episodes.last(where: { $0.isDemo }) {
            markers.append(.init(date: owner.trigger.date.addingTimeInterval(5), recordingID: owner.id, note: l("模拟人工标记：值得回顾的片刻"), isDemo: true))
        }
        heartPoints.sort { $0.sample.date < $1.sample.date }
        reports = []; summaryFailure = nil; summaryDay = nil; save()
    }
    func exitDemo() { demoMode = false; selectedDay = Date(); reports = []; summaryFailure = nil; summaryDay = nil; save() }
}
