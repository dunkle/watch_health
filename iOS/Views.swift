import SwiftUI
import Charts
import WatchMindCore

private enum Palette {
    static let background = Color(red: 0.96, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.12, green: 0.23, blue: 0.21)
    static let teal = Color(red: 0.20, green: 0.45, blue: 0.37)
    static let muted = Color(red: 0.43, green: 0.48, blue: 0.44)
    static let coral = Color(red: 0.75, green: 0.39, blue: 0.32)
}

struct RootView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { NowView() }.tabItem { Label(l("现在"), systemImage: "leaf") }
            NavigationStack { TimelineView() }.tabItem { Label(l("记录"), systemImage: "waveform.path") }
            NavigationStack { ReportView() }.tabItem { Label(l("每日摘要"), systemImage: "sparkles") }
            NavigationStack { SettingsView() }.tabItem { Label(l("设置"), systemImage: "slider.horizontal.3") }
        }
        .tint(Palette.teal)
        .preferredColorScheme(.light)
        .alert(l("需要留意"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(l("知道了")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.recordingID != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.recordingPaused ? l("录音已暂停") : l("正在录音"),
                          systemImage: model.recordingPaused ? "pause.circle.fill" : "record.circle.fill")
                        .font(.subheadline.bold())
                    Text(l("本次上限 \(Int((model.currentRecording?.maximumDuration ?? 3600) / 60)) 分钟，包含中断等待时间"))
                        .font(.caption)
                    if model.recordingPaused, let note = model.currentRecording?.note {
                        Text(l.key(note)).font(.caption)
                    }
                    HStack {
                        Button(l("标记此刻")) { model.markMoment() }
                            .disabled(model.storagePaused)
                        if model.recordingPaused { Button(l("继续录音")) { model.resumeRecording() } }
                        Button(l("结束并转写")) { model.stopRecording() }
                    }.buttonStyle(.bordered).font(.subheadline.bold()).tint(.white)
                    if let id = model.lastMarkedID, let marker = model.markers.first(where: { $0.id == id && $0.recordingID == model.recordingID }) {
                        Text(l("已标记：\(l.date(marker.date, seconds: true))，可在记录页添加备注。"))
                            .font(.caption).accessibilityAddTraits(.updatesFrequently)
                    }
                }.foregroundStyle(.white).padding().frame(maxWidth: .infinity, alignment: .leading).background(Palette.coral)
                .accessibilityElement(children: .contain)
                if let recording = model.currentRecording, let start = recording.captureStarted {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                        ProgressView(value: min(max(0, context.date.timeIntervalSince(start)), recording.maximumDuration ?? 3600), total: recording.maximumDuration ?? 3600)
                            .padding(.horizontal)
                    }
                }
            } else if model.busy && model.transcriptionTotal > 0 {
                VStack {
                    Text(l("本地分段转写：\(model.transcriptionCompleted)/\(model.transcriptionTotal)"))
                    ProgressView(value: Double(model.transcriptionCompleted), total: Double(model.transcriptionTotal))
                }.font(.caption).padding(10)
            } else if model.storagePaused {
                Text(l("设备锁定，暂缓写入；解锁后自动重试保存。"))
                    .font(.caption).padding(10).frame(maxWidth: .infinity).background(Color.yellow.opacity(0.25))
            } else if model.demoMode {
                HStack { Text(l("演示模式 · 全部为模拟数据")); Spacer(); Button(l("退出")) { model.exitDemo() } }
                    .font(.caption).padding(10).background(Color.yellow.opacity(0.25))
            }
        }
    }
}

private struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
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
    private var today: [Episode] { Insights.events(on: Date(), from: model.visible) }
    var body: some View {
        Page {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(), format: .dateTime.month().day().weekday()).font(.caption).foregroundStyle(Palette.muted)
                    Text(l("听见此刻的自己")).font(.largeTitle.bold())
                }
                Spacer(); Image(systemName: "leaf.circle.fill").font(.system(size: 42)).foregroundStyle(Palette.teal)
            }
            CompanionView()
            Surface {
                HStack {
                    Label(model.observing ? l("观察已开启") : l("留一点空间给自己"), systemImage: model.observing ? "dot.radiowaves.left.and.right" : "sun.horizon")
                        .font(.subheadline.weight(.medium))
                    Spacer(); Circle().fill(model.observing ? Palette.teal : .gray.opacity(0.4)).frame(width: 8, height: 8)
                }
                if let bpm = model.latestBPM, let time = model.latestSampleAt, abs(time.timeIntervalSinceNow) < 60 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(bpm))").font(.system(size: 64, weight: .light, design: .rounded))
                        Text(l("次/分")).foregroundStyle(Palette.muted)
                        Spacer(); Image(systemName: "heart.fill").foregroundStyle(Palette.coral).font(.title)
                    }
                    Text(l("最近样本：\(l.date(time, seconds: true))，非连续实时保证")).font(.caption).foregroundStyle(Palette.muted)
                } else {
                    Text(l("身体的变化，\n值得被温柔地记录。")).font(.title2.weight(.medium)).lineSpacing(6)
                    Text(l("开启后等待新鲜心率数据，波动时记录一小段语音。没有数据时不推断你的心情。"))
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                if model.observing {
                    Button { model.stop() } label: { Label(l("结束观察"), systemImage: "pause.fill").frame(maxWidth: .infinity).padding(6) }
                        .buttonStyle(.borderedProminent).disabled(model.consenting)
                    Text(model.foreground ? l("前台可触发录音 · 手机需在你附近") : l("后台仅记事件，不自动开启麦克风"))
                        .font(.caption).foregroundStyle(Palette.muted)
                } else {
                    Button { showConsent = true } label: {
                        Label(model.consenting ? l("正在请求权限…") : l("开启观察"), systemImage: "waveform")
                            .frame(maxWidth: .infinity).padding(6)
                    }.buttonStyle(.borderedProminent).disabled(model.demoMode || model.busy || model.consenting)
                    Text(l("只在你开启的会话中触发 · 不预先监听")).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            HeartCurveView(day: Date())
            NavigationLink { HealthMetricsView() } label: {
                Label(l("健康指标与数据时效"), systemImage: "heart.text.clipboard")
            }
            NavigationLink(l("查看处理中心")) { ProcessingCenterView() }
            HStack(spacing: 12) {
                metric(l("今日波动"), value: "\(today.count)", icon: "waveform.path.ecg")
                metric(l("语音片段"), value: "\(today.filter { $0.status == .ready || $0.status == .partial }.count)", icon: "quote.bubble")
                metric(l("感受确认"), value: "\(today.filter { $0.feeling != nil }.count)", icon: "face.smiling")
            }
            HStack { Text(l("最近的片刻")).font(.title3.bold()); Spacer(); Text(l("保存在本机")).font(.caption).foregroundStyle(Palette.muted) }
            if let event = model.visible.sorted(by: { $0.trigger.date > $1.trigger.date }).first {
                NavigationLink { EpisodeDetail(id: event.id) } label: { EpisodeCard(event: event) }.buttonStyle(.plain)
            } else {
                Surface {
                    Label(l("你的故事还未开始"), systemImage: "text.bubble")
                    Text(l("记录会出现在这里。先体验界面，也可以直接开启真实观察。"))
                        .font(.subheadline).foregroundStyle(Palette.muted)
                    Button(l("查看模拟记录")) { model.loadDemo() }.disabled(model.busy)
                }
            }
            Label(l("心率波动只是线索，不代表情绪变化或健康诊断。"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(Palette.muted)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showConsent) {
            NavigationStack {
                List {
                    Section(l("开启前请了解")) {
                        Text(l("心率小幅变化可开始录音。本次最多 \(model.recordingMinutes) 分钟；可随时停止，没有触发前的声音。"))
                        Text(l("长录音需保持前台，会增加耗电与空间占用。中断时暂停，回到前台且系统允许时尝试续录；不会补录中断空档。"))
                        Text(l("请确保在场的人知情同意。在私密谈话、会议或不适合录音的场景中结束观察。"))
                        Text(l("本地转写和本地摘要，不上传档案。原始音频保存在应用中，直到你删除。"))
                        Text(l("手表运动会话可提供更密集心率，但会保存真实运动记录并增加耗电；普通状态下心率采样可能稀疏。"))
                    }
                    Button(l("我了解，允许本次观察触发录音")) { showConsent = false; Task { await model.start() } }
                }.navigationTitle(l("你决定何时记录"))
                    .toolbar { Button(l("取消")) { showConsent = false } }
            }
        }
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Palette.teal)
            Text(value).font(.title.bold()); Text(title).font(.caption).foregroundStyle(Palette.muted)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct EpisodeCard: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    let event: Episode
    var body: some View {
        Surface {
            HStack {
                Label(l.date(event.trigger.date), systemImage: "heart.text.square")
                Spacer(); Text(l("\(Int(event.trigger.bpm)) 次/分")).foregroundStyle(Palette.coral)
            }.font(.subheadline.weight(.medium))
            Text(event.transcript.isEmpty ? l.key(event.note) : event.transcript).font(.body).lineLimit(3).multilineTextAlignment(.leading)
            HStack {
                Text(event.feeling.map { l("本人确认 · \(l.key($0))") } ?? l("感受尚未确认"))
                Spacer(); Image(systemName: "arrow.up.right")
            }.font(.caption).foregroundStyle(Palette.muted)
        }
    }
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
                    Chart {
                        BarMark(x: .value(l("类型"), l("近期中位数")), y: .value(l("次/分"), event.trigger.baseline)).foregroundStyle(Palette.teal.opacity(0.4))
                        BarMark(x: .value(l("类型"), l("触发样本")), y: .value(l("次/分"), event.trigger.bpm)).foregroundStyle(Palette.coral)
                    }.frame(height: 150).chartYScale(domain: 0...max(150, event.trigger.bpm + 20))
                    Text(l("\(Int(event.trigger.baseline)) → \(Int(event.trigger.bpm)) 次/分。\(l.key(event.note))")).font(.subheadline)
                }
                Surface {
                    HStack {
                        Label(l("语音上下文"), systemImage: "quote.opening").font(.headline)
                        Spacer()
                        if model.recordingOwner(event)?.audioName != nil {
                            Button { model.play(event) } label: { Image(systemName: model.playingID == id ? "stop.circle" : "play.circle") }
                                .disabled(model.recordingID != nil).accessibilityLabel(l("播放或停止原始录音"))
                        }
                    }
                    let owner = model.recordingOwner(event)
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
                    if let parts = owner?.recordingParts, parts.count > 1 {
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
                    if let owner = model.recordingOwner(event), (owner.status == .failed || owner.status == .partial), owner.audioName != nil {
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
            HStack { AvatarView(configuration: model.avatar, size: 62); Text(l("和你一起回顾今天")).font(.headline) }
            DatePicker(l("摘要日期"), selection: $model.selectedDay, displayedComponents: .date)
            Surface {
                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Palette.teal)
                Text(l("把零散的片刻，\n整理成一天的故事。")).font(.title2.weight(.medium)).lineSpacing(5)
                Text(l("只使用当天记录。设备支持时调用 Apple 端侧模型；否则生成清楚标注的规则摘要，不切换云端。"))
                    .font(.subheadline).foregroundStyle(Palette.muted)
                Button { Task { await model.summarize() } } label: {
                    HStack { if model.summarizing { ProgressView() }; Text(model.summarizing ? l("正在本地整理…") : l("生成每日摘要")) }.frame(maxWidth: .infinity).padding(6)
                }.buttonStyle(.borderedProminent).disabled(model.dayEvents.isEmpty || model.summarizing || model.busy)
                Button(l("使用规则摘要")) { model.ruleSummary() }.disabled(model.dayEvents.isEmpty || model.summarizing || model.busy)
            }
            if let report = model.report {
                Surface {
                    Text(l.key(report.engine)).font(.caption.bold()).foregroundStyle(Palette.teal)
                    Text(report.text).lineSpacing(7).textSelection(.enabled)
                    Divider()
                    Text(l("基于 \(report.episodeIDs.count) 条记录 · \(l.date(report.generatedAt)) 生成"))
                        .font(.caption).foregroundStyle(Palette.muted)
                    ForEach(model.dayEvents) { event in
                        NavigationLink { EpisodeDetail(id: event.id) } label: {
                            Text(l("\(l.date(event.trigger.date)) · \(event.id.uuidString.prefix(8)) · 核对依据"))
                        }.font(.caption)
                    }
                }
            } else {
                Text(model.dayEvents.isEmpty ? l("先留下一个片刻，再生成摘要。") : l("尚无当前证据的摘要，或记录已变化，请重新生成。"))
                    .foregroundStyle(Palette.muted).font(.subheadline)
            }
        }.navigationTitle(l("每日回顾"))
    }
}

