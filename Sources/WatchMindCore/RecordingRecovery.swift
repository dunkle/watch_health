import Foundation

/// One wall-clock session. Interruptions consume the original time budget; resuming never extends it.
public struct RecordingRecovery: Sendable {
    public enum Phase: Sendable { case recording, paused, finished }
    public private(set) var phase: Phase = .recording
    public private(set) var automaticResumeAllowed = false
    public private(set) var requiresManualResume = false
    public let startedAt: Date
    public let deadline: Date
    public init(startedAt: Date, maximumDuration: TimeInterval) {
        self.startedAt = startedAt
        let duration = maximumDuration.isFinite ? min(86400, max(60, maximumDuration)) : 3600
        deadline = startedAt.addingTimeInterval(duration)
    }
    public func remaining(at now: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }
    public mutating func pause(automatic: Bool, manualOnly: Bool = false) {
        guard phase != .finished else { return }
        phase = .paused
        requiresManualResume = requiresManualResume || manualOnly
        automaticResumeAllowed = automatic && !requiresManualResume
    }
    public mutating func allowAutomaticResume(_ allowed: Bool) {
        guard phase == .paused else { return }
        automaticResumeAllowed = allowed && !requiresManualResume
    }
    public func canResume(at now: Date, foreground: Bool, storageReady: Bool,
                          systemInterrupted: Bool, automatic: Bool) -> Bool {
        phase == .paused && remaining(at: now) > 0 && foreground && storageReady && !systemInterrupted
            && (!automatic || automaticResumeAllowed)
    }
    @discardableResult public mutating func resumed(at now: Date) -> Bool {
        guard phase == .paused, remaining(at: now) > 0 else { return false }
        phase = .recording; automaticResumeAllowed = false; requiresManualResume = false; return true
    }
    public mutating func finish() { phase = .finished; automaticResumeAllowed = false }
}

/// Separate audio files keep the real wall-clock gap rather than compressing interruptions out of the timeline.
public struct RecordingPart: Codable, Identifiable, Sendable {
    public var id: UUID
    public var audioName: String
    public var startedAt: Date
    public var endedAt: Date?
    public init(id: UUID = UUID(), audioName: String, startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.audioName = audioName; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

public struct AudioLocation: Equatable, Sendable {
    public var audioName: String
    public var offset: TimeInterval
    public init(audioName: String, offset: TimeInterval) { self.audioName = audioName; self.offset = offset }
}

public extension Episode {
    var audioNames: [String] {
        var names = recordingParts?.map(\.audioName) ?? []
        if let audioName, !names.contains(audioName) { names.insert(audioName, at: 0) }
        return Array(Set(names)).sorted()
    }
    /// Legacy files use a single continuous timeline. New files only resolve inside a recorded part.
    func audioLocation(in events: [Episode]) -> AudioLocation? {
        guard let owner = owner(in: events), let start = owner.captureStarted else { return nil }
        guard let parts = owner.recordingParts, !parts.isEmpty else {
            return owner.audioName.map { AudioLocation(audioName: $0, offset: max(0, trigger.date.timeIntervalSince(start))) }
        }
        if id == owner.id, let first = parts.first {
            return AudioLocation(audioName: first.audioName, offset: 0)
        }
        return RecordingTimeline.location(at: trigger.date, in: owner)
    }
}
