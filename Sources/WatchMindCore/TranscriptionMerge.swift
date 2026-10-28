import Foundation

/// A measured attempt over file-local time. Failed and skipped ranges never erase earlier text.
public struct TranscriptionChunkSpan: Sendable {
    public var range: Range<Double>
    public var outcome: ProcessingSpan.Outcome
    public init(_ range: Range<Double>, outcome: ProcessingSpan.Outcome) { self.range = range; self.outcome = outcome }
    public var succeeded: Bool { outcome == .recognized || outcome == .empty }
}

public enum TranscriptionMerge {
    /// Replace only successfully reprocessed ranges. Offsets on `previous` are archive-global;
    /// incoming segments/ranges are file-local, converted with `offset` exactly once.
    public static func merge(previous: FileTranscript?, audioName: String, text: String,
                             segments: [TranscriptSegment], spans: [TranscriptionChunkSpan], offset: Double = 0, completeRange: Range<Double>? = nil) -> FileTranscript {
        guard offset.isFinite else { return previous ?? .init(audioName: audioName, text: "", segments: []) }
        let successful = spans.filter { $0.succeeded && valid($0.range) }.map(\.range)
        let old = previous?.segments.filter(valid) ?? []
        let legacy = old.isEmpty ? previous?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        let fullyReplaced = completeRange.map { isCompleted($0, spans: spans) } ?? false
        // Unaligned legacy text has no safe partial-subtraction operation. Retain that evidence
        // until the caller proves the complete file range has succeeded.
        if !legacy.isEmpty && !fullyReplaced, let previous { return previous }
        let kept = old.filter { segment in
            // Speech emits timestamped word segments. A word belongs to the chunk containing
            // its start, even if its acoustic tail slightly overlaps the next chunk boundary.
            !successful.contains { $0.contains(segment.offset - offset) }
        }
        let incoming = segments.filter { segment in
            valid(segment) && successful.contains { $0.contains(segment.offset) }
        }.map { TranscriptSegment(text: $0.text, offset: $0.offset + offset, duration: $0.duration) }
        var ordered = (kept + incoming).sorted { a, b in
            if a.offset != b.offset { return a.offset < b.offset }
            if a.duration != b.duration { return a.duration < b.duration }
            return a.text < b.text
        }
        var seen: Set<SegmentIdentity> = []
        ordered.removeAll { !seen.insert(.init($0)).inserted }
        let nextText: String
        if fullyReplaced { nextText = text }
        else if !ordered.isEmpty { nextText = ordered.map(\.text).joined(separator: " ") }
        else if !successful.isEmpty { nextText = text }
        else { nextText = previous?.text ?? "" }
        return .init(audioName: audioName, text: nextText, segments: ordered)
    }

    /// Resume only ranges completely covered by successful prior work. A failed / skipped
    /// span or a hole prevents skipping; the caller can always choose a full re-transcription.
    public static func isCompleted(_ range: Range<Double>, spans: [TranscriptionChunkSpan]) -> Bool {
        guard valid(range) else { return false }
        let ordered = spans.filter { $0.succeeded && valid($0.range) }.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        var covered = range.lowerBound
        for span in ordered where span.upperBound > covered && span.lowerBound < range.upperBound {
            guard span.lowerBound <= covered + 0.0001 else { return false }
            covered = max(covered, span.upperBound)
            if covered >= range.upperBound - 0.0001 { return true }
        }
        return false
    }

    private static func valid(_ range: Range<Double>) -> Bool {
        range.lowerBound.isFinite && range.upperBound.isFinite && range.lowerBound >= 0 && range.upperBound > range.lowerBound
    }
    private static func valid(_ segment: TranscriptSegment) -> Bool {
        segment.offset.isFinite && segment.duration.isFinite && segment.offset >= 0 && segment.duration >= 0 && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private struct SegmentIdentity: Hashable {
        let text: String; let offset: Double; let duration: Double
        init(_ segment: TranscriptSegment) { text = segment.text; offset = segment.offset; duration = segment.duration }
    }
}
