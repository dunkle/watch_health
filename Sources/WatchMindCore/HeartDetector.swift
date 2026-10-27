import Foundation

/// A personal-change heuristic, not an emotion classifier or medical alarm.
/// Rejects old/out-of-order samples, uses preceding samples only, and enforces cooldown.
public struct HeartDetector: Sendable {
    public struct Settings: Sendable {
        public var window: TimeInterval = 180
        public var minimumSamples = 5
        public var absoluteChange: Double = 5
        public var relativeChange: Double = 0.05
        public var cooldown: TimeInterval = 30
        public var freshness: TimeInterval = 45
        public init() {}
    }
    public var settings: Settings
    private var history: [HeartSample] = []
    private var lastTrigger: Date?
    public init(settings: Settings = Settings()) { self.settings = settings }
    public var currentBaseline: Double? {
        let values = history.map(\.bpm).sorted()
        guard values.count >= max(1, settings.minimumSamples) else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid-1] + values[mid]) / 2 : values[mid]
    }
    public static func largeChanges() -> HeartDetector {
        var settings = Settings(); settings.absoluteChange = 20; settings.relativeChange = 0.25
        return HeartDetector(settings: settings)
    }
    public mutating func reset() { history = []; lastTrigger = nil }
    public mutating func ingest(_ sample: HeartSample, now: Date = Date()) -> Trigger? {
        guard sample.bpm.isFinite, (30...240).contains(sample.bpm),
              now.timeIntervalSince(sample.date) >= -5,
              now.timeIntervalSince(sample.date) <= settings.freshness,
              history.last.map({ sample.date > $0.date }) ?? true else { return nil }
        history.removeAll { sample.date.timeIntervalSince($0.date) > settings.window }
        let preceding = history
        history.append(sample)
        guard preceding.count >= max(1, settings.minimumSamples) else { return nil }
        let sorted = preceding.map(\.bpm).sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        let delta = abs(sample.bpm - median)
        guard delta >= settings.absoluteChange, delta / median >= settings.relativeChange,
              lastTrigger.map({ sample.date.timeIntervalSince($0) >= settings.cooldown }) ?? true else { return nil }
        lastTrigger = sample.date
        return Trigger(date: sample.date, bpm: sample.bpm, baseline: median)
    }
}
