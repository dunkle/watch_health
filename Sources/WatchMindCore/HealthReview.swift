import Foundation

public struct LifeBlock: Identifiable, Sendable {
    public enum Signal: Sendable { case activity, heart, unknown }
    public var id: Date { start }
    public var start: Date
    public var end: Date
    public var signal: Signal
    public var sampleCount: Int
}
public enum HealthReview {
    public static func canvas(day: Date, hearts: [HeartPoint], readings: [MetricReading], calendar: Calendar = .current) -> [LifeBlock] {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
        return stride(from: bounds.start.timeIntervalSince1970, to: bounds.end.timeIntervalSince1970, by: 600).map { seconds in
            let start = Date(timeIntervalSince1970: seconds), end = min(bounds.end, start.addingTimeInterval(600))
            let count = hearts.filter { $0.sample.date >= start && $0.sample.date < end && $0.sample.bpm.isFinite && (30...240).contains($0.sample.bpm) }.count
            let active = readings.contains { $0.date >= start && $0.date < end && $0.kind.accepts($0.value) && (($0.kind == .steps && $0.value >= 20) || ($0.kind == .activeEnergy && $0.value >= 2)) }
            return LifeBlock(start: start, end: end, signal: active ? .activity : (count > 0 ? .heart : .unknown), sampleCount: count)
        }
    }
    public static func trend(_ kind: MetricKind, readings: [MetricReading], at now: Date, calendar: Calendar = .current) -> (reading: MetricReading, baseline: Double?, days: Int)? {
        guard let latest = ContextAlgorithm.latest(kind, in: readings, at: now) else { return nil }
        let cutoff = calendar.startOfDay(for: now)
        let historyStart = ContextAlgorithm.historyStart(before: now, calendar: calendar)
        let days = Set(readings.filter { $0.kind == kind && kind.accepts($0.value) && $0.date < cutoff && $0.date >= historyStart }.map { calendar.startOfDay(for: $0.date) }).count
        // Baselines from mixed named sources are not treated as directly comparable.
        let sources = Set(readings.filter { $0.kind == kind && $0.date >= historyStart && $0.date <= now }.map(\.comparableSourceID))
        let baseline = sources.count == 1 ? ContextAlgorithm.baseline(kind, readings: readings, before: now, calendar: calendar)?.median : nil
        return (latest, baseline, days)
    }
    public static func suggestion(readings: [MetricReading], now: Date, language: AppLanguage) -> String {
        let l = Localizer(language: language)
        if let sleep = ContextAlgorithm.latest(.sleepScore, in: readings, at: now), sleep.isFresh(at: now), sleep.value < 70 {
            return l("最近可用的睡眠估算偏低。可以为今天留一点休息空间；是否调整活动由你决定。")
        }
        if let hrv = trend(.hrv, readings: readings, at: now), hrv.reading.isFresh(at: now), let base = hrv.baseline, hrv.reading.value < base - 10 {
            return l("最近HRV低于个人历史基线。这只是身体变化线索，可以结合睡眠和本人感受再决定安排。")
        }
        return l("目前没有足够依据建议改变活动。可记录本人感受，或选择一个你愿意尝试的小调整。")
    }
}
