import Foundation

/// A personal-change heuristic, not an emotion classifier or medical alarm.
/// Rejects old/out-of-order samples, uses preceding samples only, and enforces cooldown.
public struct HeartDetector: Sendable {
    public struct Settings: Sendable {
        public var window: TimeInterval = 180
        public var minimumSamples = 5
        public var absoluteChange: Double = 20
        public var relativeChange: Double = 0.25
        public var cooldown: TimeInterval = 180
        public var freshness: TimeInterval = 45
        public init() {}
    }
    public var settings: Settings
    private var history: [HeartSample] = []
    private var lastTrigger: Date?
    public init(settings: Settings = Settings()) { self.settings = settings }
    public mutating func reset() { history = []; lastTrigger = nil }
    public mutating func ingest(_ sample: HeartSample, now: Date = Date()) -> Trigger? {
        guard sample.bpm.isFinite, (30...240).contains(sample.bpm),
              now.timeIntervalSince(sample.date) >= -5,
              now.timeIntervalSince(sample.date) <= settings.freshness,
              history.last.map({ sample.date > $0.date }) ?? true else { return nil }
        history.removeAll { sample.date.timeIntervalSince($0.date) > settings.window }
        let preceding = history
        history.append(sample)
        guard preceding.count >= settings.minimumSamples else { return nil }
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
