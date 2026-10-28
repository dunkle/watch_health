import Foundation

public enum MetricKind: String, Codable, CaseIterable, Sendable {
    case oxygen, hrv, steps, environmentalAudio, headphoneAudio, sleepScore, activeEnergy, wristTemperature
    public var title: String {
        switch self {
        case .oxygen: return "血氧"
        case .hrv: return "心率变异性 SDNN"
        case .steps: return "近5分钟步数"
        case .environmentalAudio: return "环境音暴露"
        case .headphoneAudio: return "耳机音暴露"
        case .sleepScore: return "睡眠评分（本地估算）"
        case .activeEnergy: return "近5分钟活动能量"
        case .wristTemperature: return "睡眠腕温"
        }
    }
    public var unit: String {
        switch self {
        case .oxygen, .sleepScore: return self == .oxygen ? "%" : "/100"
        case .hrv: return "ms"
        case .steps: return "steps"
        case .environmentalAudio, .headphoneAudio: return "dBA"
        case .activeEnergy: return "kcal"
        case .wristTemperature: return "°C"
        }
    }
    public var freshness: TimeInterval {
        switch self {
        case .oxygen: return 2 * 3600
        case .hrv: return 6 * 3600
        case .steps, .activeEnergy: return 120
        case .environmentalAudio, .headphoneAudio: return 30 * 60
        case .sleepScore, .wristTemperature: return 36 * 3600
        }
    }
    public func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .oxygen: return value > 0 && value <= 100
        case .sleepScore: return (0...100).contains(value)
        case .hrv: return (0...1000).contains(value)
        case .steps, .activeEnergy: return value >= 0
        case .environmentalAudio, .headphoneAudio: return (0...150).contains(value)
        case .wristTemperature: return (15...45).contains(value)
        }
    }
}

public struct MetricReading: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: MetricKind
    public var value: Double
    public var date: Date
    public var source: String
    /// Stable, locally pseudonymized source/device identity. Legacy archives retain named-source isolation.
    public var sourceID: String?
    public var comparableSourceID: String { sourceID.map { "stable:" + $0 } ?? "legacy:" + source }
    public init(id: String = UUID().uuidString, kind: MetricKind, value: Double, date: Date, source: String, sourceID: String? = nil) {
        self.id = id; self.kind = kind; self.value = value; self.date = date; self.source = source; self.sourceID = sourceID
    }
    public func isFresh(at date: Date) -> Bool {
        kind.accepts(value) && (0...kind.freshness).contains(date.timeIntervalSince(self.date))
    }
}

public struct EventAssessment: Codable, Sendable {
    public var score: Double
    public var coverage: Double
    public var activeMovement: Bool
    public var contributing: [MetricKind]
    public var unavailable: [MetricKind]
    public var readings: [MetricReading]
    public var algorithmVersion = "context-2"
}

public enum ContextAlgorithm {
    public static func latest(_ kind: MetricKind, in readings: [MetricReading], at now: Date) -> MetricReading? {
        readings.filter { $0.kind == kind && $0.date <= now && kind.accepts($0.value) }.max { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    /// Exactly fourteen preceding calendar days, including across daylight-saving changes.
    public static func historyStart(before date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -14, to: start) ?? start
    }
    /// One value per day prevents a high-frequency source from dominating a personal baseline.
    public static func baseline(_ kind: MetricKind, readings: [MetricReading], before date: Date,
                                calendar: Calendar = .current) -> (median: Double, mad: Double)? {
        let start = calendar.startOfDay(for: date)
        let past = readings.filter { $0.kind == kind && $0.date < start && $0.date >= historyStart(before: date, calendar: calendar) && kind.accepts($0.value) }
        guard Set(past.map(\.comparableSourceID)).count == 1 else { return nil }
        let daily = Dictionary(grouping: past, by: { calendar.startOfDay(for: $0.date) }).values.map { median($0.map(\.value)) }
        guard daily.count >= 5 else { return nil }
        let center = median(daily)
        return (center, median(daily.map { abs($0 - center) }))
    }
    public static func assess(_ trigger: Trigger, readings: [MetricReading]) -> EventAssessment {
        let now = trigger.date
        let fresh = MetricKind.allCases.compactMap { latest($0, in: readings, at: now) }.filter { $0.isFresh(at: now) }
        let movement = fresh.contains { ($0.kind == .steps && $0.value >= 20) || ($0.kind == .activeEnergy && $0.value >= 2) }
        let heart = min(1, abs(trigger.delta) / max(20, trigger.baseline * 0.25))
        var weighted = 0.6 * heart * (movement ? 0.65 : 1)
        var weight = 0.6
        var used: [MetricKind] = []
        for reading in fresh {
            let w: Double
            let deviation: Double
            switch reading.kind {
            case .steps, .activeEnergy: continue // Context only; never relabel exercise as emotion.
            case .sleepScore:
                w = 0.07; deviation = max(0, (80 - reading.value) / 50)
            default:
                guard let base = baseline(reading.kind, readings: readings.filter { $0.comparableSourceID == reading.comparableSourceID }, before: now) else { continue }
                let floor: Double
                switch reading.kind {
                case .oxygen: w = 0.08; floor = 2
                case .hrv: w = 0.12; floor = 10
                case .environmentalAudio: w = 0.05; floor = 10
                case .headphoneAudio: w = 0.03; floor = 10
                case .wristTemperature: w = 0.05; floor = 0.2
                default: continue
                }
                let difference = reading.kind == .hrv || reading.kind == .oxygen ? base.median - reading.value : abs(reading.value - base.median)
                deviation = max(0, difference / max(floor, 3 * 1.4826 * base.mad))
            }
            weighted += w * min(1, deviation); weight += w; used.append(reading.kind)
        }
        return EventAssessment(score: min(100, max(0, weighted / weight * 100)), coverage: weight,
            activeMovement: movement, contributing: used, unavailable: MetricKind.allCases.filter { kind in !fresh.contains { $0.kind == kind } }, readings: fresh)
    }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
