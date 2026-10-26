import SwiftUI
import HealthKit
import WatchKit
import WatchConnectivity
import WatchMindCore

@main
struct WatchMindWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene { WindowGroup { WatchHome().environmentObject(model).environment(\.locale, model.language.locale) } }
}

@MainActor
final class WatchModel: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    @Published private var lifecycle = WorkoutLifecycle()
    @Published private var finishing = OperationSlot()
    @Published var bpm: Double?
    @Published var status = "先在手机开启观察"
    @Published var failure: String?
    var active: Bool { lifecycle.phase == .running }
    var starting: Bool { lifecycle.phase == .starting }
    var stopping: Bool { lifecycle.phase == .stopping || finishing.current != nil }
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var detector = HeartDetector()
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func start() async {
        guard finishing.current == nil, let id = lifecycle.begin() else { return }
        do {
            guard let heart = HKObjectType.quantityType(forIdentifier: .heartRate) else {
                lifecycle.finish(id); return
            }
            try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heart])
            guard lifecycle.id == id, lifecycle.phase == .starting else { return }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking; configuration.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let live = session.associatedWorkoutBuilder()
            live.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            session.delegate = self; live.delegate = self
            workout = session; builder = live; detector.reset()
            let start = Date(); session.startActivity(with: start)
            try await live.beginCollection(at: start)
            guard workout === session, lifecycle.started(id) else { return }
            status = "步行会话 · 等待心率"
        } catch {
            guard lifecycle.id == id else { return }
            let previous = workout; let previousBuilder = builder
            workout = nil; builder = nil; lifecycle.finish(id)
            previous?.end(); previousBuilder?.discardWorkout()
            failure = error.localizedDescription; status = "无法开始步行会话"
        }
    }
    func stop() {
        guard let id = lifecycle.id, lifecycle.stop(id) else { return }
        status = "正在保存步行…"; workout?.end()
    }
    private func complete(_ sender: HKWorkoutSession) async {
        guard workout === sender, let id = lifecycle.id, let builder,
              let operation = finishing.begin() else { return }
        lifecycle.stop(id)
        defer {
            // A failure or newer session invalidates this finalizer's ownership.
            if finishing.finish(operation), lifecycle.finish(id) {
                workout = nil; self.builder = nil
            }
        }
        do {
            try await builder.endCollection(at: Date())
            guard workout === sender, lifecycle.id == id, finishing.owns(operation) else { return }
            _ = try await builder.finishWorkout()
            guard workout === sender, lifecycle.id == id, finishing.owns(operation) else { return }
            status = "步行已保存 · 观察结束"
        } catch {
            guard workout === sender, lifecycle.id == id else { return }
            failure = error.localizedDescription; status = "保存失败，请查看健康App"
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended { Task { @MainActor in await self.complete(workoutSession) } }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.workout === workoutSession, let id = self.lifecycle.id else { return }
            let previousBuilder = self.builder
            self.workout = nil; self.builder = nil
            self.finishing.cancel(); self.lifecycle.finish(id)
            workoutSession.end(); previousBuilder?.discardWorkout()
            self.failure = error.localizedDescription; self.status = "运动会话失败，已结束"
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate), collectedTypes.contains(type),
              let statistics = workoutBuilder.statistics(for: type), let quantity = statistics.mostRecentQuantity() else { return }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? statistics.endDate
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.consume(.init(date: date, bpm: value))
        }
    }
    private func consume(_ sample: HeartSample) {
        guard active else { return }
        bpm = sample.bpm
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(["bpm": sample.bpm, "time": sample.date.timeIntervalSince1970], replyHandler: nil)
        }
        guard let trigger = detector.ingest(sample), let data = try? JSONEncoder().encode(trigger) else { return }
        WKInterfaceDevice.current().play(.notification)
        status = "发现波动 · 手机决定是否录音"
        guard session.activationState == .activated else { status = "未连接手机 · 未触发录音"; return }
        if session.isReachable {
            session.sendMessage(["trigger": data], replyHandler: nil) { _ in session.transferUserInfo(["trigger": data]) }
        } else {
            session.transferUserInfo(["trigger": data]); status = "已排队 · 延迟事件不补录"
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        applyLanguage(session.receivedApplicationContext)
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyLanguage(applicationContext)
    }
    nonisolated private func applyLanguage(_ context: [String: Any]) {
        guard let raw = context["language"] as? String, let language = AppLanguage(rawValue: raw) else { return }
        Task { @MainActor in self.language = language }
    }
}

struct WatchHome: View {
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @EnvironmentObject var model: WatchModel
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "leaf.fill").foregroundStyle(.mint)
                    Text(l("留意此刻")).font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.bpm.map { "\(Int($0))" } ?? "—").font(.system(size: 44, weight: .light, design: .rounded))
                        Text(l("次/分")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(l.key(model.status)).font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if model.active {
                        Button(l("结束并保存步行"), role: .destructive) { model.stop() }
                    } else if model.stopping {
                        ProgressView(l("正在保存步行…"))
                    } else {
                        Button(model.starting ? l("准备中…") : l("开始步行观察")) { confirm = true }.tint(.mint).disabled(model.starting)
                    }
                    Picker(l("语言 / Language"), selection: $model.language) {
                        Text(l("跟随系统")).tag(AppLanguage.system)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                        Text("English").tag(AppLanguage.english)
                    }
                    Text(l("只用于真实步行。录音由已授权且在前台的手机完成，手表不录音。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal, 8)
            }
            .confirmationDialog(l("这会启动并保存一次步行运动，增加耗电。请先在手机授权观察。"), isPresented: $confirm) {
                Button(l("我正在步行，开始")) { Task { await model.start() } }
            }
            .alert(l("请检查"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button(l("知道了")) { model.failure = nil }
            } message: { Text(model.failure ?? "") }
        }
    }
}
