import Foundation

public struct SleepInterval: Sendable {
    public enum State: Sendable { case asleep, awake, inBed }
    public var start: Date
    public var end: Date
    public var state: State
    public var source: String
    public var priority: Int
    public init(start: Date, end: Date, state: State, source: String, priority: Int = 0) {
        self.start = start; self.end = end; self.state = state; self.source = source; self.priority = priority
    }
}
public struct SleepEstimate: Sendable {
    public var end: Date
    public var asleepSeconds: Double
    public var efficiency: Double?
    public var score: Double
}

/// A duration/efficiency heuristic, not Apple's proprietary sleep score or a clinical assessment.
public enum SleepScorer {
    public static func estimates(_ intervals: [SleepInterval], targetHours: Double = 8,
                                 calendar: Calendar = .current) -> [SleepEstimate] {
        let valid = intervals.filter { $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= 18 * 3600 }
        let days = Dictionary(grouping: valid) { calendar.startOfDay(for: $0.end.addingTimeInterval(-12 * 3600)) }
        return days.values.compactMap { night in
            let sources = Dictionary(grouping: night, by: \.source).values.filter { $0.contains { $0.state == .asleep } }
            guard let preferred = sources.max(by: { a, b in
                let aPriority = a.map(\.priority).max() ?? 0, bPriority = b.map(\.priority).max() ?? 0
                if aPriority != bPriority { return aPriority < bPriority }
                let aDuration = length(union(a.filter { $0.state == .asleep }.map { $0.start..<$0.end }))
                let bDuration = length(union(b.filter { $0.state == .asleep }.map { $0.start..<$0.end }))
                if aDuration != bDuration { return aDuration < bDuration }
                return (a.first?.source ?? "") < (b.first?.source ?? "")
            }) else { return nil }
            let sleep = union(preferred.filter { $0.state == .asleep }.map { $0.start..<$0.end })
            var sessions: [[Range<Date>]] = []
            for range in sleep {
                if let end = sessions.last?.last?.upperBound, range.lowerBound.timeIntervalSince(end) <= 2 * 3600 {
                    sessions[sessions.count - 1].append(range)
                } else { sessions.append([range]) }
            }
            guard let main = sessions.max(by: { length($0) < length($1) }), let first = main.first, let last = main.last else { return nil }
            let awake = union(preferred.filter { $0.state == .awake }.map { $0.start..<$0.end })
            var seconds = length(main)
            for a in main { for b in awake {
                seconds -= max(0, min(a.upperBound, b.upperBound).timeIntervalSince(max(a.lowerBound, b.lowerBound)))
            } }
            guard seconds >= 30 * 60 else { return nil }
            let bed = union(preferred.filter {
                $0.state == .inBed && $0.end > first.lowerBound && $0.start < last.upperBound
            }.map { max($0.start, first.lowerBound.addingTimeInterval(-2 * 3600))..<min($0.end, last.upperBound.addingTimeInterval(2 * 3600)) })
            let bedSeconds = length(bed)
            let efficiency: Double? = bedSeconds >= seconds ? min(1, seconds / bedSeconds) : nil
            let duration = min(1, seconds / (max(1, targetHours) * 3600))
            let score = (efficiency.map { 0.75 * duration + 0.25 * $0 } ?? duration) * 100
            return SleepEstimate(end: last.upperBound, asleepSeconds: seconds, efficiency: efficiency, score: score)
        }.sorted { $0.end < $1.end }
    }
    private static func union(_ ranges: [Range<Date>]) -> [Range<Date>] {
        var output: [Range<Date>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.upperBound > range.lowerBound {
            if let last = output.last, range.lowerBound <= last.upperBound {
                output[output.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { output.append(range) }
        }
        return output
    }
    private static func length(_ ranges: [Range<Date>]) -> Double { ranges.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) } }
}
