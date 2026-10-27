import Foundation

public enum RecordingPolicy {
    public static let defaultMinutes = 60
    public static func minutes(_ value: Int) -> Int { min(180, max(1, value)) }
    public static func duration(minutes: Int) -> TimeInterval { Double(self.minutes(minutes)) * 60 }
    public static func chunks(duration: TimeInterval, length: TimeInterval = 45) -> [Range<Double>] {
        guard duration.isFinite, duration > 0, duration <= 180 * 60 + 1, length.isFinite, length > 0 else { return [] }
        return stride(from: 0.0, to: duration, by: length).map { $0..<min($0 + length, duration) }
    }
}

public struct HeartPoint: Codable, Identifiable, Sendable {
    public var id: String { "\(isDemo)-\(sample.date.timeIntervalSince1970)" }
    public var sample: HeartSample
    public var baseline: Double?
    public var isDemo: Bool
    public init(sample: HeartSample, baseline: Double? = nil, isDemo: Bool = false) {
        self.sample = sample; self.baseline = baseline; self.isDemo = isDemo
    }
}

public struct PlotPoint: Identifiable, Sendable {
    public var id: String { point.id }
    public var point: HeartPoint
    public var section: Int
}

public enum HeartTimeline {
    /// Keep gaps disconnected and min/max extrema visible even when reducing a long trace.
    public static func plot(_ points: [HeartPoint], limit: Int = 500, gap: TimeInterval = 90) -> [PlotPoint] {
        let ordered = points.filter { $0.sample.bpm.isFinite }.sorted { $0.sample.date < $1.sample.date }
        var section = 0; var previous: Date?
        let source = ordered.map { point -> PlotPoint in
            if let previous, point.sample.date.timeIntervalSince(previous) > gap { section += 1 }
            previous = point.sample.date
            return PlotPoint(point: point, section: section)
        }
        guard source.count > max(4, limit) else { return source }
        let size = max(1, Int(ceil(Double(source.count) / Double(max(2, limit / 4)))))
        var result: [PlotPoint] = []
        for index in stride(from: 0, to: source.count, by: size) {
            let bucket = Array(source[index..<min(index + size, source.count)])
            let selected = [bucket.first!, bucket.min { $0.point.sample.bpm < $1.point.sample.bpm }!,
                            bucket.max { $0.point.sample.bpm < $1.point.sample.bpm }!, bucket.last!]
            var ids: Set<String> = []
            result += selected.filter { ids.insert($0.id).inserted }.sorted { $0.point.sample.date < $1.point.sample.date }
        }
        return result
    }
}

public extension Trigger {
    var isLargeChange: Bool { abs(delta) >= 20 && abs(delta) / max(baseline, 1) >= 0.25 }
}
public extension Episode {
    var isImportant: Bool { trigger.isLargeChange || (assessment.map { $0.score >= 65 && $0.coverage >= 0.8 } ?? false) }
    func owner(in events: [Episode]) -> Episode? {
        guard let linkedRecordingID else { return self }
        return events.first { $0.id == linkedRecordingID && $0.linkedRecordingID == nil }
    }
    func audioOffset(in events: [Episode]) -> Double? {
        guard let owner = owner(in: events), let start = owner.captureStarted else { return nil }
        return max(0, trigger.date.timeIntervalSince(start))
    }
    func contextSegments(in events: [Episode], radius: Double = 20) -> [TranscriptSegment] {
        guard let owner = owner(in: events), let start = owner.captureStarted else { return [] }
        let offset = trigger.date.timeIntervalSince(start)
        return owner.segments.filter { $0.offset + $0.duration >= offset - radius && $0.offset <= offset + radius }
    }
}
