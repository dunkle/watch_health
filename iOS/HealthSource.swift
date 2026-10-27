import HealthKit
import WatchMindCore

@MainActor
final class HealthSource {
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var starts = OperationSlot()
    func start(onSample: @escaping @MainActor @Sendable (HeartSample) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw NSError(domain: "WatchMind", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前设备无可用健康数据。"])
        }
        stop()
        guard let id = starts.begin() else { return false }
        defer { starts.finish(id) }
        try await store.requestAuthorization(toShare: [], read: [type])
        guard starts.owns(id) else { return false }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-180), end: nil)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { _, samples, _, _, error in
            let values = (samples as? [HKQuantitySample] ?? []).map {
                HeartSample(date: $0.endDate, bpm: $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }.sorted { $0.date < $1.date }
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage { onError(errorMessage) }
                values.forEach(onSample)
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler; query = q; store.execute(q)
        return true
    }
    func stop() { starts.cancel(); if let query { store.stop(query) }; query = nil }
}