struct SettingsView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: AppModel
    @State private var erase = false
    var body: some View {
        List {
            Section(l("语言 / Language")) {
                Picker(l("应用与语音语言"), selection: $model.language) {
                    Text(l("跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }.disabled(model.busy || model.summarizing || model.consenting)
                Text(l("切换界面和新录音的转写语言；旧录音重试保留原语言，旧摘要需重新生成。"))
                    .font(.caption)
            }
            Section(l("我的虚拟形象")) {
                NavigationLink { AvatarSettingsView() } label: {
                    HStack { AvatarView(configuration: model.avatar, size: 54); Text(model.avatar.name.isEmpty ? l("定制我的形象") : model.avatar.name) }
                }
            }
            Section(l("录音与触发设置")) {
                NavigationLink { RecordingDurationView() } label: {
                    LabeledContent(l("最长录音时间"), value: l("\(model.recordingMinutes) 分钟"))
                }.disabled(model.busy || model.observing || model.consenting)
                Toggle(l("观察期间保持屏幕唤醒"), isOn: $model.keepAwake)
                Text(l("默认1小时，可选1分钟至24小时。中断等待计入本次时限；恢复不会重新计时，24小时不是持续录音保证。"))
                    .font(.caption)
                NavigationLink(l("查看综合算法与健康指标")) { HealthMetricsView() }
            }
            Section(l("运行状态")) {
                NavigationLink(l("查看处理中心")) { ProcessingCenterView() }
                Label(l("端侧优先 · 无云端接口"), systemImage: "iphone.gen3.radiowaves.left.and.right")
                Text(l("前台可触发和恢复录音。来电、锁屏或切后台时保留已录片段；系统允许且回到前台后尝试续录，否则请点击继续。进程终止后不自动开麦，可重试已存音频的转写。"))
                Text(l("小幅触发：至少5次/分且5%；大幅标记：至少20次/分且25%。需要至少5个新鲜样本，事件冷却30秒。多指标只调整事件显著度，不诊断情绪。"))
            }
            Section(l("录音与隐私")) {
                Text(l("音频、转写和摘要保存在本机，并排除应用主动创建目录的系统备份。无账号、无广告、无分析SDK。"))
                Text(l("当前不提供备份恢复；卸载可能丢失全部记录。原始音频不会自动过期，请定期删除。"))
                Text(l("现场其他人应知情同意。应用不会在未开启观察时录音，也不预先监听。"))
                Button(l("打开系统权限设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section(l("体验界面")) {
                Button(model.demoMode ? l("重新生成模拟数据") : l("进入模拟模式")) { model.loadDemo() }.disabled(model.busy)
                if model.demoMode { Button(l("退出模拟，回到真实记录")) { model.exitDemo() } }
            }
            Section(l("数据管理")) {
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
