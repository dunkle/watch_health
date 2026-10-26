import Foundation

/// Platform-independent admission policy. The microphone is never a background entitlement workaround.
public struct CaptureGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case ignore
        case record
        case missed(String)
    }
    private var latestAccepted: Date?
    public init() {}
    public mutating func reset() { latestAccepted = nil }
    public mutating func evaluate(_ trigger: Trigger, now: Date, activeSince: Date?,
                                  foreground: Bool, busy: Bool, storageReady: Bool) -> Decision {
        guard storageReady, let activeSince, trigger.date >= activeSince,
              trigger.bpm.isFinite, trigger.baseline.isFinite,
              (30...240).contains(trigger.bpm), (30...240).contains(trigger.baseline),
              trigger.date.timeIntervalSince(now) <= 5 else { return .ignore }
        if let latestAccepted, trigger.date.timeIntervalSince(latestAccepted) < 180 { return .ignore }
        latestAccepted = trigger.date
        guard now.timeIntervalSince(trigger.date) <= 15 else { return .missed("事件延迟到达，未补录当时的语音。") }
        guard foreground else { return .missed("手机不在前台，未自动启动麦克风。") }
        guard !busy else { return .missed("录音或转写繁忙，未开始新录音。") }
        return .record
    }
}

public struct ContextMoment: Identifiable, Equatable, Sendable {
    public var id: Double { offset }
    public var offset: Double
    public var text: String
    public var cues: [String]
    public var changedFromPrevious: Bool
}

public extension Insights {
    /// Groups neighboring speech tokens so Chinese words split across segments still match.
    /// These are linguistic candidates, not inferred or confirmed emotions.
    static func moments(in segments: [TranscriptSegment]) -> [ContextMoment] {
        var chunks: [(Double, String)] = []
        var start: Double?
        var previousEnd: Double = 0
        var text = ""
        for segment in segments.sorted(by: { $0.offset < $1.offset }) {
            if let beginning = start, segment.offset - previousEnd > 1.2 || segment.offset - beginning > 12 {
                chunks.append((beginning, text)); start = nil; text = ""
            }
            if start == nil { start = segment.offset }
            text += segment.text
            previousEnd = segment.offset + segment.duration
            if segment.text.last.map({ "。！？!?".contains($0) }) ?? false {
                chunks.append((start ?? segment.offset, text)); start = nil; text = ""
            }
        }
        if let start { chunks.append((start, text)) }
        var previous: Set<String> = []
        return chunks.compactMap { offset, text in
            let candidates = cues(in: text)
            guard !candidates.isEmpty else { return nil }
            let current = Set(candidates)
            let changed = !previous.isEmpty && current != previous
            previous = current
            return ContextMoment(offset: offset, text: text, cues: candidates, changedFromPrevious: changed)
        }
    }
}
