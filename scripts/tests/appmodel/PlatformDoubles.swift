// Platform stand-ins exercise AppModel orchestration on Linux. They do not validate Apple SDK behavior.
import Foundation
import WatchMindCore
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
protocol ObservableObject {}
enum ScenarioDefaults {
    static let name = "watchmind-tests-" + UUID().uuidString
    static let store = UserDefaults(suiteName: name)!
}
@MainActor class UIApplication {
    static let shared = UIApplication()
    var isProtectedDataAvailable = true
    var isIdleTimerDisabled = false
    nonisolated static let protectedDataWillBecomeUnavailableNotification = Notification.Name("willLock")
    nonisolated static let protectedDataDidBecomeAvailableNotification = Notification.Name("didUnlock")
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"
class AVAudioSession {
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    struct InterruptionOptions: OptionSet { var rawValue: UInt; static let shouldResume = Self(rawValue: 1) }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2 }
    enum Category { case playback }
    enum Mode { case spokenAudio }
    static let interruptionNotification = Notification.Name("audio")
    static let routeChangeNotification = Notification.Name("route")
    static let mediaServicesWereResetNotification = Notification.Name("reset")
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    func setCategory(_ value: Category, mode: Mode) throws {}
    func setActive(_ active: Bool) throws {}
}
class AVAudioPlayer {
    init(contentsOf: URL) throws {}
    var currentTime: Double = 0
    var duration: Double = 3600
    func play() -> Bool { true }
    func stop() {}
}
@MainActor class AudioCapture {
    static var latest: AudioCapture?
    var starts = 0
    var failNextStart = false
    var failTranscription = false
    var partialTranscription = false
    var simulateSkip = false
    var lastFilter = false
    var failingNames: Set<String> = []
    var completion: ((Result<CapturedAudio, Error>) -> Void)?
    var oldCompletion: ((Result<CapturedAudio, Error>) -> Void)?
    var startDate = Date()
    var currentURL = URL(fileURLWithPath: "/tmp/fake.m4a")
    init() { Self.latest = self }
    enum CaptureError: Error {
        case permission, recording
        func message(language: AppLanguage) -> String { "fake capture error" }
    }
    struct CapturedAudio { var url: URL; var duration: TimeInterval }
    func stop() {
        guard let callback = completion else { return }
        completion = nil; oldCompletion = callback
        callback(.success(.init(url: currentURL, duration: max(0.001, Date().timeIntervalSince(startDate)))))
    }
    func permissions() async -> Bool { true }
    func start(url: URL, maximumDuration: TimeInterval, completion: @escaping (Result<CapturedAudio, Error>) -> Void) throws -> Date {
        if failNextStart { failNextStart = false; throw CaptureError.recording }
        precondition(self.completion == nil, "Never open a duplicate microphone")
        starts += 1; self.completion = completion; startDate = Date(); currentURL = url
        return startDate
    }
    struct TranscriptionResult { var text: String; var segments: [TranscriptSegment]; var failedChunks: Int; var duration: TimeInterval; var spans: [(Range<Double>, ProcessingSpan.Outcome)] }
    func transcribe(url: URL, language: AppLanguage, filterQuiet: Bool = false, sensitivity: Int = 3, protectedOffsets: [Double] = [], progress: @escaping @MainActor (Int, Int) -> Void) async throws -> TranscriptionResult {
        lastFilter = filterQuiet
        if simulateSkip && filterQuiet && protectedOffsets.isEmpty { return .init(text: "", segments: [], failedChunks: 0, duration: 60, spans: [(0..<60, .skipped)]) }
        if failTranscription || failingNames.contains(url.lastPathComponent) { throw CaptureError.recording }
        progress(1, 1)
        return .init(text: "saved text", segments: [.init(text: "saved text", offset: 0, duration: 0.001)], failedChunks: partialTranscription ? 1 : 0, duration: 60, spans: partialTranscription ? [(0..<30, .recognized), (30..<60, .failed)] : [(0..<60, .recognized)])
    }
}
@MainActor class HealthSource {
    func context(authorize: Bool) async throws -> [MetricReading] { [] }
    func start(onSample: @escaping (HeartSample) -> Void, onError: @escaping (String) -> Void) async throws -> Bool { true }
    func stop() {}
}
@MainActor class WatchReceiver {
    static var latest: WatchReceiver?
    var onSample: ((HeartSample) -> Void)?
    var onTrigger: ((Trigger) -> Void)?
    var onConnection: ((Bool) -> Void)?
    init() { Self.latest = self }
    func setLanguage(_ value: String) {}
    func activate() {}
}
typealias Archive = JournalArchive
@MainActor class LocalStore {
    static var archive = Archive()
    static var failSave = false
    static var failDelete = false
    static var deletedNames: [String] = []
    var directory = URL(fileURLWithPath: "/tmp")
    init() throws {}
    func load() throws -> Archive { Self.archive }
    func save(_ archive: Archive) throws {
        if Self.failSave { throw CocoaError(.fileWriteOutOfSpace) }
        Self.archive = archive
    }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".m4a") }
    func deleteAudio(_ name: String) throws { if Self.failDelete { throw CocoaError(.fileWriteNoPermission) }; Self.deletedNames.append(name) }
}
enum LocalIntelligence {
    static func summarize(day: Date, events: [Episode], language: AppLanguage, recordings: [Episode], markers: [MomentMarker] = [], clips: [EvidenceClip] = [], memories: [JournalMemory] = [], coverage: DailyCoverage? = nil) async throws -> DailyReport {
        Insights.report(day: day, events: events, language: language, recordings: recordings, markers: markers, clips: clips)
    }
}

extension ProcessInfo {
    enum ThermalState { case nominal, serious, critical }
    var thermalState: ThermalState { .nominal }
    var isLowPowerModeEnabled: Bool { ScenarioDefaults.store.bool(forKey: "fakeLowPower") }
}
enum AudioQuality {
    static func analyze(url: URL, sensitivity: Int) -> AudioQualitySummary? { nil }
}
