import Foundation

public struct HeartSample: Codable, Equatable, Sendable {
    public var date: Date
    public var bpm: Double
    public init(date: Date, bpm: Double) { self.date = date; self.bpm = bpm }
}

public struct Trigger: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var bpm: Double
    public var baseline: Double
    public var delta: Double { bpm - baseline }
    public init(id: UUID = UUID(), date: Date, bpm: Double, baseline: Double) {
        self.id = id; self.date = date; self.bpm = bpm; self.baseline = baseline
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var text: String
    public var offset: Double
    public var duration: Double
    public init(text: String, offset: Double, duration: Double) {
        self.text = text; self.offset = offset; self.duration = duration
    }
}

public enum CaptureStatus: String, Codable, Sendable {
    case missed, recording, transcribing, ready, failed, linked, partial
}

public struct Episode: Codable, Identifiable, Sendable {
    public var id: UUID { trigger.id }
    public var trigger: Trigger
    public var captureStarted: Date?
    public var status: CaptureStatus
    public var transcript: String
    public var segments: [TranscriptSegment]
    public var note: String
    public var feeling: String?
    public var audioName: String?
    public var speechLanguage: String?
    public var captureEnded: Date?
    public var maximumDuration: Double?
    public var linkedRecordingID: UUID?
    public var assessment: EventAssessment?
    public var failedTranscriptionChunks: Int?
    /// Before language selection existed, all real recordings used zh-CN.
    public var transcriptionLanguage: AppLanguage {
        AppLanguage(rawValue: speechLanguage ?? "zh-Hans")?.resolved ?? .simplifiedChinese
    }
    public var isDemo: Bool
    public init(trigger: Trigger, status: CaptureStatus = .missed, note: String = "", isDemo: Bool = false) {
        self.trigger = trigger; self.status = status; self.note = note; self.isDemo = isDemo
        transcript = ""; segments = []
    }
}

public struct DailyReport: Codable, Sendable {
    public var day: Date
    public var text: String
    public var engine: String
    public var episodeIDs: [UUID]
    public var generatedAt: Date
    public var language: String?
    public init(day: Date, text: String, engine: String, episodeIDs: [UUID], generatedAt: Date = Date(), language: String? = nil) {
        self.day = day; self.text = text; self.engine = engine
        self.episodeIDs = episodeIDs; self.generatedAt = generatedAt; self.language = language
    }
}
