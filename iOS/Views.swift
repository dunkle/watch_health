import SwiftUI
import Charts
import WatchMindCore

private enum Palette {
    static let background = AppTheme.canvas
    static let ink = AppTheme.ink
    static let teal = AppTheme.accent
    static let muted = AppTheme.muted
    static let coral = AppTheme.recording
}

struct RootView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    @State private var selectedTab = 0
    @StateObject private var aiSettings = AISettings()
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { NowView(onReview: { model.selectedDay = Date(); selectedTab = 2 }) }.tabItem { Label(l("今天"), systemImage: "leaf").accessibilityIdentifier("tab-today") }.tag(0)
            NavigationStack { TimelineView() }.tabItem { Label(l("片刻"), systemImage: "waveform.path").accessibilityIdentifier("tab-moments") }.tag(1)
            NavigationStack { ReportView() }.tabItem { Label(l("回顾"), systemImage: "sparkles").accessibilityIdentifier("tab-review") }.tag(2)
            NavigationStack { SettingsView() }.tabItem { Label(l("我的"), systemImage: "person.crop.circle").accessibilityIdentifier("tab-settings") }.tag(3)
        }
        .environmentObject(aiSettings)
        .tint(Palette.teal)
        .alert(l("需要留意"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(l("知道了")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .safeAreaInset(edge: .top, spacing: 0) { SessionStatusBar() }
        .sensoryFeedback(.success, trigger: model.lastMarkedID) { _, value in value != nil }
    }
}

private struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { AppCard { content } }
}

private struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) { content }.padding(20).padding(.bottom, 24) }
            .background(Palette.background).foregroundStyle(Palette.ink)
    }
}

struct NowView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    @State private var showConsent = false
    var onReview: () -> Void = {}
    var body: some View {
        Page { DashboardContent(onStart: { showConsent = true }, onReview: onReview) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showConsent) {
            NavigationStack {
                List {
                    Section(l("开启前请了解")) {
                        Text(l("心率小幅变化可开始录音。本次最多 \(model.recordingMinutes) 分钟；可随时停止，没有触发前的声音。"))
                        Text(l("长录音需保持前台，会增加耗电与空间占用。中断时暂停，回到前台且系统允许时尝试续录；不会补录中断空档。"))
                        Text(l("请确保在场的人知情同意。在私密谈话、会议或不适合录音的场景中结束观察。"))
                        Text(model.cleanupNewRecordings ? l("本次已开启：完整转写并可靠保存文字后清理原音频；失败保留，清理后不能播放或重转写。") : l("录音与转写保存在本机。只有你单独确认 AI 复盘时，所选文字和身体信号才会发送到指定接口。原始音频保留到你删除或按设置清理。"))
                        Text(l("手表运动会话可提供更密集心率，但会保存真实运动记录并增加耗电；普通状态下心率采样可能稀疏。"))
                    }
                    Button(l("我了解，允许本次观察触发录音")) { showConsent = false; Task { await model.start() } }
                }.navigationTitle(l("你决定何时记录"))
                    .toolbar { Button(l("取消")) { showConsent = false } }
            }
        }
    }

}

struct EpisodeCard: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel
    private var l: Localizer { Localizer(locale: locale) }
    let event: Episode
    private var excerpt: String { Insights.voiceContext(for: event, events: model.visible) }
    private var statusText: String {
        switch event.status {
        case .recording: return l("正在录音")
        case .paused: return l("录音已暂停")
        case .transcribing: return l("正在本机整理")
        case .failed, .partial, .deferred: return l("待核对")
        case .missed: return l("没有对应声音")
        case .linked: return l("关联片刻")
        case .ready: return event.audioPurgedAt == nil ? l("文字已就绪") : l("文字保留")
        }
    }
    var body: some View {
        Surface {
            ViewThatFits(in: .horizontal) {
                HStack { time; Spacer(); StatusPill(text: statusText, icon: "waveform") }
                VStack(alignment: .leading, spacing: 8) { time; StatusPill(text: statusText, icon: "waveform") }
            }
            Text(excerpt.isEmpty ? l.key(event.note) : "“" + excerpt + "”")
                .font(excerpt.isEmpty ? .body : .title3.weight(.medium)).lineLimit(4)
                .foregroundStyle(excerpt.isEmpty ? Palette.muted : Palette.ink).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Image(systemName: "heart").foregroundStyle(Palette.coral)
                if let baseline = event.trigger.displayBaseline, let bpm = event.trigger.displayBPM {
                    Text(l("\(baseline) → \(bpm) 次/分")).monospacedDigit()
                } else { Text(l("历史心率值不可用，原话仍可核对。")) }
            }.font(.caption).foregroundStyle(Palette.muted)
            Divider().overlay(AppTheme.border)
            ViewThatFits(in: .horizontal) {
                HStack { feeling; Spacer(); source }
                VStack(alignment: .leading, spacing: 8) { feeling; source }
            }
        }
    }
    private var time: some View { Label(l.date(event.trigger.date), systemImage: "clock").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted) }
    private var feeling: some View {
        Text(event.feeling.map { l("本人确认 · \(l.key($0))") } ?? l("感受尚未确认")).font(.caption).foregroundStyle(Palette.muted)
    }
    private var source: some View { Label(l("回到原话核对"), systemImage: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal) }
}

