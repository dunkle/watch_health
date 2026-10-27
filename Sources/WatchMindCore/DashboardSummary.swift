import Foundation

public struct DashboardMoment: Identifiable, Sendable {
    public enum Source: Sendable { case heart, manual, highlight }
    public var id: UUID
    public var date: Date
    public var source: Source
    public var text: String
}

/// Counts and suggestions use actual scoped records. Missing data never becomes a wellbeing score.
public struct DashboardSummary: Sendable {
    public var heartEvents: Int
    public var manualMarkers: Int
    public var confirmedHighlights: Int
    public var needsReview: Int
    public var latest: DashboardMoment?
    public var hasTodayEvidence: Bool { heartEvents + manualMarkers + confirmedHighlights > 0 }

    public static func build(day: Date, episodes: [Episode], markers: [MomentMarker], clips: [EvidenceClip],
                             isDemo: Bool, calendar: Calendar = .current) -> DashboardSummary {
        let scoped = episodes.filter { $0.isDemo == isDemo }
        let owners = Set(scoped.filter { $0.linkedRecordingID == nil }.map(\.id))
        let today = scoped.filter { calendar.isDate($0.trigger.date, inSameDayAs: day) }
        let manual = markers.filter { $0.isDemo == isDemo && owners.contains($0.recordingID) && calendar.isDate($0.date, inSameDayAs: day) }
        let highlights = clips.filter { $0.isDemo == isDemo && $0.confirmed && owners.contains($0.recordingID) && calendar.isDate($0.date, inSameDayAs: day) }
        let pending = scoped.filter { $0.linkedRecordingID == nil && $0.audioPurgedAt == nil && ($0.cleanupPending == true || ([.failed, .partial, .deferred].contains($0.status) && !$0.audioNames.isEmpty)) }
        let moments = today.map { DashboardMoment(id: $0.id, date: $0.trigger.date, source: .heart, text: Insights.voiceContext(for: $0, events: scoped)) }
            + manual.map { DashboardMoment(id: $0.id, date: $0.date, source: .manual, text: $0.note.isEmpty ? $0.context(in: scoped).map(\.text).joined(separator: " ") : $0.note) }
            + highlights.map { DashboardMoment(id: $0.id, date: $0.date, source: .highlight, text: $0.text) }
        return .init(heartEvents: today.count, manualMarkers: manual.count, confirmedHighlights: highlights.count,
                     needsReview: pending.count, latest: moments.max { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date })
    }
}
