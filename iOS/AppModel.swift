import SwiftUI
import WatchMindCore
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published var episodes: [Episode] = []
    @Published var reports: [DailyReport] = []
    @Published var observing = false
    @Published var foreground = true
    @Published var busy = false
    @Published var summarizing = false
    @Published var latestBPM: Double?
    @Published var latestSampleAt: Date?
    @Published var error: String?
    @Published var demoMode = false
    @Published var consenting = false
    @Published var recordingID: UUID?
    @Published var playingID: UUID?
    @Published var selectedDay = Date()
    private let audio = AudioCapture()
    private let health = HealthSource()
    private let receiver = WatchReceiver()
    private var store: LocalStore?
    private var detector = HeartDetector()
    private var player: AVAudioPlayer?
    private var observationStart: Date?
    private var lastTriggerDate: Date?
    private var interruptionToken: NSObjectProtocol?
    private var writable = true
    private var revision = 0

    var visible: [Episode] { episodes.filter { $0.isDemo == demoMode } }
    var dayEvents: [Episode] { Insights.events(on: selectedDay, from: visible) }
    var report: DailyReport? {
        reports.last { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) && $0.episodeIDs == dayEvents.map(\.id) }
    }
    init() {
        do {
            let store = try LocalStore(); self.store = store
            let archive = try store.load(); episodes = archive.episodes; reports = archive.reports
            // A terminated recording is never silently resumed.
            for index in episodes.indices where [.recording, .transcribing].contains(episodes[index].status) {
                episodes[index].status = .failed; episodes[index].note = "上次任务被中断。可手动重试本地转写。"
            }
            save()
        } catch {
            writable = false
            self.error = "无法读取本地档案，已停止写入以保护原文件：\(error.localizedDescription)"
        }
        receiver.onSample = { [weak self] sample in self?.ingest(sample) }
        receiver.onTrigger = { [weak self] trigger in self?.accept(trigger) }
        receiver.activate()
        interruptionToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audio.stop() }
        }
    }
    private func save() {
        guard writable, let store else { return }
        do { try store.save(Archive(episodes: episodes, reports: reports)); revision += 1 }
        catch {
            writable = false; observing = false; health.stop(); audio.stop()
            self.error = "保存失败，已停止采集以保护数据，请不要退出应用：\(error.localizedDescription)"
        }
    }
    private func modify(_ id: UUID, _ action: (inout Episode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        action(&episodes[index]); reports = []; save()
    }
    func start() async {
        guard writable, !busy, !demoMode, !observing else { return }
        consenting = true
        defer { consenting = false }
        guard await audio.permissions() else { error = AudioCapture.CaptureError.permission.localizedDescription; return }
        do {
            detector.reset(); observationStart = Date(); lastTriggerDate = nil
            try await health.start(onSample: { [weak self] in self?.ingest($0) }, onError: { [weak self] in self?.error = $0 })
            observing = true
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        observing = false; health.stop(); audio.stop(); detector.reset(); observationStart = nil
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { audio.stop() }
    }
    private func ingest(_ sample: HeartSample) {
        guard observing, !demoMode, sample.date >= (observationStart ?? .distantFuture),
              abs(Date().timeIntervalSince(sample.date)) <= 45 else { return }
        if sample.date >= (latestSampleAt ?? .distantPast) { latestBPM = sample.bpm; latestSampleAt = sample.date }
        if let trigger = detector.ingest(sample) { accept(trigger) }
    }
    private func accept(_ trigger: Trigger) {
        guard observing, !demoMode, writable, trigger.date >= (observationStart ?? .distantFuture),
              !episodes.contains(where: { $0.id == trigger.id }),
              trigger.bpm.isFinite, trigger.baseline.isFinite,
              (30...240).contains(trigger.bpm), (30...240).contains(trigger.baseline),
              trigger.date.timeIntervalSinceNow <= 5 else { return }
        // Deduplicate phone and Watch detections of the same physiological episode.
        if let lastTriggerDate, abs(trigger.date.timeIntervalSince(lastTriggerDate)) < 180 { return }
        lastTriggerDate = trigger.date
        let fresh = Date().timeIntervalSince(trigger.date) <= 15
        let canCapture = fresh && foreground && !busy && store != nil
        let reason = !fresh ? "事件延迟到达，未补录当时的语音。" : (!foreground ? "手机不在前台，未自动启动麦克风。" : "录音或转写繁忙，未开始新录音。")
        var event = Episode(trigger: trigger, status: canCapture ? .recording : .missed, note: canCapture ? "触发后录音，最多30秒；没有触发前语音。" : reason)
        guard canCapture, let store else { episodes.append(event); reports = []; save(); return }
        busy = true; recordingID = event.id
        player?.stop(); playingID = nil
        event.captureStarted = Date(); event.audioName = store.audioURL(event.id).lastPathComponent
        episodes.append(event); reports = []; save()
        guard writable else { busy = false; recordingID = nil; return }
        do {
            try audio.start(url: store.audioURL(event.id)) { [weak self] result in
                guard let self else { return }
                self.recordingID = nil
                switch result {
                case .success(let url): Task { await self.transcribe(id: event.id, url: url) }
                case .failure(let error):
                    self.modify(event.id) { $0.status = .failed; $0.note = error.localizedDescription }; self.busy = false
                }
            }
        } catch {
            modify(event.id) { $0.status = .failed; $0.note = error.localizedDescription }
            recordingID = nil; busy = false; self.error = error.localizedDescription
        }
    }
    func stopRecording() { audio.stop() }
    private func transcribe(id: UUID, url: URL) async {
        busy = true; modify(id) { $0.status = .transcribing }
        defer { busy = false }
        do {
            let (text, segments) = try await audio.transcribe(url: url)
            modify(id) {
                $0.transcript = text; $0.segments = segments; $0.status = .ready
                $0.note = text.isEmpty ? "未识别到可用语音。" : "本地转写完成。请核对文字，心率变化不等于情绪变化。"
            }
        } catch { modify(id) { $0.status = .failed; $0.note = error.localizedDescription } }
    }
    func retry(_ event: Episode) async {
        guard !busy, !event.isDemo, let store, let name = event.audioName else { return }
        guard await audio.permissions() else { error = AudioCapture.CaptureError.permission.localizedDescription; return }
        await transcribe(id: event.id, url: store.directory.appendingPathComponent(name))
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
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ event: Episode) {
        guard !busy, writable else { return }
        do {
            if let name = event.audioName { try store?.deleteAudio(name) }
            player?.stop(); playingID = nil
            episodes.removeAll { $0.id == event.id }; reports = []; save()
        } catch { self.error = "删除音频失败：\(error.localizedDescription)" }
    }
    func erase() {
        guard !busy, writable else { return }
        stop(); player?.stop(); playingID = nil
        do {
            for event in episodes { if let name = event.audioName { try store?.deleteAudio(name) } }
            episodes = []; reports = []; save()
        } catch { self.error = "清除未完成：\(error.localizedDescription)" }
    }
    func summarize() async {
        guard !summarizing, !dayEvents.isEmpty else { return }
        summarizing = true; defer { summarizing = false }
        let events = dayEvents; let day = selectedDay; let snapshot = revision
        do {
            let report: DailyReport
            if demoMode { report = Insights.report(day: day, events: events) }
            else { report = try await LocalIntelligence.summarize(day: day, events: events) }
            // Discard a result whose evidence changed while the model was generating.
            guard revision == snapshot, events.map(\.id) == Insights.events(on: day, from: visible).map(\.id), !busy else { return }
            reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: day) }
            reports.append(report); save()
        } catch { self.error = "端侧模型暂不可用：\(error.localizedDescription)。可关闭模型或稍后重试。" }
    }
    func ruleSummary() {
        guard !dayEvents.isEmpty else { return }
        reports.removeAll { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
        reports.append(Insights.report(day: selectedDay, events: dayEvents)); save()
    }
    func loadDemo() {
        guard !busy else { return }
        stop(); demoMode = true; selectedDay = Date()
        episodes.removeAll( where: { $0.isDemo })
        let texts = ["今天要讲这个方案，我有点紧张，先把重点说清楚。", "刚散步回来，和朋友聊得很开心。", "今天有点累了，今晚早点休息。"]
        for index in 0..<3 {
            let date = Date().addingTimeInterval(Double(index - 3) * 1800)
            var event = Episode(trigger: Trigger(date: date, bpm: Double(103 + index * 5), baseline: 74), status: .ready, note: "模拟数据，不来自传感器或真实录音。", isDemo: true)
            event.captureStarted = date.addingTimeInterval(1); event.transcript = texts[index]
            event.segments = [.init(text: texts[index], offset: 0, duration: 8)]
            episodes.append(event)
        }
        reports = []; save()
    }
    func exitDemo() { demoMode = false; selectedDay = Date(); reports = []; save() }
}
