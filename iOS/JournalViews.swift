import SwiftUI
import WatchMindCore

struct MarkerRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    let marker: MomentMarker
    private var excerpt: String {
        marker.note.isEmpty ? marker.context(in: model.visible).map(\.text).joined(separator: " ") : marker.note
    }
    var body: some View {
        AppCard {
            ViewThatFits(in: .horizontal) {
                HStack { StatusPill(text: l("主动标记"), icon: "bookmark.fill"); Spacer(); time }
                VStack(alignment: .leading, spacing: 8) { StatusPill(text: l("主动标记"), icon: "bookmark.fill"); time }
            }
            Text(excerpt.isEmpty ? l("你为这个时刻留了一个位置。") : excerpt)
                .font(excerpt.isEmpty ? .body : .title3.weight(.medium)).foregroundStyle(AppTheme.ink)
                .lineLimit(4).multilineTextAlignment(.leading)
            Label(l("查看这个时刻"), systemImage: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
        }
    }
    private var time: some View { Text(l.date(marker.date, seconds: true)).font(.caption).foregroundStyle(AppTheme.muted) }
}

struct MarkerDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var deleting = false
    let id: UUID
    private var l: Localizer { Localizer(locale: locale) }
    private var marker: MomentMarker? { model.markers.first { $0.id == id } }
    var body: some View {
        List {
            if let marker {
                Section {
                    Label(l("人工标记"), systemImage: "bookmark.fill")
                    Text(l.date(marker.date, includeDate: true, seconds: true))
                    Text(l("由你主动标记，不代表心率或情绪判断。")).font(.caption).foregroundStyle(.secondary)
                    TextField(l("备注（最多500字）"), text: $note, axis: .vertical)
                        .onChange(of: note) { _, value in if value.count > 500 { note = String(value.prefix(500)) } }
                    Button(l("保存备注")) { model.updateMarker(id, note: note) }.disabled(!model.canWriteArchive)
                }
                Section(l("对应的声音与文字")) {
                    if marker.isDemo {
                        Text(l("模拟数据，不来自传感器或真实录音。"))
                    } else if marker.owner(in: model.episodes)?.cleanupPending == true {
                        Text(l("音频清理待完成，可能已移除部分文件；请在处理中心核对。"))
                    } else if marker.owner(in: model.episodes)?.audioPurgedAt != nil {
                        Text(l("原音频已按所选策略清理；文字与来源位置仍保留，不能播放或重转写。"))
                    } else if marker.audioLocation(in: model.episodes) == nil {
                        Text(l("此事件发生在录音中断的空档，没有对应音频。"))
                    } else {
                        Button(model.playingID == id ? l("停止播放") : l("从标记位置播放")) { model.playMarker(marker) }
                            .disabled(model.recordingID != nil)
                    }
                    let context = marker.context(in: model.episodes)
                    if context.isEmpty { Text(l("标记前后20秒内暂无成功转写的文字。")) }
                    ForEach(Array(context.enumerated()), id: \.offset) { _, segment in
                        Text("+\(Int(segment.offset))s · " + segment.text).textSelection(.enabled)
                    }
                    if let owner = marker.owner(in: model.episodes) {
                        if !context.isEmpty { Button(l("收藏附近原话")) { model.saveClip(recordingID: owner.id, at: marker.date) }.disabled(!model.canWriteArchive) }
                        NavigationLink(l("查看所属录音与处理状态")) { EpisodeDetail(id: owner.id) }
                    }
                }
                Section {
                    Text(l("删除标记会保留所属录音；删除所属录音会一并删除标记。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(l("删除这个标记"), role: .destructive) { deleting = true }.disabled(!model.canWriteArchive)
                }
            } else { Text(l("记录已删除或不可用。")) }
        }.navigationTitle(l("人工标记"))
            .onAppear { note = marker?.note ?? "" }
            .confirmationDialog(l("删除这个标记？原始录音会保留。"), isPresented: $deleting) {
                Button(l("删除标记"), role: .destructive) { model.deleteMarker(id); dismiss() }
            }
    }
}

struct HourJournalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedHour: Date?
    private var l: Localizer { Localizer(locale: locale) }
    private var hours: [HourBucket] { model.hourBuckets.filter { !$0.isEmpty } }
    private func label(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = l.locale; formatter.timeZone = .current
        let hour = Calendar.current.component(.hour, from: date)
        let repeated = model.hourBuckets.filter { Calendar.current.component(.hour, from: $0.start) == hour }.count > 1
        formatter.dateFormat = repeated ? "HH:mm XXX" : "HH:mm" // Offsets appear only where an hour is ambiguous.
        return formatter.string(from: date)
    }
    private struct Row: Identifiable {
        let id: UUID
        let date: Date
        let event: Episode?
        let marker: MomentMarker?
    }
    private func rows(_ hour: HourBucket) -> [Row] {
        let events = model.visible.filter { hour.eventIDs.contains($0.id) }.map { Row(id: $0.id, date: $0.trigger.date, event: $0, marker: nil) }
        let markers = model.visibleMarkers.filter { hour.markerIDs.contains($0.id) }.map { Row(id: $0.id, date: $0.date, event: nil, marker: $0) }
        return (events + markers).sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    DatePicker(l("选择日期"), selection: $model.selectedDay, displayedComponents: .date).datePickerStyle(.compact)
                    SectionHeading(title: l("每个片刻，都有依据。"), detail: l("按时间找回原话，也看见没有录到的空白。"))
                    NavigationLink { JournalLibraryView() } label: {
                        FeatureRoute(title: l("搜索原话与高光"), detail: l("从一句话，回到那段生活"), icon: "text.magnifyingglass")
                    }.buttonStyle(.plain)
                    DisclosureGroup(l("心率与片刻的时间线")) { HeartCurveView(day: model.selectedDay) }
                        .font(.subheadline.weight(.semibold)).padding(.vertical, 6)
                    NavigationLink(l("查看处理中心")) { ProcessingCenterView() }.font(.caption).frame(minHeight: 44)
                    if hours.isEmpty {
                        ContentUnavailableView(l("这一天还没有记录"), systemImage: "waveform", description: Text(l("未记录不代表没有情绪变化。")))
                    } else {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(hours) { hour in
                                    Button {
                                        selectedHour = hour.id
                                        if reduceMotion { proxy.scrollTo(hour.id, anchor: .top) }
                                        else { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(hour.id, anchor: .top) } }
                                    } label: {
                                        Text(label(hour.start)).font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(minHeight: 44)
                                            .foregroundStyle(selectedHour == hour.id ? Color.white : AppTheme.accent)
                                            .background(selectedHour == hour.id ? AppTheme.buttonFill : AppTheme.raised, in: Capsule())
                                    }.buttonStyle(.plain).accessibilityAddTraits(selectedHour == hour.id ? [.isSelected] : [])
                                }
                            }
                        }
                        Text(l("仅显示有记录的小时；时区偏移用于区分重复小时。跨小时录音引用同一原文件。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(hours) { hour in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(label(hour.start) + " – " + label(hour.end)).font(.headline)
                            ForEach(rows(hour)) { row in
                                if let event = row.event {
                                    NavigationLink { EpisodeDetail(id: event.id) } label: { EpisodeCard(event: event) }.buttonStyle(.plain)
                                } else if let marker = row.marker {
                                    NavigationLink { MarkerDetail(id: marker.id) } label: { MarkerRow(marker: marker) }.buttonStyle(.plain)
                                }
                            }
                            ForEach(model.visible.filter { hour.continuationIDs.contains($0.id) }) { owner in
                                NavigationLink { EpisodeDetail(id: owner.id) } label: {
                                    Label(l("本小时仍有录音 · 开始于 \(l.date(owner.captureStarted ?? owner.trigger.date, includeDate: true))"), systemImage: "arrow.turn.down.right")
                                        .font(.subheadline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                }
                            }
                        }.id(hour.id)
                    }
                }.padding(20)
            }.background(AppTheme.canvas)
        }.navigationTitle(l("片刻"))
    }
}

