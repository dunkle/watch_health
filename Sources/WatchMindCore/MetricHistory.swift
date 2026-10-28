import Foundation

/// A query result may replace a derived cache only when its covered query completed successfully.
/// A nil replacement window means failure, unsupported data, or a truncated query: preserve cached history.
public struct HealthMetricSnapshot: Sendable {
    public var readings: [MetricReading]
    public var replacingSleepWindow: DateInterval?
    public init(readings: [MetricReading], replacingSleepWindow: DateInterval? = nil) {
        self.readings = readings; self.replacingSleepWindow = replacingSleepWindow
    }
}

public enum MetricHistory {
    public static func sleepReadings(_ intervals: [SleepInterval], calendar: Calendar = .current) -> [MetricReading] {
        SleepScorer.estimates(intervals, calendar: calendar).map { estimate in
            let algorithm = estimate.efficiency == nil ? "duration-v2" : "duration-efficiency-v2"
            return MetricReading(id: "sleep-night-\(Int(estimate.night.timeIntervalSince1970))", kind: .sleepScore,
                value: estimate.score, date: estimate.end,
                source: estimate.efficiency == nil ? "local-duration-only" : "local-duration-efficiency",
                sourceID: "watchmind.sleep.\(algorithm):\(estimate.source)")
        }
    }
    /// Replaces stale revisions of the same night even when partial synchronization changed the sleep end.
    /// A completed authoritative query also removes locally derived nights that no longer have readable evidence.
    public static func merge(existing: [MetricReading], snapshot: HealthMetricSnapshot, at now: Date,
                             calendar: Calendar = .current) -> [MetricReading] {
        var existing = existing
        if let window = snapshot.replacingSleepWindow {
            existing.removeAll { reading in
                reading.kind == .sleepScore && reading.date >= window.start && reading.date <= window.end
                    && (reading.id.hasPrefix("sleep-") || reading.sourceID?.hasPrefix("watchmind.sleep.") == true)
            }
        }
        var combined = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for reading in snapshot.readings where reading.kind.accepts(reading.value) && reading.date <= now {
            combined[reading.id] = reading
        }
        let start = ContextAlgorithm.historyStart(before: now, calendar: calendar)
        let recent = combined.values.filter { $0.date >= start && $0.date <= now && $0.kind.accepts($0.value) }
        return Dictionary(grouping: recent, by: \.kind).values.flatMap {
            $0.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.prefix(500)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
