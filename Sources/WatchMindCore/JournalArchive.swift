import Foundation

public struct JournalArchive: Codable {
    public var version = 1
    public var episodes: [Episode]
    public var reports: [DailyReport]
    public var heartPoints: [HeartPoint]
    public var metrics: [MetricReading]
    public var markers: [MomentMarker]
    public var journal: JournalCollection
    public init(episodes: [Episode] = [], reports: [DailyReport] = [], heartPoints: [HeartPoint] = [], metrics: [MetricReading] = [], markers: [MomentMarker] = [], journal: JournalCollection = .init()) {
        self.episodes = episodes; self.reports = reports; self.heartPoints = heartPoints; self.metrics = metrics; self.markers = markers; self.journal = journal
    }
    enum CodingKeys: String, CodingKey { case version, episodes, reports, heartPoints, metrics, markers, journal }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        episodes = try values.decode([Episode].self, forKey: .episodes)
        reports = try values.decode([DailyReport].self, forKey: .reports)
        heartPoints = try values.decodeIfPresent([HeartPoint].self, forKey: .heartPoints) ?? []
        metrics = try values.decodeIfPresent([MetricReading].self, forKey: .metrics) ?? []
        markers = try values.decodeIfPresent([MomentMarker].self, forKey: .markers) ?? []
        journal = try values.decodeIfPresent(JournalCollection.self, forKey: .journal) ?? .init()
    }
}
