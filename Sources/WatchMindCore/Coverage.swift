import Foundation

public struct DailyCoverage: Sendable {
    public var observed: Double?
    public var recorded: Double
    public var processed: Double
    public var recognized: Double
    public var failed: Double
    public var skipped: Double
    public var recordedFraction: Double? { guard let observed, observed > 0 else { return nil }; return min(1, recorded / observed) }
}
public enum Coverage {
    public static func seconds(_ intervals: [DateInterval], within bounds: DateInterval) -> Double {
        let sorted = intervals.compactMap { $0.intersection(with: bounds) }.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var total = 0.0, current: DateInterval?
        for interval in sorted {
            if let previous = current {
                if interval.start <= previous.end { current = .init(start: previous.start, end: max(previous.end, interval.end)) }
                else { total += previous.duration; current = interval }
            } else { current = interval }
        }
        return total + (current?.duration ?? 0)
    }
    public static func daily(_ day: Date, episodes: [Episode], journal: JournalCollection, now: Date = Date(), calendar: Calendar = .current) -> DailyCoverage {
        let day = calendar.dateInterval(of: .day, for: day)!
        let windows = journal.observations.filter { $0.start < day.end && ($0.end ?? $0.lastKnownAt) > day.start }
        let observed = windows.compactMap { window -> DateInterval? in
            let end = min(now, window.end ?? window.lastKnownAt)
            return end > window.start ? .init(start: window.start, end: end) : nil
        }
        let audio = episodes.filter { $0.linkedRecordingID == nil }.flatMap { episode -> [DateInterval] in
            let parts = episode.recordingParts ?? episode.captureStarted.map { [.init(audioName: episode.audioName ?? "", startedAt: $0, endedAt: episode.captureEnded)] } ?? []
            return parts.compactMap { part in
                let end = min(now, part.endedAt ?? (episode.status == .recording ? now : part.startedAt))
                return end > part.startedAt ? .init(start: part.startedAt, end: end) : nil
            }
        }
        let owners = Set(episodes.filter { $0.linkedRecordingID == nil }.map(\.id))
        let spans = journal.processing.filter { owners.contains($0.recordingID) && $0.end > $0.start }
        func ranges(_ outcomes: [ProcessingSpan.Outcome]) -> [DateInterval] { spans.filter { outcomes.contains($0.outcome) }.map { .init(start: $0.start, end: $0.end) } }
        return .init(observed: windows.isEmpty ? nil : seconds(observed, within: day), recorded: seconds(audio, within: day),
                     processed: seconds(ranges([.recognized, .empty]), within: day), recognized: seconds(ranges([.recognized]), within: day), failed: seconds(ranges([.failed]), within: day), skipped: seconds(ranges([.skipped]), within: day))
    }
}
public struct AudioQualitySummary: Codable, Sendable {
    public var analyzedSeconds: Double
    public var lowEnergySeconds: Double
    public var peakDBFS: Double
    public var sensitivity: Int
    public var speechSeconds: Double?
    public init(analyzedSeconds: Double, lowEnergySeconds: Double, peakDBFS: Double, sensitivity: Int, speechSeconds: Double? = nil) {
        self.analyzedSeconds = analyzedSeconds; self.lowEnergySeconds = lowEnergySeconds; self.peakDBFS = peakDBFS; self.sensitivity = sensitivity; self.speechSeconds = speechSeconds
    }
}
public enum AudioEnergy {
    public static func threshold(sensitivity: Int) -> Double { [-32, -38, -44, -50, -56][min(4, max(0, sensitivity - 1))] }
    public static func shouldSkip(_ quality: AudioQualitySummary?, range: Range<Double>, protectedOffsets: [Double]) -> Bool {
        guard !protectedOffsets.contains(where: { $0 >= range.lowerBound - 20 && $0 <= range.upperBound + 20 }), let quality,
              quality.speechSeconds == 0, quality.analyzedSeconds >= (range.upperBound - range.lowerBound) * 0.95 else { return false }
        return true
    }
    public static func speechThreshold(sensitivity: Int) -> Double { [0.8, 0.7, 0.6, 0.45, 0.3][min(4, max(0, sensitivity - 1))] }
    public static func dbfs(meanSquare: Double) -> Double { meanSquare.isFinite && meanSquare > 0 ? max(-120, 10 * log10(meanSquare)) : -120 }
}
