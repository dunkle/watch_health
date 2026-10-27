import Foundation

/// A user-created time anchor. No heart sample or emotion inference is fabricated.
public struct MomentMarker: Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var recordingID: UUID
    public var note: String
    public var isDemo: Bool
    public init(id: UUID = UUID(), date: Date, recordingID: UUID, note: String = "", isDemo: Bool = false) {
        self.id = id; self.date = date; self.recordingID = recordingID
        self.note = String(note.prefix(500)); self.isDemo = isDemo
    }
    public func owner(in episodes: [Episode]) -> Episode? {
        episodes.first { $0.id == recordingID && $0.linkedRecordingID == nil && $0.isDemo == isDemo }
    }
    public func audioLocation(in episodes: [Episode]) -> AudioLocation? {
        guard let owner = owner(in: episodes) else { return nil }
        return RecordingTimeline.location(at: date, in: owner)
    }
    public func context(in episodes: [Episode], radius: Double = 20) -> [TranscriptSegment] {
        guard let owner = owner(in: episodes), let start = owner.captureStarted else { return [] }
        let offset = date.timeIntervalSince(start)
        return owner.segments.filter { $0.offset + $0.duration >= offset - radius && $0.offset <= offset + radius }
    }
}

public enum RecordingTimeline {
    public static func location(at date: Date, in owner: Episode) -> AudioLocation? {
        guard owner.audioPurgedAt == nil, let start = owner.captureStarted, date >= start else { return nil }
        if let parts = owner.recordingParts, !parts.isEmpty {
            guard let part = parts.first(where: { part in
                let isActive = part.id == parts.last?.id && owner.status == .recording
                let end = part.endedAt ?? (isActive ? .distantFuture : part.startedAt)
                return date >= part.startedAt && date < end
            }) else { return nil }
            return AudioLocation(audioName: part.audioName, offset: date.timeIntervalSince(part.startedAt))
        }
        guard date < (owner.captureEnded ?? (owner.status == .recording ? .distantFuture : start)) else { return nil }
        return owner.audioName.map { AudioLocation(audioName: $0, offset: date.timeIntervalSince(start)) }
    }
}
