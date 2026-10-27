import Foundation

public struct HourBucket: Identifiable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    public var eventIDs: [UUID]
    public var markerIDs: [UUID]
    public var continuationIDs: [UUID]
    public var isEmpty: Bool { eventIDs.isEmpty && markerIDs.isEmpty && continuationIDs.isEmpty }
}

public enum HourTimeline {
    /// Calendar intervals preserve 23/25-hour days and half-hour DST transitions.
    public static func buckets(on day: Date, episodes: [Episode], markers: [MomentMarker],
                               now: Date = Date(), calendar: Calendar = .current) -> [HourBucket] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        var result: [HourBucket] = [], cursor = interval.start
        while cursor < interval.end {
            guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
            let end = min(hour.end, interval.end)
            let events = episodes.filter { $0.trigger.date >= cursor && $0.trigger.date < end }.sorted { $0.trigger.date < $1.trigger.date }
            let anchors = markers.filter { $0.date >= cursor && $0.date < end && $0.owner(in: episodes) != nil }.sorted { $0.date < $1.date }
            let continuing = episodes.filter { event in
                guard event.linkedRecordingID == nil, event.trigger.date < cursor, let start = event.captureStarted else { return false }
                let parts = event.recordingParts ?? [.init(audioName: event.audioName ?? "", startedAt: start, endedAt: event.captureEnded)]
                return parts.contains { part in
                    let stop = part.endedAt ?? (event.status == .recording ? now : part.startedAt)
                    return part.startedAt < end && stop > cursor && !part.audioName.isEmpty
                }
            }.sorted { $0.trigger.date < $1.trigger.date }
            result.append(.init(start: cursor, end: end, eventIDs: events.map(\.id), markerIDs: anchors.map(\.id), continuationIDs: continuing.map(\.id)))
            cursor = end
        }
        return result
    }
}
