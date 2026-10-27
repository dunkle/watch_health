import Foundation
import WatchMindCore

@MainActor extension AppModel {
    func journalChanged() { reports = []; save() }
    var visibleClips: [EvidenceClip] { journal.clips.filter { clip in clip.isDemo == demoMode && visible.contains(where: { $0.id == clip.recordingID }) } }
    var visiblePeople: [JournalPerson] { journal.people.filter { $0.isDemo == demoMode } }
    var visibleMemories: [JournalMemory] { journal.memories.filter { $0.isDemo == demoMode } }
    var visiblePlans: [ImprovementPlan] { journal.plans.filter { $0.isDemo == demoMode } }
    var coverage: DailyCoverage {
        var scoped = journal
        if demoMode { scoped.observations = [] }
        return Coverage.daily(selectedDay, episodes: visible, journal: scoped)
    }
    @discardableResult func saveClip(recordingID: UUID, at date: Date, suggested: Bool = false) -> UUID? {
        guard canWriteArchive, let owner = visible.first(where: { $0.id == recordingID && $0.linkedRecordingID == nil }), let start = owner.captureStarted else { return nil }
        let segments = owner.segments.filter { $0.offset + $0.duration >= date.timeIntervalSince(start) - 20 && $0.offset <= date.timeIntervalSince(start) + 20 }.sorted { $0.offset < $1.offset }
        guard let first = segments.first, let last = segments.last else { return nil }
        let quote = segments.map(\.text).joined(separator: " ")
        if let existing = journal.clips.first(where: { $0.recordingID == recordingID && abs($0.offset - first.offset) < 1 && $0.text == quote }) { return existing.id }
        var clip = EvidenceClip(recordingID: recordingID, date: start.addingTimeInterval(first.offset), offset: first.offset,
                                duration: max(0.001, last.offset + max(0.001, last.duration) - first.offset), text: quote, isDemo: owner.isDemo)
        clip.suggested = suggested; clip.confirmed = !suggested
        journal.clips.append(clip); journalChanged(); return clip.id
    }
    func suggestHighlights() {
        guard canWriteArchive else { return }
        for event in dayEvents where event.isImportant { _ = saveClip(recordingID: event.linkedRecordingID ?? event.id, at: event.trigger.date, suggested: true) }
        for marker in visibleMarkers where Calendar.current.isDate(marker.date, inSameDayAs: selectedDay) { _ = saveClip(recordingID: marker.recordingID, at: marker.date, suggested: true) }
    }
    func editClip(_ id: UUID, note: String, confirmed: Bool) {
        guard canWriteArchive, let i = journal.clips.firstIndex(where: { $0.id == id }) else { return }
        journal.clips[i].note = String(note.prefix(1000)); journal.clips[i].confirmed = confirmed
        if !confirmed {
            for index in journal.memories.indices where journal.memories[index].clipIDs.contains(id) { journal.memories[index].enabled = false }
        }
        journalChanged()
    }
    func deleteClip(_ id: UUID) {
        guard canWriteArchive else { return }
        journal.clips.removeAll { $0.id == id }; journal.reconcile(episodes: episodes); journalChanged()
    }
    func addPerson(_ name: String) {
        guard canWriteArchive, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        journal.people.append(.init(name: name, isDemo: demoMode)); journalChanged()
    }
    func linkPerson(_ personID: UUID, clipID: UUID) {
        guard canWriteArchive, let i = journal.clips.firstIndex(where: { $0.id == clipID && $0.isDemo == demoMode }), visiblePeople.contains(where: { $0.id == personID }) else { return }
        if journal.clips[i].personIDs.contains(personID) { journal.clips[i].personIDs.removeAll { $0 == personID } }
        else { journal.clips[i].personIDs.append(personID) }
        journalChanged()
    }
    func renamePerson(_ id: UUID, name: String) {
        guard canWriteArchive, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let i = journal.people.firstIndex(where: { $0.id == id }) else { return }
        journal.people[i].name = String(name.prefix(40)); journalChanged()
    }
    func deletePerson(_ id: UUID) {
        guard canWriteArchive else { return }
        journal.people.removeAll { $0.id == id }; journal.reconcile(episodes: episodes); journalChanged()
    }
    func addMemory(clipID: UUID, text: String) {
        guard canWriteArchive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, visibleClips.contains(where: { $0.id == clipID && $0.confirmed }) else { return }
        journal.memories.append(.init(text: text, clipIDs: [clipID], isDemo: demoMode)); journalChanged()
    }
    func editMemory(_ id: UUID, text: String, enabled: Bool) {
        guard canWriteArchive, let i = journal.memories.firstIndex(where: { $0.id == id }) else { return }
        journal.memories[i].text = String(text.prefix(1000))
        journal.memories[i].enabled = enabled && journal.memoryHasSources(journal.memories[i]); journalChanged()
    }
    func deleteMemory(_ id: UUID) { guard canWriteArchive else { return }; journal.memories.removeAll { $0.id == id }; journalChanged() }
    func saveReflection(_ text: String) {
        guard canWriteArchive else { return }
        journal.reflections.removeAll { $0.isDemo == demoMode && Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { journal.reflections.append(.init(day: selectedDay, text: text, isDemo: demoMode)) }
        journalChanged()
    }
    func addPlan(_ title: String) {
        guard canWriteArchive, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !visiblePlans.contains(where: \.active) else { return }
        journal.plans.append(.init(title: title, isDemo: demoMode)); journalChanged()
    }
    func checkIn(_ id: UUID, note: String) {
        guard canWriteArchive, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let i = journal.plans.firstIndex(where: { $0.id == id && $0.active }) else { return }
        journal.plans[i].checkIns.append(.init(date: Date(), note: note)); journalChanged()
    }
    func finishPlan(_ id: UUID) { guard canWriteArchive, let i = journal.plans.firstIndex(where: { $0.id == id }) else { return }; journal.plans[i].active = false; journalChanged() }
    func deletePlan(_ id: UUID) { guard canWriteArchive else { return }; journal.plans.removeAll { $0.id == id }; journalChanged() }
    func playClip(_ clip: EvidenceClip) {
        let marker = MomentMarker(id: clip.id, date: clip.date, recordingID: clip.recordingID, isDemo: clip.isDemo)
        // General evidence playback uses exactly the same wall-clock lookup as manual markers.
        playEvidence(at: marker.date, recordingID: marker.recordingID, playbackID: marker.id)
    }
}
