import SwiftUI
import HealthKit
import WatchKit
import WatchConnectivity
import WatchMindCore

@main
struct WatchMindWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene { WindowGroup { WatchHome().environmentObject(model) } }
}

@MainActor
final class WatchModel: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    @Published var active = false
    @Published var starting = false
    @Published var bpm: Double?
    @Published var status = "先在手机开启观察"
    @Published var failure: String?
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var detector = HeartDetector()
    private var discard = false
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func start() async {
        guard !active, !starting else { return }
        starting = true; defer { starting = false }
        do {
            guard let heart = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
            try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heart])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking; configuration.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let live = session.associatedWorkoutBuilder()
            live.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            session.delegate = self; live.delegate = self
            workout = session; builder = live; detector.reset(); discard = false
            let start = Date(); session.startActivity(with: start)
            try await live.beginCollection(at: start)
            active = true; status = "步行会话 · 等待心率"
        } catch {
            discard = true; workout?.end(); builder?.discardWorkout(); workout = nil; builder = nil
            failure = error.localizedDescription; status = "无法开始步行会话"
        }
    }
    func stop() {
        guard active else { return }
        active = false; status = "正在保存步行…"; workout?.end()
    }
    private func complete() async {
        guard let builder, !discard else { return }
        do {
            try await builder.endCollection(at: Date())
            _ = try await builder.finishWorkout()
            status = "步行已保存 · 观察结束"
        } catch { failure = error.localizedDescription; status = "保存失败，请查看健康App" }
        workout = nil; self.builder = nil; active = false
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended { Task { @MainActor in await self.complete() } }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.discard = true; self.builder?.discardWorkout(); self.active = false
            self.workout = nil; self.builder = nil; self.failure = error.localizedDescription
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate), collectedTypes.contains(type),
              let statistics = workoutBuilder.statistics(for: type), let quantity = statistics.mostRecentQuantity() else { return }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? statistics.endDate
        Task { @MainActor in self.consume(.init(date: date, bpm: value)) }
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
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}

struct WatchHome: View {
    @EnvironmentObject var model: WatchModel
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "leaf.fill").foregroundStyle(.mint)
                    Text("留意此刻").font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.bpm.map { "\(Int($0))" } ?? "—").font(.system(size: 44, weight: .light, design: .rounded))
                        Text("次/分").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(model.status).font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if model.active {
                        Button("结束并保存步行", role: .destructive) { model.stop() }
                    } else {
                        Button(model.starting ? "准备中…" : "开始步行观察") { confirm = true }.tint(.mint).disabled(model.starting)
                    }
                    Text("只用于真实步行。录音由已授权且在前台的手机完成，手表不录音。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal, 8)
            }
            .confirmationDialog("这会启动并保存一次步行运动，增加耗电。请先在手机授权观察。", isPresented: $confirm) {
                Button("我正在步行，开始") { Task { await model.start() } }
            }
            .alert("请检查", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("知道了") { model.failure = nil }
            } message: { Text(model.failure ?? "") }
        }
    }
}