struct TimelineView: View {
    var body: some View { HourJournalView() }
}

struct EpisodeDetail: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var deleting = false
    private var event: Episode? { model.episodes.first { $0.id == id } }
    var body: some View {
        Page {
            if let event {
                Text(l.date(event.trigger.date, includeDate: true, seconds: true)).foregroundStyle(Palette.muted)
                Surface {
                    Label(l("心率变化 · 并非情绪判断"), systemImage: "heart.fill").font(.headline)
                    if let baseline = event.trigger.displayBaseline, let bpm = event.trigger.displayBPM {
                    Chart {
                        BarMark(x: .value(l("类型"), l("近期中位数")), y: .value(l("次/分"), event.trigger.baseline)).foregroundStyle(Palette.teal.opacity(0.4))
                        BarMark(x: .value(l("类型"), l("触发样本")), y: .value(l("次/分"), event.trigger.bpm)).foregroundStyle(Palette.coral)
                    }.frame(height: 150).chartYScale(domain: 0...max(150, event.trigger.bpm + 20))
                    Text(l("\(baseline) → \(bpm) 次/分。\(l.key(event.note))")).font(.subheadline)
                    } else { Text(l("历史心率值不可用，原话仍可核对。")); Text(l.key(event.note)).font(.caption) }
                }
                Surface {
                    HStack {
                        Label(l("语音上下文"), systemImage: "quote.opening").font(.headline)
                        Spacer()
                        if model.recordingOwner(event)?.audioName != nil && model.recordingOwner(event)?.audioPurgedAt == nil && model.recordingOwner(event)?.cleanupPending != true {
                            Button { model.play(event) } label: { Image(systemName: model.playingID == id ? "stop.circle" : "play.circle") }
                                .disabled(model.recordingID != nil).accessibilityLabel(l("播放或停止原始录音"))
                        }
                    }
                    let owner = model.recordingOwner(event)
                    if owner?.cleanupPending == true { Text(l("音频清理待完成，可能已移除部分文件；请在处理中心核对。")).font(.caption) }
                    if owner?.audioPurgedAt != nil {
                        Text(l("原音频已按所选策略清理；文字与来源位置仍保留，不能播放或重转写。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let quality = owner?.audioQuality {
                        Text(l("按第\(quality.sensitivity)档分析 \(Int(quality.analyzedSeconds)) 秒音频，低能量 \(Int(quality.lowEnergySeconds)) 秒；能量值不代表人声或情绪。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let seconds = quality.speechSeconds {
                            Text(l("声音分类器检出语音候选约 \(Int(seconds)) 秒，需核对；不代表情绪或真实身份。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let owner, !owner.segments.isEmpty {
                        NavigationLink(l("选取片段进行 AI 复盘")) { AIReviewComposerView(recordingID: owner.id) }
                        Button(l("收藏附近原话")) { model.saveClip(recordingID: owner.id, at: event.trigger.date) }.disabled(!model.canWriteArchive)
                    }
                    if owner?.status == .recording || owner?.status == .paused || owner?.status == .transcribing {
                        Text(l("录音结束后可播放；本地转写完成后显示文字。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let owner, !owner.transcript.isEmpty {
                        let nearby = event.contextSegments(in: model.episodes).map(\.text).joined(separator: " ")
                        Text(nearby.isEmpty ? l("此标记附近没有成功转写的文字，可播放原始音频核对。") : nearby).textSelection(.enabled)
                        DisclosureGroup(l("展开完整转写")) { Text(owner.transcript).textSelection(.enabled) }
                    } else {
                        Text(l("没有可用转写。\(l.key(event.note))"))
                    }
                    if event.linkedRecordingID != nil {
                        Text(l("关联录音位置：+\(Int(event.audioOffset(in: model.episodes) ?? 0)) 秒。点击播放从该位置开始。"))
                            .font(.caption).foregroundStyle(Palette.teal)
                    }
                    if let parts = owner?.recordingParts, parts.count > 1, owner?.audioPurgedAt == nil, owner?.cleanupPending != true {
                        Text(l("此录音包含 \(parts.count) 个实际片段；中断空档不包含声音。"))
                            .font(.caption).foregroundStyle(Palette.muted)
                        ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                            Button(l("播放片段 \(index + 1) · \(l.date(part.startedAt, seconds: true))")) {
                                model.playPart(part, eventID: id)
                            }.disabled(model.recordingID != nil)
                        }
                    }
                    if let count = owner?.failedTranscriptionChunks, count > 0 {
                        Text(l("有 \(count) 段未能转写，原始音频仍保留。"))
                    }
                    if !(model.recordingOwner(event)?.segments.isEmpty ?? true) {
                        Divider()
                        Text(l("靠近心率事件的文字 · 触发前后20秒窗口")).font(.caption.bold())
                        ForEach(Array(event.contextSegments(in: model.episodes).enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .top) {
                                Text("+\(Int(segment.offset))s").font(.caption.monospaced()).foregroundStyle(Palette.muted)
                                Text(segment.text).foregroundStyle(Palette.teal)
                            }
                        }
                    }
                    ForEach(Insights.moments(in: event.contextSegments(in: model.episodes), language: l.language)) { moment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("+\(Int(moment.offset))s · \(moment.changedFromPrevious ? l("用词线索发生变化") : l("待确认的用词线索"))")
                                .font(.caption.bold()).foregroundStyle(Palette.coral)
                            Text(moment.text)
                            Text(moment.cues.joined(separator: l("、"))).font(.caption).foregroundStyle(Palette.muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text(l("只记录触发后的声音；无法恢复波动前的对话。文字可能有误，请以原始录音和本人反馈核对。"))
                        .font(.caption).foregroundStyle(Palette.muted)
                    if let owner = model.recordingOwner(event), (owner.status == .failed || owner.status == .partial), owner.audioName != nil, owner.audioPurgedAt == nil {
                        Button(l("重试本地转写")) { Task { await model.retry(owner) } }.disabled(model.busy)
                    }
                }
                let manual = model.visibleMarkers.filter { $0.recordingID == (event.linkedRecordingID ?? event.id) }
                if !manual.isEmpty {
                    Surface {
                        Text(l("这段录音中的人工标记")).font(.headline)
                        ForEach(manual.sorted { $0.date < $1.date }) { marker in
                            NavigationLink { MarkerDetail(id: marker.id) } label: { MarkerRow(marker: marker) }
                        }
                    }
                }
                if let assessment = event.assessment {
                    AssessmentView(assessment: assessment, at: event.trigger.date)
                }
                Surface {
                    Text(l("那一刻，你的感受是？")).font(.headline)
                    Text(l("以下文字线索尚未验证：\(Insights.cues(in: event.contextSegments(in: model.episodes).map(\.text).joined(separator: " "), language: l.language).joined(separator: l("、")))"))
                        .font(.caption).foregroundStyle(Palette.muted)
                    LazyVGrid(columns: [.init(.adaptive(minimum: 90))], spacing: 10) {
                        ForEach(["愉快", "紧张", "平静", "身体累", "说不清", "只是运动"], id: \.self) { feeling in
                            Button(l.key(feeling)) { model.confirm(id, feeling: feeling) }
                                .buttonStyle(.bordered).tint(event.feeling == feeling ? Palette.coral : Palette.teal)
                        }
                    }
                    Text(event.feeling.map { l("本人确认：\(l.key($0))") } ?? l("不回答也可以，系统会保留未知。"))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Button(l("删除这条记录和音频"), role: .destructive) { deleting = true }.disabled(model.busy || model.summarizing)
            }
        }.navigationTitle(l("回到那个片刻")).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(l("删除后无法恢复；删除整段录音也会删除关联标记。"), isPresented: $deleting) {
                Button(l("删除记录和音频"), role: .destructive) { if let event { model.delete(event); dismiss() } }
            }
    }
}

struct ReportView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page {
            SectionHeading(title: l("把片刻，串成今天。"), detail: l("事实有出处，感受由本人补充。"))
            NavigationLink { AIReviewLibraryView() } label: {
                FeatureRoute(title: l("AI 复盘工作台"), detail: l("选原话、选身体信号，理解一个具体片刻"), icon: "sparkles.rectangle.stack")
            }.buttonStyle(.plain)
            DatePicker(l("摘要日期"), selection: $model.selectedDay, displayedComponents: .date)
            Surface {
                HStack {
                    StatusPill(text: model.report == nil ? l("等待整理") : l("回顾已就绪"), icon: "sparkles")
                    Spacer()
                    if model.summarizing { ProgressView() }
                }
                Text(model.summaryEvidenceIDs.isEmpty ? l("先留下一点真实片段。") : l("有 \(model.summaryEvidenceIDs.count) 条依据，可整理成回顾。"))
                    .font(.headline)
                Button { Task { await model.summarize() } } label: {
                    Text(model.summarizing ? l("正在本地整理…") : model.report == nil ? l("整理这一天") : l("重新整理回顾"))
                }.buttonStyle(PrimaryActionStyle()).disabled(model.summaryEvidenceIDs.isEmpty || model.summarizing || model.busy)
                Button(l("使用规则摘要")) { model.ruleSummary() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(model.summaryEvidenceIDs.isEmpty || model.summarizing || model.busy)
                Text(l("支持时使用端侧模型，否则提供规则整理。只回顾实际片段，未知不补造。"))
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let report = model.report {
                Surface {
                    SectionHeading(title: l("这一天，值得回看的内容"))
                    Text(report.text).font(.body).lineSpacing(7).textSelection(.enabled)
                    Divider()
                    Text(l.key(report.engine)).font(.caption.weight(.medium)).foregroundStyle(Palette.teal)
                    Text(l("基于 \((report.evidenceIDs ?? report.episodeIDs).count) 条记录 · \(l.date(report.generatedAt)) 生成"))
                        .font(.caption).foregroundStyle(Palette.muted)
                    DisclosureGroup(l("查看这份回顾的依据")) {
                        ForEach(model.visibleMarkers.filter { Calendar.current.isDate($0.date, inSameDayAs: model.selectedDay) }) { marker in
                            NavigationLink { MarkerDetail(id: marker.id) } label: { Label(l("人工标记 · \(l.date(marker.date))"), systemImage: "bookmark") }.frame(minHeight: 44)
                        }
                        ForEach(model.visibleClips.filter { $0.confirmed && Calendar.current.isDate($0.date, inSameDayAs: model.selectedDay) }) { clip in
                            NavigationLink { ClipDetailView(id: clip.id) } label: { Label(l("本人确认的高光"), systemImage: "quote.bubble") }.frame(minHeight: 44)
                        }
                        ForEach(model.dayEvents) { event in
                            NavigationLink { EpisodeDetail(id: event.id) } label: { Label(l("\(l.date(event.trigger.date)) · 核对原话"), systemImage: "waveform.path.ecg") }.frame(minHeight: 44)
                        }
                    }.font(.subheadline)
                }
            }
            NavigationLink { ReflectionView() } label: {
                FeatureRoute(title: l("留一句自己的感受"), detail: l("补充、纠正，或暂时跳过，都可以"), icon: "square.and.pencil")
            }.buttonStyle(.plain)
            DisclosureGroup(l("查看采集覆盖与缺口")) { CoverageView() }.font(.subheadline).padding(.vertical, 8)
            if model.report == nil {
                Text(model.summaryEvidenceIDs.isEmpty ? l("没有记录，不代表没有经历或感受。") : l("依据变化后，请重新整理回顾。"))
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }.navigationTitle(l("回顾"))
    }
}

struct SettingsView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    @State private var erase = false
    var body: some View {
        List {
            Section(l("我的虚拟形象")) {
                NavigationLink { AvatarSettingsView() } label: {
                    HStack { AvatarView(configuration: model.avatar, size: 54); Text(model.avatar.name.isEmpty ? l("定制我的形象") : model.avatar.name) }
                }
            }
            Section(l("语言 / Language")) {
                Picker(l("应用与语音语言"), selection: $model.language) {
                    Text(l("跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }.disabled(model.busy || model.summarizing || model.consenting)
                Text(l("切换界面和新录音的转写语言；旧录音重试保留原语言，旧摘要需重新生成。"))
                    .font(.caption)
            }
            Section(l("记录与回顾")) {
                NavigationLink(l("AI 复盘工作台")) { AIReviewLibraryView() }.accessibilityIdentifier("ai-review-link")
                NavigationLink(l("AI 与模型设置")) { AISettingsView() }.accessibilityIdentifier("ai-settings-link")
                NavigationLink(l("高光与本地搜索")) { JournalLibraryView() }
                NavigationLink(l("我的长期记忆")) { MemoriesView() }
                NavigationLink(l("我的小调整计划")) { PlansView() }
                NavigationLink(l("健康趋势与日常安排")) { HealthOverviewView() }.accessibilityIdentifier("health-overview-link")
                NavigationLink(l("音频与资源设置")) { CapturePolicySettingsView() }
            }
            Section(l("录音与触发设置")) {
                NavigationLink { RecordingDurationView() } label: {
                    LabeledContent(l("最长录音时间"), value: l("\(model.recordingMinutes) 分钟"))
                }.disabled(model.busy || model.observing || model.consenting)
                Toggle(l("观察期间保持屏幕唤醒"), isOn: $model.keepAwake)
                Text(l("默认1小时，可选1分钟至24小时。中断等待计入本次时限；恢复不会重新计时，24小时不是持续录音保证。"))
                    .font(.caption)
                NavigationLink(l("选择辅助触发信号")) { TriggerSignalsView() }
                NavigationLink(l("查看综合算法与健康指标")) { HealthMetricsView() }
            }
            Section(l("运行状态")) {
                NavigationLink(l("查看处理中心")) { ProcessingCenterView() }
                Label(l("端侧优先 · 云端分析由你选择"), systemImage: "iphone.gen3.radiowaves.left.and.right")
                Text(l("前台可触发和恢复录音。来电、锁屏或切后台时保留已录片段；系统允许且回到前台后尝试续录，否则请点击继续。进程终止后不自动开麦，可重试已存音频的转写。"))
                Text(l("小幅触发：至少5次/分且5%；大幅标记：至少20次/分且25%。需要至少5个新鲜样本，事件冷却30秒。多指标只调整事件显著度，不诊断情绪。"))
            }
            Section(l("录音与隐私")) {
                NavigationLink(l("隐私与数据说明")) { PrivacyCenterView() }.accessibilityIdentifier("privacy-center-link")
                NavigationLink(l("帮助与支持")) { SupportCenterView() }.accessibilityIdentifier("support-center-link")
                Text(l("音频、转写和摘要保存在本机，并排除应用主动创建目录的系统备份。无账号、无广告、无分析SDK。"))
                Text(l("可导出本地文字档案，暂不支持导入恢复和音频备份。卸载可能丢失记录；音频清理需单独开启。"))
                Text(l("现场其他人应知情同意。应用不会在未开启观察时录音，也不预先监听。"))
                Button(l("打开系统权限设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section(l("体验界面")) {
                Button(model.demoMode ? l("重新生成模拟数据") : l("进入模拟模式")) { model.loadDemo() }.disabled(model.busy)
                if model.demoMode { Button(l("退出模拟，回到真实记录")) { model.exitDemo() } }
            }
            Section(l("数据管理")) {
                NavigationLink(l("存储与导出")) { StorageManagementView() }
                Text(l("已保存 \(model.episodes.filter { !$0.isDemo }.count) 条真实事件。删除不会修改 Apple 健康中的原始心率。"))
                Button(l("清除全部本地记录与音频"), role: .destructive) { erase = true }.disabled(model.busy || model.summarizing)
            }
            Section(l("能力边界")) {
                Text(l("不能从心率准确判断情绪；文字线索和模型输出都需要本人核对。不用于医疗监测、诊断或紧急告警。"))
                Text(l("摘要模型需 Xcode 26+ 编译、受支持的 iOS 设备、地区和已就绪模型。可用性由系统决定。"))
            }
        }.navigationTitle(l("由你掌控"))
            .confirmationDialog(l("清除全部记录和音频？此操作无法恢复。"), isPresented: $erase) {
                Button(l("清除全部"), role: .destructive) { model.erase() }
            }
    }
}
