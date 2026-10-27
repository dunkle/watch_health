import Foundation

public struct EvidenceClip: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var recordingID: UUID
    public var date: Date
    public var offset: Double
    public var duration: Double
    public var text: String
    public var note = ""
    public var confirmed = false
    public var suggested = false
    public var personIDs: [UUID] = []
    public var isDemo: Bool
    public init(recordingID: UUID, date: Date, offset: Double, duration: Double, text: String, isDemo: Bool) {
        self.recordingID = recordingID; self.date = date; self.offset = offset
        self.duration = duration; self.text = text; self.isDemo = isDemo
    }
}
public struct JournalPerson: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var isDemo: Bool
    public init(name: String, isDemo: Bool) { self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)); self.isDemo = isDemo }
}
public struct JournalMemory: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public var clipIDs: [UUID]
    public var enabled = true
    public var isDemo: Bool
    public init(text: String, clipIDs: [UUID], isDemo: Bool) { self.text = String(text.prefix(1000)); self.clipIDs = clipIDs; self.isDemo = isDemo }
}
public struct DailyReflection: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var day: Date
    public var text: String
    public var isDemo: Bool
    public init(day: Date, text: String, isDemo: Bool) { self.day = day; self.text = String(text.prefix(2000)); self.isDemo = isDemo }
}
public struct PlanCheckIn: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var note: String
    public init(date: Date, note: String) { self.date = date; self.note = String(note.prefix(500)) }
}
public struct ImprovementPlan: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var createdAt = Date()
    public var active = true
    public var checkIns: [PlanCheckIn] = []
    public var isDemo: Bool
    public init(title: String, isDemo: Bool) { self.title = String(title.prefix(200)); self.isDemo = isDemo }
}
public struct ObservationWindow: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Date
    public var lastKnownAt: Date
    public var end: Date?
    public init(start: Date) { self.start = start; self.lastKnownAt = start }
}
public struct ProcessingSpan: Codable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case recognized, empty, failed, skipped }
    public var id = UUID()
    public var recordingID: UUID
    public var audioName: String
    public var start: Date
    public var end: Date
    public var outcome: Outcome
    public init(recordingID: UUID, audioName: String, start: Date, end: Date, outcome: Outcome) {
        self.recordingID = recordingID; self.audioName = audioName; self.start = start; self.end = end; self.outcome = outcome
    }
}
public struct FileTranscript: Codable, Sendable {
    public var audioName: String
    public var text: String
    public var segments: [TranscriptSegment]
    public init(audioName: String, text: String, segments: [TranscriptSegment]) { self.audioName = audioName; self.text = text; self.segments = segments }
}
public struct JournalCollection: Codable, Sendable {
    public var clips: [EvidenceClip] = []
    public var people: [JournalPerson] = []
    public var memories: [JournalMemory] = []
    public var reflections: [DailyReflection] = []
    public var plans: [ImprovementPlan] = []
    public var observations: [ObservationWindow] = []
    public var processing: [ProcessingSpan] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case clips, people, memories, reflections, plans, observations, processing }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decodeIfPresent([EvidenceClip].self, forKey: .clips) ?? []
        people = try values.decodeIfPresent([JournalPerson].self, forKey: .people) ?? []
        memories = try values.decodeIfPresent([JournalMemory].self, forKey: .memories) ?? []
        reflections = try values.decodeIfPresent([DailyReflection].self, forKey: .reflections) ?? []
        plans = try values.decodeIfPresent([ImprovementPlan].self, forKey: .plans) ?? []
        observations = try values.decodeIfPresent([ObservationWindow].self, forKey: .observations) ?? []
        processing = try values.decodeIfPresent([ProcessingSpan].self, forKey: .processing) ?? []
    }
    /// Invalid source references never leave a memory active or retain searchable deleted evidence.
    public mutating func reconcile(episodes: [Episode]) {
        let owners = Dictionary(episodes.filter { $0.linkedRecordingID == nil }.map { ($0.id, $0.isDemo) }, uniquingKeysWith: { a, _ in a })
        clips.removeAll { owners[$0.recordingID] != $0.isDemo }
        for i in clips.indices where clips[i].confirmed {
            guard let owner = episodes.first(where: { $0.id == clips[i].recordingID }) else { continue }
            let clip = clips[i]
            let text = owner.segments.filter { $0.offset >= clip.offset - 0.0001 && $0.offset < clip.offset + max(0.001, clip.duration) }.map(\.text).joined()
            let normalize: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined() }
            if normalize(text) != normalize(clip.text) { clips[i].confirmed = false }
        }
        let validPeople = Set(people.map(\.id)), validClips = Set(clips.map(\.id))
        for i in clips.indices { clips[i].personIDs.removeAll { !validPeople.contains($0) } }
        for i in memories.indices where !memoryHasSources(memories[i]) || !Set(memories[i].clipIDs).isSubset(of: validClips) { memories[i].enabled = false }
        processing.removeAll { owners[$0.recordingID] == nil }
    }
    public func memoryHasSources(_ memory: JournalMemory) -> Bool {
        !memory.clipIDs.isEmpty && memory.clipIDs.allSatisfy { id in clips.contains { $0.id == id && $0.confirmed && $0.isDemo == memory.isDemo } }
    }
}
public struct JournalSearchHit: Identifiable, Sendable {
    public var id: String
    public var recordingID: UUID
    public var date: Date
    public var text: String
    public var offset: Double?
}
public enum JournalSearch {
    public static func find(_ query: String, episodes: [Episode], markers: [MomentMarker], journal: JournalCollection, personID: UUID? = nil) -> [JournalSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || personID != nil else { return [] }
        let matches: (String) -> Bool = { query.isEmpty || $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let ownerIDs = Set(episodes.filter { $0.linkedRecordingID == nil }.map(\.id))
        var hits: [JournalSearchHit] = []
        if personID == nil {
            for owner in episodes where owner.linkedRecordingID == nil {
                if owner.segments.isEmpty {
                    if matches(owner.transcript), !owner.transcript.isEmpty { hits.append(.init(id: "file-\(owner.id)", recordingID: owner.id, date: owner.captureStarted ?? owner.trigger.date, text: owner.transcript, offset: nil)) }
                } else {
                    // Search overlapping groups so words split into Speech tokens remain findable.
                    var matchedUntil = -Double.infinity
                    for i in owner.segments.indices {
                        if owner.segments[i].offset < matchedUntil { continue }
                        var group = [owner.segments[i]]
                        for next in owner.segments.dropFirst(i + 1).prefix(11) {
                            if next.offset - (group.last!.offset + group.last!.duration) > 2.5 { break }
                            group.append(next)
                        }
                        let spaced = group.map(\.text).joined(separator: " "), compact = group.map(\.text).joined()
                        if matches(spaced) || matches(compact) {
                            let segment = group[0]
                            matchedUntil = (group.last?.offset ?? segment.offset) + max(0.001, group.last?.duration ?? 0)
                            hits.append(.init(id: "word-\(owner.id)-\(i)", recordingID: owner.id, date: (owner.captureStarted ?? owner.trigger.date).addingTimeInterval(segment.offset), text: spaced, offset: segment.offset))
                        }
                    }
                }
            }
            for marker in markers where ownerIDs.contains(marker.recordingID) && matches(marker.note) && !marker.note.isEmpty {
                hits.append(.init(id: "marker-\(marker.id)", recordingID: marker.recordingID, date: marker.date, text: marker.note, offset: nil))
            }
        }
        for clip in journal.clips where ownerIDs.contains(clip.recordingID) && (personID == nil || clip.personIDs.contains(personID!)) && (matches(clip.text) || matches(clip.note)) {
            hits.append(.init(id: "clip-\(clip.id)", recordingID: clip.recordingID, date: clip.date, text: clip.text + (clip.note.isEmpty ? "" : "\n" + clip.note), offset: clip.offset))
        }
        return hits.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
