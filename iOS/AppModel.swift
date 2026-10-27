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
    private var l: Localizer { Localizer(language: language) }
    private func describe(_ error: Error) -> String {
        (error as? AudioCapture.CaptureError)?.message(language: language) ?? l.key(error.localizedDescription)
    }
    @Published var episodes: [Episode] = []
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
    var visible: [Episode] { episodes.filter { $0.isDemo == demoMode } }
    var dayEvents: [Episode] { Insights.events(on: selectedDay, from: visible) }
    var report: DailyReport? {
        reports.last { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) && $0.episodeIDs == dayEvents.map(\.id) && ($0.language ?? "zh-Hans") == language.resolved.rawValue }
    }
    init() {
        resumeStorage()
        receiver.onSample = { [weak self] sample in self?.ingest(sample) }
        receiver.onTrigger = { [weak self] trigger in self?.accept(trigger) }
        receiver.setLanguage(language.rawValue)
        receiver.activate()
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.audio.interrupt() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.storagePaused = true; self?.audio.interrupt() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeStorage() }
        })
    }
    deinit { notificationTokens.forEach { NotificationCenter.default.removeObserver($0) } }

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
                archiveLoaded = true
                for index in episodes.indices where [.recording, .transcribing].contains(episodes[index].status) {
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
    @discardableResult private func save() -> Bool {
        // Invalidate in-flight summaries even when disk persistence is deferred.
        revision += 1
        guard writable, archiveLoaded, let store else { return false }
        do {
            let persisted = try archiveWriter.save(Archive(episodes: episodes, reports: reports),
                isAvailable: { UIApplication.shared.isProtectedDataAvailable }, write: store.save)
            storagePaused = !persisted
            return persisted
        } catch {
            writable = false; observing = false; starts.cancel(); consenting = false
            health.stop(); audio.interrupt()
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
            detector.reset(); captureGate.reset()
            let ready = try await health.start(onSample: { [weak self] in self?.ingest($0) }, onError: { [weak self] in self?.error = $0 })
            guard ready, starts.owns(request), !demoMode, writable else { return }
            observationStart = Date(); observing = true
        } catch { if starts.owns(request) { self.error = describe(error) } }
    }
    func stop() {
        starts.cancel(); consenting = false
        observing = false; observationStart = nil; health.stop(); detector.reset(); audio.stop()
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { audio.stop() } else { resumeStorage() }
    }
    private func ingest(_ sample: HeartSample) {
        guard observing, !demoMode, sample.bpm.isFinite, (30...240).contains(sample.bpm),
              sample.date >= (observationStart ?? .distantFuture),
              abs(Date().timeIntervalSince(sample.date)) <= 45 else { return }
        if sample.date >= (latestSampleAt ?? .distantPast) { latestBPM = sample.bpm; latestSampleAt = sample.date }
        if let trigger = detector.ingest(sample) { accept(trigger) }
    }
    private func accept(_ trigger: Trigger) {
        guard observing, !demoMode, writable, !episodes.contains(where: { $0.id == trigger.id }) else { return }
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
                            note: canCapture ? "触发后录音，最多30秒；没有触发前语音。" : reason)
        guard canCapture, let store, let operation = work.begin() else {
            episodes.append(event); reports = []; save(); return
        }
        let id = event.id
        recordingID = id; player?.stop(); playingID = nil
        event.audioName = store.audioURL(id).lastPathComponent
        event.speechLanguage = language.resolved.rawValue
        episodes.append(event); reports = []
        guard save() else {
            modify(id) { $0.status = .failed; $0.note = "档案暂不可写，未启动录音；解锁后重试保存。" }
            recordingID = nil; work.finish(operation); return
        }
        do {
            let startedAt = try audio.start(url: store.audioURL(id)) { [weak self] result in
                guard let self, self.work.owns(operation) else { return }
                self.recordingID = nil
                switch result {
                case .success(let url): Task { await self.transcribe(id: id, url: url, operation: operation) }
                case .failure(let error):
                    self.modify(id) { $0.status = .failed; $0.note = self.describe(error) }
                    self.work.finish(operation)
                }
            }
            modify(id) { $0.captureStarted = startedAt }
        } catch {
            modify(id) { $0.status = .failed; $0.note = describe(error) }
            recordingID = nil; work.finish(operation); self.error = describe(error)
        }
    }
    func stopRecording() { audio.stop() }
    private func transcribe(id: UUID, url: URL, operation: UUID) async {
        guard work.owns(operation) else { return }
        defer { work.finish(operation) }
        guard writable, UIApplication.shared.isProtectedDataAvailable else {
            modify(id) { $0.status = .failed; $0.note = "数据暂不可用，未转写；解锁后可手动重试。" }; return
        }
        modify(id) { $0.status = .transcribing }
        guard writable else { return }
        do {
            let (text, segments) = try await audio.transcribe(url: url, language: episodes.first(where: { $0.id == id })?.transcriptionLanguage ?? language.resolved)
            guard work.owns(operation) else { return }
            modify(id) {
                $0.transcript = text; $0.segments = segments; $0.status = .ready
                $0.note = text.isEmpty ? "未识别到可用语音。" : "本地转写完成。请核对文字，心率变化不等于情绪变化。"
            }
        } catch { modify(id) { $0.status = .failed; $0.note = describe(error) } }
    }
    func retry(_ event: Episode) async {
        guard writable, archiveLoaded, !storagePaused, !event.isDemo,
              episodes.contains(where: { $0.id == event.id }), let store, let name = event.audioName,
              let operation = work.begin() else { return }
        // Reserve before the first suspension; duplicate taps and heart triggers now see busy=true.
        defer { work.finish(operation) }
        guard await audio.permissions() else { error = AudioCapture.CaptureError.permission.message(language: language); return }
        guard work.owns(operation) else { return }
        await transcribe(id: event.id, url: store.directory.appendingPathComponent(name), operation: operation)
    }
    func confirm(_ id: UUID, feeling: String) { modify(id) { $0.feeling = feeling } }
    func play(_ event: Episode) {
        guard !busy else { return }
        if playingID == event.id { player?.stop(); playingID = nil; return }
        guard let name = event.audioName, let store else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: store.directory.appendingPathComponent(name))
            player?.play(); playingID = event.id
        } catch { self.error = describe(error) }
    }
    func delete(_ event: Episode) {
        guard !busy, writable, !storagePaused, archiveLoaded else { return }
        do {
            if let name = event.audioName { try store?.deleteAudio(name) }
            player?.stop(); playingID = nil
            episodes.removeAll { $0.id == event.id }; reports = []; save()
        } catch { self.error = l("删除音频失败：\(describe(error))") }
    }
    func erase() {
        guard !busy, writable, !storagePaused, archiveLoaded else { return }
        stop(); player?.stop(); playingID = nil
        do {
            for event in episodes { if let name = event.audioName { try store?.deleteAudio(name) } }
            episodes = []; reports = []; save()
        } catch { self.error = l("清除未完成：\(describe(error))") }
    }
    func summarize() async {
        guard !summarizing, !dayEvents.isEmpty else { return }
        summarizing = true; defer { summarizing = false }
        let events = dayEvents; let day = selectedDay; let snapshot = revision
        do {
            let report: DailyReport
            if demoMode { report = Insights.report(day: day, events: events, language: language) }
            else { report = try await LocalIntelligence.summarize(day: day, events: events, language: language.resolved) }
            guard revision == snapshot, events.map(\.id) == Insights.events(on: day, from: visible).map(\.id), !busy else { return }
            reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: day) }
            reports.append(report); save()
        } catch { self.error = l("端侧模型暂不可用：\(describe(error))。可使用规则摘要或稍后重试。") }
    }
    func ruleSummary() {
        guard !dayEvents.isEmpty else { return }
        reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
        reports.append(Insights.report(day: selectedDay, events: dayEvents, language: language)); save()
    }
    func loadDemo() {
        guard !busy, archiveLoaded else { return }
        stop(); demoMode = true; selectedDay = Date()
        episodes.removeAll(where: { $0.isDemo })
        let texts = [l("今天要讲这个方案，我有点紧张，先把重点说清楚。"), l("刚散步回来，和朋友聊得很开心。"), l("今天有点累了，今晚早点休息。") ]
        for index in 0..<3 {
            let date = Date().addingTimeInterval(Double(index - 3) * 1800)
            var event = Episode(trigger: Trigger(date: date, bpm: Double(103 + index * 5), baseline: 74), status: .ready, note: "模拟数据，不来自传感器或真实录音。", isDemo: true)
            event.captureStarted = date.addingTimeInterval(1); event.transcript = texts[index]
            event.speechLanguage = language.resolved.rawValue
            event.segments = [.init(text: texts[index], offset: 0, duration: 8)]
            episodes.append(event)
        }
        reports = []; save()
    }
    func exitDemo() { demoMode = false; selectedDay = Date(); reports = []; save() }
}
