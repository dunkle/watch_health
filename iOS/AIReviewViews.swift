import SwiftUI
import WatchMindCore

private func providerTitle(_ provider: AIProvider, _ l: Localizer) -> String {
    switch provider {
    case .apple: return l("Apple 本机模型")
    case .openAI: return "OpenAI"
    case .deepSeek: return "DeepSeek"
    case .compatible: return l("兼容接口 / 服务额度")
    case .localEndpoint: return l("本机模型服务")
    }
}
private func goalTitle(_ goal: AIReviewGoal, _ l: Localizer) -> String {
    switch goal {
    case .intent: return l("沟通与意图")
    case .emotion: return l("感受与情绪线索")
    case .body: return l("身体数据解读")
    case .combined: return l("综合情境复盘")
    }
}

struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.locale) private var locale
    @State private var key = ""
    @State private var status: String?
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        Form {
            Section(l("分析方式")) {
                Picker(l("模型服务"), selection: Binding(get: { settings.configuration.provider }, set: { settings.usePreset($0); key = ""; status = nil })) {
                    ForEach(AIProvider.allCases, id: \.self) { Text(providerTitle($0, l)).tag($0) }
                }
                Text(l("默认使用受支持设备上的 Apple 本机模型。不可用时明确提示，不会自动改用云端。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.configuration.provider != .apple {
                Section(l("连接设置")) {
                    TextField(l("接口地址（包含 /v1）"), text: $settings.configuration.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(l("模型名称"), text: $settings.configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(l("使用 OpenAI Chat Completions 格式。远程服务需 HTTPS；本机服务仅限此设备的 localhost。Mac 的 localhost 不是 iPhone 的 localhost。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(l("访问密钥")) {
                    SecureField(l("API Key / 个人服务令牌"), text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(l("保存密钥到钥匙串")) {
                        do { try settings.saveKey(key); key = ""; status = l("密钥已安全保存。") }
                        catch { status = AIReviewService.errorMessage(error, language: l.language) }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.keyAvailable {
                        Label(l("此接口已配置密钥"), systemImage: "key.fill")
                        Button(l("移除此接口密钥"), role: .destructive) {
                            do { try settings.deleteKey(); status = l("密钥已移除。") }
                            catch { status = AIReviewService.errorMessage(error, language: l.language) }
                        }
                    }
                    Text(l("密钥只保存在本机钥匙串，不包含在档案导出中。更换接口地址后需单独配置，避免误发给其他服务。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.caption) }
                    if settings.keyError != nil { Text(l("钥匙串暂不可用，请解锁设备后重试。")) }
                }
            }
            Section(l("额度与本地模型")) {
                Text(l("本机模型无需 API 额度，模型由系统管理下载与就绪状态。此版本不内置第三方模型下载器。"))
                Text(l("OpenAI、DeepSeek 等按各自账户计费；本应用不赠送或虚构第三方免费额度。部署配套额度服务后，可在兼容接口填写服务地址和个人令牌。"))
                Text(l("支持本机运行的兼容模型服务；不支持的接口协议需通过适配服务转换。不会自动向任意公开接口发送健康数据。"))
            }.font(.footnote)
        }.navigationTitle(l("AI 与模型设置"))
            .onDisappear { key = "" }
    }
}

struct AIReviewLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section {
                NavigationLink { AIReviewComposerView() } label: {
                    Label(l("新建 AI 复盘"), systemImage: "sparkles.rectangle.stack")
                }
                NavigationLink(l("AI 与模型设置")) { AISettingsView() }
                Text(l("选一段原话、一组身体信号，或组合分析。解读是待核对的假设，不替代本人感受或医疗判断。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("已保存的复盘")) {
                if model.visibleAIReviews.isEmpty { Text(l("从一个具体片刻开始，而不是让 AI 猜测一整天。")) }
                ForEach(model.visibleAIReviews) { review in
                    NavigationLink { AIReviewDetailView(id: review.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(goalTitle(review.goal, l)).font(.headline)
                            Text(l.date(review.evidence.selection.start, includeDate: true)).font(.caption)
                            Text(review.text).lineLimit(3).foregroundStyle(.secondary)
                            if review.evidence.isDemo { Text(l("模拟数据")).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
        }.navigationTitle(l("AI 复盘工作台"))
    }
}
private struct AIReviewDraft: Identifiable { let id = UUID(); let evidence: AIReviewEvidence; let goal: AIReviewGoal }

struct AIReviewComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    var recordingID: UUID? = nil
    @State private var selectedID: UUID?
    @State private var start = Date().addingTimeInterval(-300)
    @State private var end = Date()
    @State private var includeTranscript = false
    @State private var includeHeart = true
    @State private var kinds = Set<MetricKind>()
    @State private var question = ""
    @State private var goal: AIReviewGoal = .combined
    @State private var failure: String?
    @State private var draft: AIReviewDraft?
    private var l: Localizer { Localizer(locale: locale) }
    private var owners: [Episode] { model.visible.filter { $0.linkedRecordingID == nil && $0.captureStarted != nil && $0.captureEnded != nil && ![.recording, .paused, .transcribing].contains($0.status) }.sorted { $0.trigger.date > $1.trigger.date } }
    private var owner: Episode? { owners.first { $0.id == selectedID } }
    var body: some View {
        Form {
            Section(l("你想理解什么？")) {
                Picker(l("分析目标"), selection: $goal) { ForEach(AIReviewGoal.allCases, id: \.self) { Text(goalTitle($0, l)).tag($0) } }
                TextField(l("补充你的问题（可选）"), text: $question, axis: .vertical)
                    .onChange(of: question) { _, value in if value.count > 1000 { question = String(value.prefix(1000)) } }
                if model.demoMode { Label(l("模拟数据"), systemImage: "flask") }
            }
            Section(l("选择录音与时间范围")) {
                Toggle(l("包含片段原话"), isOn: $includeTranscript)
                if includeTranscript {
                    Picker(l("来源录音"), selection: $selectedID) {
                        Text(l("请选择录音")).tag(UUID?.none)
                        ForEach(owners) { event in Text(l.date(event.captureStarted ?? event.trigger.date, includeDate: true, seconds: true)).tag(Optional(event.id)) }
                    }.onChange(of: selectedID) { _, _ in selectRecording() }
                }
                DatePicker(l("片段开始"), selection: $start)
                DatePicker(l("片段结束"), selection: $end)
                if includeTranscript, let owner, let began = owner.captureStarted, let ended = owner.captureEnded, ended.timeIntervalSince(began) > 0.1 {
                    preciseRange(began: began, ended: ended)
                }
                Text(l("最长选择24小时。文字按实际转写句段重叠提取，边界句可能超出所选范围；没有逐字对齐时不伪造精确截字。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l("只保存时间范围与证据快照，不复制音频。试听在所选结束或第一个录音空档处停止。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("组合身体信号")) {
                Toggle(l("心率与当时基线"), isOn: $includeHeart)
                ForEach(HealthCategory.allCases, id: \.self) { category in
                    DisclosureGroup(l.key(category.title)) {
                        ForEach(category.metricKinds, id: \.self) { kind in
                            Toggle(l.key(kind.title), isOn: Binding(get: { kinds.contains(kind) }, set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }))
                        }
                    }
                }
                Text(l("仅选中的可读指标进入分析。范围前仍有效的最近样本和个人基线会标明历史时间；缺失数据保持未知。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(l("核对所选依据")) { prepare() }.disabled(model.busy || !model.canWriteArchive)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
        }.navigationTitle(l("新建 AI 复盘"))
            .onAppear { if let recordingID, selectedID == nil { selectedID = recordingID; includeTranscript = true; selectRecording() } }
            .sheet(item: $draft) { draft in NavigationStack { AIReviewRunView(evidence: draft.evidence, initialGoal: draft.goal) } }
    }
    private func preciseRange(began: Date, ended: Date) -> some View {
        let length = ended.timeIntervalSince(began)
        return VStack(alignment: .leading, spacing: 12) {
            Text(l("精细选段（秒）")).font(.subheadline.bold())
            Slider(value: Binding(get: { max(0, min(length, start.timeIntervalSince(began))) }, set: { start = began.addingTimeInterval(min($0, length - 0.1)); if end < start.addingTimeInterval(0.1) { end = min(ended, start.addingTimeInterval(0.1)) } }), in: 0...max(0.001, length - 0.1), step: 0.1)
                .accessibilityLabel(l("片段开始"))
            Slider(value: Binding(get: { max(0, min(length, end.timeIntervalSince(began))) }, set: { end = began.addingTimeInterval(max(0.1, $0)); if start > end.addingTimeInterval(-0.1) { start = max(began, end.addingTimeInterval(-0.1)) } }), in: 0.1...length, step: 0.1)
                .accessibilityLabel(l("片段结束"))
            Text(String(format: "%.1f – %.1f s", start.timeIntervalSince(began), end.timeIntervalSince(began))).monospacedDigit()
        }
    }
    private func selectRecording() {
        guard let owner, let began = owner.captureStarted, let ended = owner.captureEnded else { return }
        start = began; end = min(ended, began.addingTimeInterval(300))
    }
    private func prepare() {
        do {
            let selection = AIReviewSelection(recordingID: selectedID, start: start, end: end, includeTranscript: includeTranscript, includeHeart: includeHeart, metricKinds: Array(kinds), question: question)
            let evidence = try AIReviewEvidence.build(selection: selection, episodes: model.visible, heartPoints: model.heartPoints, metrics: model.visibleMetrics, isDemo: model.demoMode)
            failure = nil; draft = .init(evidence: evidence, goal: goal)
        } catch { failure = AIReviewService.errorMessage(error, language: l.language) }
    }
}

struct AIReviewRunView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AISettings
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let evidence: AIReviewEvidence
    let initialGoal: AIReviewGoal
    @State private var consent = false
    @State private var running = false
    @State private var result = ""
    @State private var failure: String?
    @State private var saved = false
    @State private var task: Task<Void, Never>?
    @State private var playbackID = UUID()
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section(l("本次依据")) {
                Text(l.date(evidence.selection.start, includeDate: true, seconds: true) + " — " + l.date(evidence.selection.end, includeDate: true, seconds: true))
                if evidence.isDemo { Label(l("模拟数据"), systemImage: "flask") }
                Text(l("原话 \(evidence.transcript.count) 段 · 心率 \(evidence.heartPoints.count) 点 · 健康样本 \(evidence.metrics.count) 条"))
                ForEach(Array(evidence.transcript.enumerated()), id: \.offset) { _, quote in
                    VStack(alignment: .leading) { Text(l.date(quote.start, seconds: true)).font(.caption); Text(quote.text).textSelection(.enabled) }
                }
                if !evidence.audioWindows.isEmpty && !evidence.isDemo {
                    Button(model.playingID == playbackID ? l("停止播放") : l("试听所选范围")) { model.previewReview(evidence, playbackID: playbackID) }.disabled(model.recordingID != nil)
                }
                ForEach(evidence.metrics) { reading in MetricRow(kind: reading.kind, reading: reading, at: evidence.selection.end) }
                DisclosureGroup(l("完整输入预览")) { Text((try? evidence.preview) ?? "").font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section(l("分析方式")) {
                NavigationLink { AISettingsView() } label: { LabeledContent(l("模型服务"), value: providerTitle(settings.configuration.provider, l)) }
                if settings.configuration.provider != .apple {
                    Text(settings.configuration.baseURL).font(.caption).textSelection(.enabled)
                    Text(l("只发送上述文字、选定身体信号、历史基线和问题；不发送原始音频。服务商会按其政策处理，可能产生费用。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(l("我同意将本次所选依据发送到此接口"), isOn: $consent)
                }
                Button { generate() } label: {
                    HStack { if running { ProgressView() }; Text(running ? l("正在分析…") : l("开始复盘分析")) }
                }.disabled(running || saved || model.aiReviews.count >= 200 || !model.canWriteArchive || (settings.configuration.provider != .apple && !consent))
                if running { Button(l("取消本次分析")) { task?.cancel() } }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            if !result.isEmpty {
                Section(l("AI 解读 · 待本人核对")) {
                    Text(result).textSelection(.enabled)
                    if saved { Label(l("已保存在本机复盘记录中"), systemImage: "checkmark.circle") }
                    else { Button(l("重新尝试保存")) { persist() }.disabled(!model.canWriteArchive) }
                    ShareLink(item: result) { Label(l("导出这份复盘"), systemImage: "square.and.arrow.up") }
                }
            }
        }.navigationTitle(goalTitle(initialGoal, l))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(l("完成")) { dismiss() } } }
            .onChange(of: settings.configuration) { _, _ in consent = false }
            .onDisappear { task?.cancel(); if model.playingID == playbackID { model.previewReview(evidence, playbackID: playbackID) } }
    }
    @State private var resultID = UUID()
    @State private var resultDate = Date()
    @State private var usedConfiguration: AIConfiguration?
    @State private var usedLanguage: AppLanguage?
    private func generate() {
        guard !running else { return }
        running = true; result = ""; failure = nil; resultID = UUID(); resultDate = Date()
        usedConfiguration = settings.configuration; usedLanguage = l.language.resolved
        task = Task { @MainActor in
            defer { running = false }
            do {
                let text = try await AIReviewService.generate(evidence: evidence, goal: initialGoal, language: usedLanguage ?? .english, settings: settings)
                try Task.checkCancellation()
                result = text; persist()
            } catch is CancellationError { failure = l("本次分析已取消，没有自动重试。") }
            catch { failure = AIReviewService.errorMessage(error, language: l.language) }
        }
    }
    private func persist() {
        guard let configuration = usedConfiguration, let language = usedLanguage else { return }
        let record = AIReviewRecord(id: resultID, createdAt: resultDate, evidence: evidence, goal: initialGoal, text: result, provider: configuration.provider, model: configuration.model, language: language.rawValue)
        saved = model.saveAIReview(record)
        if !saved { failure = l("结果尚未保存：请检查存储状态、来源是否仍在，以及是否达到200份复盘上限。请先导出结果。") }
        else { failure = nil }
    }
}

struct AIReviewDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    let id: UUID
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            if let review = model.visibleAIReviews.first(where: { $0.id == id }) {
                Section(l("AI 解读 · 待本人核对")) {
                    Text(review.text).textSelection(.enabled)
                    Text(providerTitle(review.provider, l) + (review.model.isEmpty ? "" : " · " + review.model)).font(.caption).foregroundStyle(.secondary)
                    Text(l.date(review.createdAt, includeDate: true)).font(.caption)
                    if review.evidence.isDemo { Text(l("模拟数据")) }
                    ShareLink(item: review.text) { Label(l("导出这份复盘"), systemImage: "square.and.arrow.up") }
                }
                Section(l("生成时的依据快照")) {
                    Text(l("重新转写不会改写旧复盘。快照可能与当前转写不同，需核对来源；删除来源录音会一并删除关联复盘。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let source = review.evidence.selection.recordingID { NavigationLink(l("查看原录音")) { EpisodeDetail(id: source) } }
                    DisclosureGroup(l("完整输入预览")) { Text((try? review.evidence.preview) ?? "").font(.caption.monospaced()).textSelection(.enabled) }
                    NavigationLink(l("再做一次复盘")) { AIReviewComposerView(recordingID: review.evidence.selection.recordingID) }
                }
                Button(l("删除这份复盘"), role: .destructive) { deleting = true }.disabled(!model.canWriteArchive)
            } else { Text(l("来源已删除或不可用。")) }
        }.navigationTitle(l("复盘详情"))
            .confirmationDialog(l("删除复盘及其依据快照？原始记录会保留。"), isPresented: $deleting) {
                Button(l("删除"), role: .destructive) { model.deleteAIReview(id); dismiss() }
            }
    }
}
