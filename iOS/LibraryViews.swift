import SwiftUI
import WatchMindCore

struct JournalLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var personID: UUID?
    private var l: Localizer { Localizer(locale: locale) }
    private var results: [JournalSearchHit] { JournalSearch.find(query, episodes: model.visible, markers: model.visibleMarkers, journal: model.journal, personID: personID) }
    var body: some View {
        List {
            Section {
                NavigationLink(l("人物与对话")) { PeopleView() }
                NavigationLink(l("我的长期记忆")) { MemoriesView() }
                Picker(l("按人物筛选"), selection: $personID) {
                    Text(l("全部人物")).tag(UUID?.none)
                    ForEach(model.visiblePeople) { person in Text(person.name).tag(Optional(person.id)) }
                }
                Text(l("搜索本机转写、人工备注与高光。人物关联由本人确认，不自动识别人名。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || personID != nil {
                Section(l("搜索结果")) {
                    if results.isEmpty { Text(l("没有匹配的本地内容。")) }
                    ForEach(Array(results.prefix(200))) { hit in
                        NavigationLink { SearchEvidenceView(hit: hit) } label: {
                            VStack(alignment: .leading) {
                                Text(l.date(hit.date, includeDate: true, seconds: true)).font(.caption).foregroundStyle(.secondary)
                                Text(hit.text).lineLimit(5)
                            }
                        }
                    }
                    if results.count > 200 { Text(l("仅显示前200项，请缩小搜索范围。")) }
                }
            } else {
                Section(l("高光与收藏")) {
                    Button(l("从当天事件与标记生成候选高光")) { model.suggestHighlights() }.disabled(!model.canWriteArchive)
                    Text(l("候选按已有事件窗口整理，需本人确认；未入选不代表不重要。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.visibleClips.isEmpty { Text(l("在录音详情或人工标记中收藏原话。")) }
                    ForEach(model.visibleClips.sorted { $0.date > $1.date }) { clip in
                        NavigationLink { ClipDetailView(id: clip.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(clip.confirmed ? l("本人确认") : l("待核对候选"), systemImage: clip.confirmed ? "bookmark.fill" : "bookmark")
                                    .font(.caption).foregroundStyle(.teal)
                                Text(clip.text).lineLimit(4)
                                Text(l.date(clip.date, includeDate: true)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle(l("高光与本地搜索"))
            .searchable(text: $query, prompt: l("搜索原话、备注或高光"))
            .onChange(of: model.visiblePeople.map(\.id)) { _, ids in if let id = personID, !ids.contains(id) { personID = nil } }
    }
}
struct SearchEvidenceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let hit: JournalSearchHit
    @State private var playbackID = UUID()
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            if let owner = model.visible.first(where: { $0.id == hit.recordingID }) {
                Text(l.date(hit.date, includeDate: true, seconds: true))
                Text(hit.text).textSelection(.enabled)
                if owner.audioPurgedAt != nil { Text(l("原音频已按所选策略清理；文字与来源位置仍保留，不能播放或重转写。")) }
                else if owner.cleanupPending == true { Text(l("音频清理待完成，可能已移除部分文件；请在处理中心核对。")) }
                else if hit.offset != nil {
                    Button(model.playingID == playbackID ? l("停止播放") : l("播放对应声音")) { model.playEvidence(at: hit.date, recordingID: hit.recordingID, playbackID: playbackID) }.disabled(model.recordingID != nil)
                }
                NavigationLink(l("查看原录音")) { EpisodeDetail(id: owner.id) }
                Button(l("收藏附近原话")) { model.saveClip(recordingID: owner.id, at: hit.date) }.disabled(!model.canWriteArchive)
            } else { Text(l("来源已删除或不可用。")) }
        }.navigationTitle(l("核对来源"))
    }
}
struct ClipDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var confirmed = false
    @State private var memory = ""
    @State private var deleting = false
    let id: UUID
    private var l: Localizer { Localizer(locale: locale) }
    private var clip: EvidenceClip? { model.visibleClips.first { $0.id == id } }
    var body: some View {
        List {
            if let clip {
                Section(l("原话证据")) {
                    Text(l.date(clip.date, includeDate: true, seconds: true))
                    Text(clip.text).textSelection(.enabled)
                    Text(l("这是收藏时的原话快照。重新识别可能改变当前转写，请核对来源。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let owner = model.visible.first(where: { $0.id == clip.recordingID }) {
                        if owner.audioPurgedAt != nil { Text(l("原音频已按所选策略清理；文字与来源位置仍保留，不能播放或重转写。")) }
                        else if owner.cleanupPending == true { Text(l("音频清理待完成，可能已移除部分文件；请在处理中心核对。")) }
                        else if !owner.isDemo { Button(model.playingID == clip.id ? l("停止播放") : l("播放对应声音")) { model.playClip(clip) }.disabled(model.recordingID != nil) }
                        NavigationLink(l("查看原录音")) { EpisodeDetail(id: owner.id) }
                        Button(l("收藏附近原话")) { model.saveClip(recordingID: owner.id, at: clip.date) }.disabled(!model.canWriteArchive)
                    }
                }
                Section(l("本人确认与备注")) {
                    Toggle(l("已核对这条高光"), isOn: $confirmed)
                    TextField(l("备注（最多1000字）"), text: $note, axis: .vertical).onChange(of: note) { _, value in if value.count > 1000 { note = String(value.prefix(1000)) } }
                    Button(l("保存")) { model.editClip(id, note: note, confirmed: confirmed) }.disabled(!model.canWriteArchive)
                }
                Section(l("关联人物")) {
                    if model.visiblePeople.isEmpty { NavigationLink(l("先添加人物昵称")) { PeopleView() } }
                    ForEach(model.visiblePeople) { person in
                        Button { model.linkPerson(person.id, clipID: id) } label: {
                            HStack { Text(person.name); Spacer(); if clip.personIDs.contains(person.id) { Image(systemName: "checkmark") } }
                        }.disabled(!model.canWriteArchive)
                    }
                }
                Section(l("保存为可管理记忆")) {
                    TextField(l("你希望长期记住什么？"), text: $memory, axis: .vertical)
                    Button(l("创建记忆")) { model.addMemory(clipID: id, text: memory); memory = "" }
                        .disabled(!clip.confirmed || memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canWriteArchive)
                    Text(l("先保存本人确认，再创建记忆。来源删除或撤销确认后，记忆会停用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(l("删除高光，保留原录音"), role: .destructive) { deleting = true }.disabled(!model.canWriteArchive)
            } else { Text(l("来源已删除或不可用。")) }
        }.navigationTitle(l("高光详情"))
            .onAppear { note = clip?.note ?? ""; confirmed = clip?.confirmed ?? false }
            .onChange(of: clip?.confirmed) { _, value in confirmed = value ?? false }
            .confirmationDialog(l("删除这条高光？关联记忆将停用。"), isPresented: $deleting) {
                Button(l("删除"), role: .destructive) { model.deleteClip(id); dismiss() }
            }
    }
}
struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var name = ""
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section {
                TextField(l("人物昵称"), text: $name)
                Button(l("添加人物")) { model.addPerson(name); name = "" }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canWriteArchive)
                Text(l("人物由你手动建立和关联；没有声纹识别，也不猜测真实身份。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.visiblePeople) { person in NavigationLink(person.name) { PersonDetailView(id: person.id) } }
        }.navigationTitle(l("人物与对话"))
    }
}
struct PersonDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var deleting = false
    let id: UUID
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            TextField(l("人物昵称"), text: $name)
            Button(l("保存昵称")) { model.renamePerson(id, name: name) }.disabled(!model.canWriteArchive)
            ForEach(model.visibleClips.filter { $0.personIDs.contains(id) }) { clip in
                NavigationLink { ClipDetailView(id: clip.id) } label: { Text(clip.text).lineLimit(4) }
            }
            Button(l("删除人物，保留对话"), role: .destructive) { deleting = true }.disabled(!model.canWriteArchive)
        }.navigationTitle(l("人物详情"))
            .onAppear { name = model.visiblePeople.first { $0.id == id }?.name ?? "" }
            .confirmationDialog(l("删除人物会移除关联，原始对话会保留。"), isPresented: $deleting) {
                Button(l("删除"), role: .destructive) { model.deletePerson(id); dismiss() }
            }
    }
}
struct MemoriesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Text(l("记忆来自你确认的高光，可编辑、停用或删除。启用的记忆可作为端侧摘要的历史背景，不是今天发生事件的证据。"))
                .font(.caption).foregroundStyle(.secondary)
            if model.visibleMemories.isEmpty { Text(l("先在高光详情中创建一条记忆。")) }
            ForEach(model.visibleMemories) { memory in
                NavigationLink { MemoryDetailView(id: memory.id) } label: {
                    VStack(alignment: .leading) { Text(memory.text).lineLimit(4); Text(memory.enabled ? l("已启用") : l("已停用")).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle(l("我的长期记忆"))
    }
}
struct MemoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var enabled = false
    @State private var deleting = false
    let id: UUID
    private var l: Localizer { Localizer(locale: locale) }
    private var memory: JournalMemory? { model.visibleMemories.first { $0.id == id } }
    var body: some View {
        List {
            if let memory {
                TextField(l("记忆内容（最多1000字）"), text: $text, axis: .vertical).onChange(of: text) { _, value in if value.count > 1000 { text = String(value.prefix(1000)) } }
                Toggle(l("启用这条记忆"), isOn: $enabled).disabled(!model.journal.memoryHasSources(memory))
                if !model.journal.memoryHasSources(memory) { Text(l("来源缺失或尚未确认，记忆保持停用。")) }
                Button(l("保存")) { model.editMemory(id, text: text, enabled: enabled) }.disabled(!model.canWriteArchive)
                ForEach(model.visibleClips.filter { memory.clipIDs.contains($0.id) }) { clip in
                    NavigationLink(l("核对来源")) { ClipDetailView(id: clip.id) }
                }
                Button(l("删除记忆"), role: .destructive) { deleting = true }.disabled(!model.canWriteArchive)
            }
        }.navigationTitle(l("记忆详情"))
            .onAppear { text = memory?.text ?? ""; enabled = memory?.enabled ?? false }
            .confirmationDialog(l("删除记忆？原始高光和录音会保留。"), isPresented: $deleting) {
                Button(l("删除"), role: .destructive) { model.deleteMemory(id); dismiss() }
            }
    }
}
