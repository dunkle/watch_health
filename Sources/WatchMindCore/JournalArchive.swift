import Foundation

public struct JournalArchive: Codable {
    public var version = 1
    public var episodes: [Episode]
    public var reports: [DailyReport]
    public var heartPoints: [HeartPoint]
    public var metrics: [MetricReading]
    public init(episodes: [Episode] = [], reports: [DailyReport] = [], heartPoints: [HeartPoint] = [], metrics: [MetricReading] = []) {
        self.episodes = episodes; self.reports = reports; self.heartPoints = heartPoints; self.metrics = metrics
    }
    enum CodingKeys: String, CodingKey { case version, episodes, reports, heartPoints, metrics }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        episodes = try values.decode([Episode].self, forKey: .episodes)
        reports = try values.decode([DailyReport].self, forKey: .reports)
        heartPoints = try values.decodeIfPresent([HeartPoint].self, forKey: .heartPoints) ?? []
        metrics = try values.decodeIfPresent([MetricReading].self, forKey: .metrics) ?? []
    }
}
