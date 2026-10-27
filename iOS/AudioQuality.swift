import AVFoundation
import WatchMindCore
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif

enum AudioQuality {
    static func analyze(url: URL, sensitivity: Int) -> AudioQualitySummary? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return nil }
        #if canImport(SoundAnalysis)
        let observer = SpeechObserver(threshold: AudioEnergy.speechThreshold(sensitivity: sensitivity))
        let analyzer = SNAudioStreamAnalyzer(format: file.processingFormat)
        var classifying = false
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            do { try analyzer.add(request, withObserver: observer); classifying = true } catch { }
        }
        #endif
        let rate = file.processingFormat.sampleRate
        let limit = min(file.length, AVAudioFramePosition(rate * 300))
        var frames: AVAudioFramePosition = 0, quiet = 0.0, peak = -120.0
        do {
            while frames < limit {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, limit - frames)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                var sum = 0.0
                let n = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
                for c in 0..<channelCount {
                    for i in 0..<n { let value = Double(channels[c][i]); sum += value * value }
                }
                #if canImport(SoundAnalysis)
                if classifying { analyzer.analyze(buffer, atAudioFramePosition: frames) }
                #endif
                let db = AudioEnergy.dbfs(meanSquare: sum / Double(n * max(1, channelCount)))
                let seconds = Double(n) / rate
                if db < AudioEnergy.threshold(sensitivity: sensitivity) { quiet += seconds }
                peak = max(peak, db); frames += AVAudioFramePosition(n)
            }
        } catch { return nil }
        guard frames > 0 else { return nil }
        var speech: Double?
        #if canImport(SoundAnalysis)
        if classifying {
            analyzer.completeAnalysis()
            speech = observer.result(duration: Double(frames) / rate)
        }
        #endif
        return .init(analyzedSeconds: Double(frames) / rate, lowEnergySeconds: quiet, peakDBFS: peak, sensitivity: sensitivity, speechSeconds: speech)
    }
}

#if canImport(SoundAnalysis)
private final class SpeechObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private let complete = DispatchSemaphore(value: 0)
    private let threshold: Double
    private var ranges: [DateInterval] = []
    private var knownRanges: [DateInterval] = []
    private var sawSpeechClass = false
    private var failed = false
    init(threshold: Double) { self.threshold = threshold }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let candidates = result.classifications.filter { $0.identifier == "speech" || $0.identifier == "whispering" }
        lock.lock(); defer { lock.unlock() }
        guard !candidates.isEmpty else { return }
        sawSpeechClass = true
        let knownStart = result.timeRange.start.seconds, knownDuration = result.timeRange.duration.seconds
        if knownStart.isFinite, knownDuration.isFinite, knownDuration > 0 { knownRanges.append(.init(start: Date(timeIntervalSince1970: knownStart), duration: knownDuration)) }
        if candidates.contains(where: { $0.confidence >= threshold }) {
            let start = result.timeRange.start.seconds, duration = result.timeRange.duration.seconds
            if start.isFinite, duration.isFinite, duration > 0 { ranges.append(.init(start: Date(timeIntervalSince1970: start), duration: duration)) }
        }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); failed = true; lock.unlock(); complete.signal()
    }
    func requestDidComplete(_ request: SNRequest) { complete.signal() }
    func result(duration: Double) -> Double? {
        guard complete.wait(timeout: .now() + 10) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        let bounds = DateInterval(start: Date(timeIntervalSince1970: 0), duration: duration)
        guard !failed, sawSpeechClass, Coverage.seconds(knownRanges, within: bounds) >= duration * 0.95 else { return nil }
        return Coverage.seconds(ranges, within: .init(start: Date(timeIntervalSince1970: 0), duration: duration))
    }
}
#endif
