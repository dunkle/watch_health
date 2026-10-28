import SwiftUI
import Charts
import WatchMindCore

struct CoverageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        let value = model.coverage
        VStack(alignment: .leading, spacing: 8) {
            Text(l("今天记录到了多少")).font(.headline)
            Text(value.observed.map { l("观察开启：\(Int($0 / 60)) 分钟") } ?? l("观察时长未知，旧记录不补造分母。"))
            Text(l("实际录音：\(Int(value.recorded)) 秒；成功处理：\(Int(value.processed)) 秒；失败范围：\(Int(value.failed)) 秒"))
            Text(l("已跳过未检出语音片段：\(Int(value.skipped)) 秒，可手动完整重试。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(l("这些是实际片段的时间覆盖，不代表全天经历、情绪准确率或说话时长。心率未触发和录音空档仍是未知。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
struct ReflectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var text = ""
    private var l: Localizer { Localizer(locale: locale) }
    private var saved: String { model.journal.reflections.last { $0.isDemo == model.demoMode && Calendar.current.isDate($0.day, inSameDayAs: model.selectedDay) }?.text ?? "" }
    var body: some View {
        List {
            DatePicker(l("回顾日期"), selection: $model.selectedDay, displayedComponents: .date)
            CoverageView()
            Section(l("当天有依据的片刻")) {
                ForEach(model.dayEvents) { event in
                    NavigationLink { EpisodeDetail(id: event.id) } label: {
                        Text(Insights.voiceContext(for: event, events: model.visible).isEmpty ? l("此事件没有可用原话。") : Insights.voiceContext(for: event, events: model.visible)).lineLimit(4)
                    }
                }
                ForEach(model.visibleMarkers.filter { Calendar.current.isDate($0.date, inSameDayAs: model.selectedDay) }) { marker in
                    NavigationLink { MarkerDetail(id: marker.id) } label: { Text(marker.note.isEmpty ? l("人工标记") : marker.note) }
                }
                ForEach(model.visibleClips.filter { $0.confirmed && Calendar.current.isDate($0.date, inSameDayAs: model.selectedDay) }) { clip in
                    NavigationLink { ClipDetailView(id: clip.id) } label: { Text(clip.text).lineLimit(4) }
                }
            }
            Section(l("可选反思，允许跳过")) {
                Text(l("今天哪个有记录的片刻值得记住？你如何理解它，还有哪些地方无法确认？"))
                TextField(l("写下本人感受或纠正（最多2000字）"), text: $text, axis: .vertical)
                    .onChange(of: text) { _, value in if value.count > 2000 { text = String(value.prefix(2000)) } }
                Button(l("保存反思")) { model.saveReflection(text) }.disabled(!model.canWriteArchive)
                Text(l("清空后保存即可删除。反思是本人输入，不替换事实，也不自动变成任务。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink(l("我的小调整计划")) { PlansView() }
        }.navigationTitle(l("片段回顾与反思"))
            .onAppear { text = saved }
            .onChange(of: model.selectedDay) { _, _ in text = saved }
    }
}
struct PlansView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var title = ""
    @State private var note = ""
    @State private var deletingID: UUID?
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section {
                Text(l("一次尝试一个小调整。计划由你主动选择，不要求连续打卡，也不自动发通知。"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(l("例如：晚饭后留十分钟散步"), text: $title)
                Button(l("开始一个小调整")) { model.addPlan(title); title = "" }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.visiblePlans.contains(where: \.active) || !model.canWriteArchive)
            }
            ForEach(model.visiblePlans.sorted { $0.createdAt > $1.createdAt }) { plan in
                Section(plan.title) {
                    Text(plan.active ? l("进行中") : l("已结束"))
                    if plan.active {
                        TextField(l("这次尝试感觉如何？"), text: $note, axis: .vertical)
                        Button(l("记录尝试结果")) { model.checkIn(plan.id, note: note); note = "" }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canWriteArchive)
                        Button(l("结束这次尝试")) { model.finishPlan(plan.id) }.disabled(!model.canWriteArchive)
                    }
                    ForEach(plan.checkIns.reversed()) { check in
                        VStack(alignment: .leading) { Text(l.date(check.date, includeDate: true)).font(.caption); Text(check.note) }
                    }
                    Button(l("删除计划与结果"), role: .destructive) { deletingID = plan.id }.disabled(!model.canWriteArchive)
                }
            }
        }.navigationTitle(l("我的小调整计划"))
            .confirmationDialog(l("删除计划和结果？其他健康与录音记录会保留。"), isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
                Button(l("删除"), role: .destructive) { if let id = deletingID { model.deletePlan(id) }; deletingID = nil }
            }
    }
}
struct HealthOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var chosenBlock: Date?
    @State private var showSignalList = false
    private var l: Localizer { Localizer(locale: locale) }
    private var now: Date { min(Date(), Calendar.current.dateInterval(of: .day, for: model.selectedDay)?.end ?? Date()) }
    private var blocks: [LifeBlock] { HealthReview.canvas(day: model.selectedDay, hearts: model.heartPoints.filter { $0.isDemo == model.demoMode }, readings: model.visibleMetrics) }
    var body: some View {
        List {
            DatePicker(l("查看日期"), selection: $model.selectedDay, displayedComponents: .date)
            Section(l("一天的数据拼图")) {
                Toggle(l("使用可访问时段列表"), isOn: $showSignalList)
                    .accessibilityIdentifier("health-signal-list-toggle")
                if let block = blocks.first(where: { $0.start == chosenBlock }) { Text(signalLabel(block)).accessibilityIdentifier("health-selected-signal") }
                if showSignalList {
                    ForEach(blocks) { block in
                        Button { chosenBlock = block.start } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: signalIcon(block.signal)).foregroundStyle(signalColor(block.signal))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l.date(block.start) + " – " + l.date(block.end))
                                    Text(signalTitle(block.signal)).font(.subheadline).foregroundStyle(.secondary)
                                    Text(l("\(block.sampleCount) 个心率点")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if chosenBlock == block.start { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
                            .accessibilityLabel(signalLabel(block))
                            .accessibilityIdentifier("health-signal-cell")
                            .accessibilityAddTraits(chosenBlock == block.start ? [.isSelected] : [])
                    }
                } else {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                        ForEach(blocks) { block in
                            Button { chosenBlock = block.start } label: {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 5).fill(signalColor(block.signal))
                                        .frame(height: 24)
                                        .overlay { Image(systemName: signalIcon(block.signal)).font(.caption2).foregroundStyle(block.signal == .unknown ? Color.secondary : Color.white) }
                                        .overlay { if chosenBlock == block.start { RoundedRectangle(cornerRadius: 5).stroke(.primary, lineWidth: 2) } }
                                    Text(l.date(block.start)).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityElement(children: .ignore)
                                .accessibilityLabel(signalLabel(block))
                                .accessibilityIdentifier("health-signal-cell")
                                .accessibilityHint(l("选择后查看该时段的实际线索。"))
                                .accessibilityAddTraits(chosenBlock == block.start ? [.isSelected] : [])
                        }
                    }
                }
                Text(l("每格10分钟：橙色有活动聚合线索，绿色有心率点，灰色无可用线索。不推断专注、情绪或具体行为。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("个人趋势与证据")) {
                ForEach([MetricKind.sleepScore, .hrv, .wristTemperature], id: \.self) { kind in
                    HealthTrendRow(kind: kind, at: now)
                }
                Text(l("步数和能量是近5分钟窗口，不能直接相加当全天总量。多来源或不足5个历史日时不生成可比基线。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("一个可选安排")) {
                Text(HealthReview.suggestion(readings: model.visibleMetrics, now: now, language: l.language))
                Text(l("这不是训练处方、心理压力诊断或医学告警。依据不足时不催促活动。"))
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink(l("我的小调整计划")) { PlansView() }
            }
            CoverageView()
            NavigationLink(l("查看原始健康指标")) { HealthMetricsView() }
        }.navigationTitle(l("健康趋势与日常安排"))
    }
    private func signalTitle(_ signal: LifeBlock.Signal) -> String {
        switch signal {
        case .activity: return l("有活动聚合线索")
        case .heart: return l("有心率样本")
        case .unknown: return l("没有可用线索")
        }
    }
    private func signalIcon(_ signal: LifeBlock.Signal) -> String {
        switch signal { case .activity: return "figure.walk"; case .heart: return "heart.fill"; case .unknown: return "questionmark" }
    }
    private func signalColor(_ signal: LifeBlock.Signal) -> Color {
        switch signal { case .activity: return .orange; case .heart: return .teal; case .unknown: return Color(uiColor: .tertiarySystemFill) }
    }
    private func signalLabel(_ block: LifeBlock) -> String {
        l("\(l.date(block.start)) – \(l.date(block.end))，\(signalTitle(block.signal))，\(block.sampleCount) 个心率点")
    }

}
struct HealthTrendRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let kind: MetricKind
    let at: Date
    private var l: Localizer { Localizer(locale: locale) }
    private var points: [MetricReading] { model.visibleMetrics.filter { $0.kind == kind && kind.accepts($0.value) && $0.date <= at && $0.date >= ContextAlgorithm.historyStart(before: at) }.sorted { $0.date < $1.date } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.key(kind.title)).font(.headline)
            if let trend = HealthReview.trend(kind, readings: model.visibleMetrics, at: at) {
                Text(String(format: "%.1f", trend.reading.value) + " " + kind.unit + " · " + l.date(trend.reading.date, includeDate: true))
                Text(trend.reading.isFresh(at: at) ? l("当前可用") : l("仅作历史参考"))
                    .font(.caption).foregroundStyle(.secondary)
                Chart {
                    ForEach(points) { point in
                        PointMark(x: .value("Date", point.date), y: .value("Value", point.value)).foregroundStyle(.teal)
                    }
                    if let base = trend.baseline { RuleMark(y: .value("Baseline", base)).foregroundStyle(.gray).lineStyle(.init(dash: [4, 3])) }
                }.frame(height: 110).chartYScale(domain: .automatic(includesZero: false))
                Text(trend.baseline.map { l("个人基线：\(String(format: "%.1f", $0))；历史有数据日：\(trend.days)") } ?? l("暂无可比个人基线，历史有数据日：\(trend.days)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(l("无可读样本 / 不可用")).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
}
struct CapturePolicySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        Form {
            Section(l("原音频策略")) {
                Toggle(l("新录音完整转写后清理原音频"), isOn: $model.cleanupNewRecordings).disabled(model.busy || model.observing)
                Text(l("默认关闭，仅影响之后的新会话。全部片段转写成功且文字可靠保存后才清理；失败保留音频。清理后不能播放或重转写，文字与来源仍保留。"))
                    .font(.caption)
            }
            Section(l("录后音频质量")) {
                Toggle(l("自动转写前筛选未检出语音片段"), isOn: $model.filterQuietAudio).disabled(model.busy)
                Picker(l("轻声敏感度"), selection: $model.audioSensitivity) {
                    ForEach(1...5, id: \.self) { value in Text(l("第\(value)档")).tag(value) }
                }.disabled(model.busy)
                Text(l("使用Apple本地声音分类与能量分析，最多预览5分钟；筛选开启后逐段检测，未知或人工标记附近仍转写。档位越高越容易保留轻声，效果待真机验证；漏检可手动完整重试。跳过片段时保留原音频，不改变心率触发。"))
                    .font(.caption)
            }
            Section(l("资源预算")) {
                Toggle(l("低电量模式或过热时延后自动转写"), isOn: $model.deferHeavyWork)
                Text(l("录音仍按原时限结束并保留。延后任务可在处理中心手动继续；不会自动开麦、周期采样或强制健康设备测量。"))
                    .font(.caption)
                Text(l("AAC目标64kbps：每小时约29MB，24小时约0.7GB，另需临时空间。此为估算，不是可用容量或续航保证。"))
                    .font(.caption)
            }
        }.navigationTitle(l("音频与资源设置"))
    }
}
