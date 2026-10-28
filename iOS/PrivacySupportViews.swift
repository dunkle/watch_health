import SwiftUI
import WatchMindCore

/// Public links are supplied by the publisher, never invented or inferred from private settings.
enum PublisherConfiguration {
    static var privacyURL: URL? { publicURL(for: "WatchMindPrivacyPolicyURL") }
    static var supportURL: URL? { publicURL(for: "WatchMindSupportURL") }
    static var operatorName: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "WatchMindOperatorName") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("$(") ? nil : value
    }
    private static func publicURL(for key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        return validatedPublicURL(raw)
    }
    static func validatedPublicURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              value.scheme?.lowercased() == "https", let host = value.host?.lowercased(),
              !host.isEmpty, host != "localhost", !["example.com", "example.net", "example.org"].contains(host), !host.hasSuffix(".example"), !host.hasSuffix(".localhost"),
              host.contains("."), !host.split(separator: ".").allSatisfy({ Int($0) != nil }), !host.hasSuffix(".invalid"), !host.hasSuffix(".test"),
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return nil }
        return url
    }
}

struct PrivacyCenterView: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section(l("你的记录如何处理")) {
                Text(l("WatchMind 默认在设备上保存和处理录音、文字、健康资料与复盘。基础记录不需要账号，不包含广告或分析 SDK。"))
                Text(l("只有你开启观察或明确开始录音后才使用麦克风；没有触发前的声音。HealthKit、语音识别与麦克风权限可在系统设置中分别管理。"))
                Text(l("身体信号、实际原话和 AI 的解释是不同层次的资料。心率与 HRV 不能直接证明心情、疾病或他人意图。"))
            }
            Section(l("本机与外部 AI")) {
                Text(l("本机转写不自动切换到云端。Apple 本机模型是否可用取决于设备、地区、系统和模型就绪状态。"))
                Text(l("只有在你选定片段、核对输入并确认发送后，复盘功能才向所选接口发送相应文字、身体信号、历史基线和问题；不发送原始音频或整个档案。"))
                Text(l("自定义接口和供应商可能保留请求并关联其账户。请先查看该服务的政策、地区和计费规则；取消请求不保证撤销已产生的费用。"))
                NavigationLink(l("AI 与模型设置")) { AISettingsView() }
            }
            Section(l("保留、导出与删除")) {
                Text(l("本地档案使用系统文件保护，应用主动创建的资料目录排除系统备份。API 密钥单独保存在设备钥匙串，不加入档案导出。"))
                Text(l("默认保留原音频。可为新会话选择完整转写后的清理；失败或部分成功不自动删除声音。已清理音频无法播放或重新转写。"))
                Text(l("导出文件可能包含私人文字与健康信息，请存放到你信任的位置。删除与卸载可能导致不可恢复的数据丢失；当前支持的导出与恢复范围请查看数据管理页面。"))
                NavigationLink(l("存储与导出")) { StorageManagementView() }
            }
            Section(l("发布者与完整政策")) {
                if let name = PublisherConfiguration.operatorName { LabeledContent(l("发布主体"), value: name) }
                if let url = PublisherConfiguration.privacyURL {
                    Link(destination: url) { Label(l("打开完整隐私政策"), systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("publisher-privacy-link")
                } else {
                    Label(l("完整隐私政策尚未配置"), systemImage: "doc.text.magnifyingglass")
                    Text(l("这是本机构建的处理说明，不替代发布者的完整法律政策。发布者必须配置真实主体、公开政策与支持联系方式，才能用于公开发布。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink(l("帮助与联系支持")) { SupportCenterView() }
            }
        }.navigationTitle(l("隐私与数据处理"))
            .accessibilityIdentifier("privacy-center-screen")
    }
}

struct SupportCenterView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var diagnostics: String {
        "WatchMind \(version) (\(build))\n" + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        + "Language: \(model.language.rawValue)\n"
        + "Foreground: \(model.foreground), observing: \(model.observing), busy: \(model.busy), protected storage paused: \(model.storagePaused)\n"
        + "No recordings, transcripts, health values, API endpoints or API keys are included."
    }
    var body: some View {
        List {
            Section(l("使用帮助")) {
                Text(l("没有触发录音时，请先确认已开启观察、应用在前台、设备解锁且有新鲜心率样本。普通手表心率可能较稀疏，不保证实时触发。"))
                Text(l("来电、锁屏或失去前台可能暂停录音。查看顶部状态条和处理中心，在条件允许时继续，录音空档不会补造。"))
                Text(l("转写或 AI 失败时先保留原始记录，核对处理状态。请勿为了重试而卸载应用；卸载可能删除本地资料。"))
                NavigationLink(l("查看处理中心")) { ProcessingCenterView() }
                Button(l("打开系统权限设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section(l("联系支持")) {
                if let url = PublisherConfiguration.supportURL {
                    Link(destination: url) { Label(l("打开支持页面"), systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("publisher-support-link")
                } else {
                    Text(l("支持联系方式尚未配置。请向提供此构建的开发者反馈；正式发布前必须配置真实支持页面。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent(l("应用版本"), value: "\(version) (\(build))")
                ShareLink(item: diagnostics) { Label(l("分享不含正文的诊断信息"), systemImage: "square.and.arrow.up") }
                Text(l("只有你主动分享才会离开应用。诊断仅包含版本、系统、语言和运行状态，不包含录音、文字、健康值、接口地址或密钥。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink(l("隐私与数据处理")) { PrivacyCenterView() }
        }.navigationTitle(l("帮助与联系支持"))
            .accessibilityIdentifier("support-center-screen")
    }
}
