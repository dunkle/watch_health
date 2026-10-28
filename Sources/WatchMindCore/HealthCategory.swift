import Foundation

/// Navigation groups, not diagnostic labels or a single combined health score.
public enum HealthCategory: String, CaseIterable, Codable, Sendable {
    case cardio, activity, recovery, environment
    public var title: String {
        switch self {
        case .cardio: return "心血管与身体信号"
        case .activity: return "活动与消耗"
        case .recovery: return "睡眠与恢复线索"
        case .environment: return "声音与环境暴露"
        }
    }
    public var summary: String {
        switch self {
        case .cardio: return "心率、血氧与心率变异性；变化需要结合活动和个人基线理解。"
        case .activity: return "近5分钟步数和活动能量，用于区分活动情境。"
        case .recovery: return "睡眠估算与睡眠腕温；不是医学恢复评分。"
        case .environment: return "健康记录中的环境和耳机音暴露，不启动麦克风。"
        }
    }
    public var symbol: String {
        switch self {
        case .cardio: return "heart.text.square"
        case .activity: return "figure.walk"
        case .recovery: return "moon.zzz"
        case .environment: return "ear"
        }
    }
    public var includesHeart: Bool { self == .cardio }
    public var metricKinds: [MetricKind] { MetricKind.allCases.filter { $0.category == self } }
}

public extension MetricKind {
    var category: HealthCategory {
        switch self {
        case .oxygen, .hrv: return .cardio
        case .steps, .activeEnergy: return .activity
        case .sleepScore, .wristTemperature: return .recovery
        case .environmentalAudio, .headphoneAudio: return .environment
        }
    }
}
