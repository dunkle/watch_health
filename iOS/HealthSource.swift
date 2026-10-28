import HealthKit
import CryptoKit
import WatchMindCore

@MainActor
final class HealthSource {
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var starts = OperationSlot()
    private var queryID: UUID?
    private var quantityTypes: [(MetricKind, HKQuantityTypeIdentifier, HKUnit)] {
        [(.oxygen, .oxygenSaturation, .percent()), (.hrv, .heartRateVariabilitySDNN, .secondUnit(with: .milli)),
         (.environmentalAudio, .environmentalAudioExposure, .decibelAWeightedSoundPressureLevel()),
         (.headphoneAudio, .headphoneAudioExposure, .decibelAWeightedSoundPressureLevel()),
         (.wristTemperature, .appleSleepingWristTemperature, .degreeCelsius())]
    }
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        for (_, identifier, _) in quantityTypes {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        for id in [HKQuantityTypeIdentifier.heartRate, .stepCount, .activeEnergyBurned] {
            if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        return types
    }
    func start(onSample: @escaping @MainActor @Sendable (HeartSample) -> Void,
               onError: @escaping @MainActor @Sendable (String) -> Void) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw NSError(domain: "WatchMind", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前设备无可用健康数据。"])
        }
        stop(); guard let id = starts.begin() else { return false }
        defer { starts.finish(id) }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        guard starts.owns(id) else { return false }
        queryID = id
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-180), end: nil)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, error in
            let values = (samples as? [HKQuantitySample] ?? []).map {
                HeartSample(date: $0.endDate, bpm: $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }.sorted { $0.date < $1.date }
            let message = error?.localizedDescription
            Task { @MainActor in
                guard self?.queryID == id else { return }
                if let message { onError(message) }
                values.forEach(onSample)
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler; query = q; store.execute(q)
        return true
    }
    func stop() { starts.cancel(); queryID = nil; if let query { store.stop(query) }; query = nil }

    func context(authorize: Bool) async throws -> [MetricReading] {
        try await contextSnapshot(authorize: authorize).readings
    }
    /// Source and local-device identifiers are hashed before storage or optional AI sharing.
    nonisolated private static func stableSourceID(_ sample: HKSample) -> String {
        let identity = sample.sourceRevision.source.bundleIdentifier + "|" +
            (sample.device?.localIdentifier ?? sample.sourceRevision.productType ?? "unknown-device")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func contextSnapshot(authorize: Bool) async throws -> HealthMetricSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else { return .init(readings: []) }
        if authorize { try await store.requestAuthorization(toShare: [], read: readTypes) }
        let now = Date(), since = ContextAlgorithm.historyStart(before: Date())
        var result: [MetricReading] = []
        var replacingSleepWindow: DateInterval?
        // Each query is bounded. Missing readable samples are not treated as zero or proof of denial.
        for (kind, identifier, unit) in quantityTypes {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            let unitString = unit.unitString
            let rows: [MetricReading] = await withCheckedContinuation { continuation in
                let q = HKSampleQuery(sampleType: type,
                    predicate: HKQuery.predicateForSamples(withStart: since, end: now), limit: 400,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                    let rows = (samples as? [HKQuantitySample] ?? []).map {
                        MetricReading(id: $0.uuid.uuidString, kind: kind, value: $0.quantity.doubleValue(for: HKUnit(from: unitString)) * (kind == .oxygen ? 100 : 1), date: $0.endDate, source: $0.sourceRevision.source.name, sourceID: Self.stableSourceID($0))
                    }
                    continuation.resume(returning: rows.filter { kind.accepts($0.value) })
                }
                store.execute(q)
            }
            result += rows
        }
        for (kind, identifier, unit) in [(MetricKind.steps, HKQuantityTypeIdentifier.stepCount, HKUnit.count()),
                                         (.activeEnergy, .activeEnergyBurned, .kilocalorie())] {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            let unitString = unit.unitString
            let row: MetricReading? = await withCheckedContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-300), end: now, options: .strictStartDate)
                let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
                    let row: MetricReading?
                    if let quantity = statistics?.sumQuantity() {
                        row = MetricReading(id: "\(kind.rawValue)-\(Int(now.timeIntervalSince1970 / 60))", kind: kind,
                            value: quantity.doubleValue(for: HKUnit(from: unitString)), date: now, source: "HealthKit 5m aggregate")
                    } else { row = nil }
                    continuation.resume(returning: row)
                }
                store.execute(q)
            }
            if let row { result.append(row) }
        }
        if let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            let sleepResult: (intervals: [SleepInterval], complete: Bool) = await withCheckedContinuation { continuation in
                let q = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: now),
                    limit: 6000, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                    let intervals = (samples as? [HKCategorySample] ?? []).compactMap { sample -> SleepInterval? in
                        let state: SleepInterval.State
                        switch sample.value {
                        case HKCategoryValueSleepAnalysis.inBed.rawValue: state = .inBed
                        case HKCategoryValueSleepAnalysis.awake.rawValue: state = .awake
                        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                             HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                             HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                             HKCategoryValueSleepAnalysis.asleepREM.rawValue: state = .asleep
                        default: return nil
                        }
                        return SleepInterval(start: sample.startDate, end: sample.endDate, state: state,
                            source: Self.stableSourceID(sample),
                            priority: sample.sourceRevision.productType?.hasPrefix("Watch") == true ? 1 : 0)
                    }
                    continuation.resume(returning: (intervals, error == nil && samples != nil && (samples?.count ?? 0) < 6000))
                }
                store.execute(q)
            }
            if sleepResult.complete {
                result += MetricHistory.sleepReadings(sleepResult.intervals)
                replacingSleepWindow = DateInterval(start: since, end: now)
            }
        }
        return HealthMetricSnapshot(readings: result, replacingSleepWindow: replacingSleepWindow)
    }
}