struct ProcessingCenterView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    private var owners: [Episode] { model.visible.filter { $0.linkedRecordingID == nil }.sorted { $0.trigger.date > $1.trigger.date } }
    private func stage(_ title: String, _ value: ProcessingStage) -> some View {
        LabeledContent(title, value: l.key(value.title)).font(.subheadline)
    }
    var body: some View {
        List {
            Section(l("设备与本地保存")) {
                Text(model.watchReachable.map { $0 ? l("Watch当前可连接") : l("Watch当前不可连接") } ?? l("Watch连接状态尚未确认"))
                if let date = model.lastWatchPacketAt { Text(l("最近收到Watch数据：\(l.date(date, includeDate: true, seconds: true))")) }
                Text(l("当前Watch只传输心率与事件，录音保存在手机；没有手表音频同步队列。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.storagePaused {
                    Text(l("设备锁定，暂缓写入；解锁后自动重试保存。"))
                } else if !model.canWriteArchive {
                    Text(l("本地档案读取或写入受阻，采集不可用；请先处理存储错误。"))
                        .foregroundStyle(.red)
                } else {
                    Text(l("档案状态依据本机记录，音频可用性以实际播放和转写结果为准。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(l("每日摘要")) {
                DatePicker(l("摘要日期"), selection: $model.selectedDay, displayedComponents: .date)
                if model.summarizing, let day = model.summaryDay {
                    HStack { ProgressView(); Text(l("正在整理 \(l.date(day, includeDate: true)) 的摘要")) }
                }
                if let report = model.report {
                    stage(l("摘要"), .complete); Text(l.key(report.engine)).font(.caption)
                } else if let failure = model.summaryFailure, let day = model.summaryDay, Calendar.current.isDate(day, inSameDayAs: model.selectedDay) {
                    stage(l("摘要"), .failed); Text(failure).font(.caption)
                } else if !model.summarizing { stage(l("摘要"), model.summaryEvidenceIDs.isEmpty ? .unavailable : .pending) }
                Button(l("生成每日摘要")) { Task { await model.summarize() } }.disabled(model.summaryEvidenceIDs.isEmpty || model.busy || model.summarizing)
                Button(l("使用规则摘要")) { model.ruleSummary() }.disabled(model.summaryEvidenceIDs.isEmpty || model.busy || model.summarizing)
            }
            Section(l("录音与转写任务")) {
                if owners.isEmpty { Text(l("暂无录音任务。")) }
                ForEach(owners) { owner in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink { EpisodeDetail(id: owner.id) } label: { Text(l.date(owner.trigger.date, includeDate: true, seconds: true)).font(.headline) }
                        stage(l("录音"), owner.recordingStage)
                        stage(l("本地转写"), owner.transcriptionStage)
                        Text(l.key(owner.note)).font(.caption).foregroundStyle(.secondary)
                        if owner.audioPurgedAt != nil { Text(l("原音频已清理，文字保留。")).font(.caption) }
                        if owner.audioPurgedAt == nil, owner.cleanupAfterTranscription == true, owner.status == .ready {
                            Button(l("继续清理原音频")) { model.requestCleanup(owner.id) }.disabled(model.busy || !model.canWriteArchive)
                            if owner.cleanupStartedAt == nil {
                                Button(l("保留原音频，取消清理")) { model.cancelCleanup(owner.id) }.disabled(!model.canWriteArchive)
                            }
                        }
                        if model.transcriptionID == owner.id, model.transcriptionTotal > 0 {
                            Text(l("当前已处理分段：\(model.transcriptionCompleted)/\(model.transcriptionTotal)"))
                            ProgressView(value: Double(model.transcriptionCompleted), total: Double(max(1, model.transcriptionTotal)))
                        }
                        if model.recordingID == owner.id {
                            if model.recordingPaused { Button(l("继续录音")) { model.resumeRecording() } }
                            Button(l("结束并转写")) { model.stopRecording() }
                        } else if (owner.status == .failed || owner.status == .partial || owner.status == .deferred), owner.audioPurgedAt == nil, !owner.audioNames.isEmpty, !owner.isDemo {
                            Button(l("重试本地转写")) { Task { await model.retry(owner) } }.disabled(model.busy || !model.canWriteArchive)
                        }
                    }.padding(.vertical, 5)
                }
            }
            Section {
                Text(l("仅展示已存在的本地任务，不会自动批量重试。系统终止后未完成任务需手动恢复转写。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(l("处理中心"))
    }
}
