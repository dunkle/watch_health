import SwiftUI
import UniformTypeIdentifiers
import WatchMindCore

private struct TextArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct StorageManagementView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AISettings
    @Environment(\.locale) private var locale
    @State private var audioBytes: Int64?
    @State private var archiveBytes: Int64?
    @State private var document = TextArchiveDocument(data: Data())
    @State private var exporting = false
    @State private var deletingKeys = false
    @State private var status: String?
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section(l("本机空间")) {
                LabeledContent(l("原始音频"), value: size(audioBytes))
                LabeledContent(l("文字、健康与复盘档案"), value: size(archiveBytes))
                LabeledContent(l("已保存的复盘"), value: "\(model.aiReviews.filter { !$0.evidence.isDemo }.count) / 200")
                Button(l("刷新空间统计")) { refresh() }
                Text(l("选段复盘不会复制音频。每次最多24小时、24000字符输入；最多保留200份复盘，达到上限后请先导出或删除。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("保留与清理")) {
                NavigationLink(l("音频与资源设置")) { CapturePolicySettingsView() }
                NavigationLink(l("查看处理中心")) { ProcessingCenterView() }
                NavigationLink(l("管理复盘记录")) { AIReviewLibraryView() }
                Text(l("删除录音会同时移除关联复盘及证据快照；只删除复盘不会影响原录音。音频清理后仍可用已存文字复盘。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("文字档案导出")) {
                Button(l("导出 JSON 文字档案")) {
                    do { document = TextArchiveDocument(data: try model.exportTextArchive()); exporting = true; status = nil }
                    catch { status = l("导出未完成，请检查设备解锁与存储状态。") }
                }.disabled(!model.canWriteArchive || model.busy)
                Text(l("包含真实记录的文字、健康数据、人物、记忆和复盘，不包含音频、密钥或模拟数据；暂不支持导入恢复。导出文件含私人信息，请自行选择安全位置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("密钥管理")) {
                Button(l("移除全部 AI 访问密钥"), role: .destructive) { deletingKeys = true }
                Text(l("删除本地记录不会注销第三方服务。密钥单独管理，卸载后也请检查服务商授权。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status { Text(status) }
        }.navigationTitle(l("存储与导出")).onAppear { refresh() }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "WatchMind-text-archive") { result in
                switch result { case .success: status = l("文字档案已导出，不包含音频和密钥。")
                case .failure: status = l("导出未完成，请检查设备解锁与存储状态。") }
                document = TextArchiveDocument(data: Data())
            }
            .confirmationDialog(l("移除所有已配置接口的本机密钥？"), isPresented: $deletingKeys) {
                Button(l("移除全部密钥"), role: .destructive) {
                    do { try settings.deleteAllKeys(); status = l("密钥已移除。") }
                    catch { status = AIReviewService.errorMessage(error, language: l.language) }
                }
            }
    }
    private func size(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
    private func refresh() {
        do { let usage = try model.storageUsage(); audioBytes = usage.audio; archiveBytes = usage.archive; status = nil }
        catch { audioBytes = nil; archiveBytes = nil; status = l("空间统计暂不可用，请解锁后重试。") }
    }
}

struct TriggerSignalsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        Form {
            Section {
                Label(l("心率是当前录音触发的必要信号"), systemImage: "heart")
                Text(l("自由选择哪些辅助指标参与事件显著度计算。它们不会单独开启麦克风；健康数据更新频率受系统与设备限制。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(HealthCategory.allCases, id: \.self) { category in
                Section(l.key(category.title)) {
                    ForEach(category.metricKinds, id: \.self) { kind in
                        Toggle(l.key(kind.title), isOn: Binding(get: { model.contextMetricKinds.contains(kind) }, set: { selected in
                            model.contextMetricKinds.removeAll { $0 == kind }
                            if selected { model.contextMetricKinds.append(kind) }
                        }))
                    }
                }
            }
            Text(l("选择仅影响之后的真实事件，不改写旧事件快照。AI 复盘时可以另外选择信号。"))
                .font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(l("选择辅助触发信号"))
            .disabled(model.observing || model.busy)
    }
}
