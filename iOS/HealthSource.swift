import HealthKit
import WatchMindCore

@MainActor
final class HealthSource {
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    func start(onSample: @escaping (HeartSample) -> Void, onError: @escaping (String) -> Void) async throws {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw NSError(domain: "WatchMind", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前设备无可用健康数据。"])
        }
        try await store.requestAuthorization(toShare: [], read: [type])
        stop()
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-180), end: nil)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { _, samples, _, _, error in
            let values = (samples as? [HKQuantitySample] ?? []).map {
                HeartSample(date: $0.endDate, bpm: $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }.sorted { $0.date < $1.date }
            Task { @MainActor in
                if let error { onError(error.localizedDescription) }
                values.forEach(onSample)
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler; query = q; store.execute(q)
    }
    func stop() { if let query { store.stop(query) }; query = nil }
}
