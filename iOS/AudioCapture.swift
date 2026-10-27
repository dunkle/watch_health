import AVFoundation
import Speech
import WatchMindCore

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var finished: ((Result<URL, Error>) -> Void)?
    private var url: URL?
    struct TranscriptionResult {
        var text: String
        var segments: [TranscriptSegment]
        var failedChunks: Int
    }
    private var transcriptionSlot = OperationSlot()
    private var speechTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var speechSlot = OperationSlot()
    private var speechCompletion: ((Result<(String, [TranscriptSegment]), Error>) -> Void)?
    private var deadline: Task<Void, Never>?
    enum CaptureError: LocalizedError {
        case permission, unavailable, recording, interrupted, busy, timeout
        var errorDescription: String? { message(language: .system) }
        func message(language: AppLanguage) -> String {
            let l = Localizer(language: language)
            switch self {
            case .permission: return l("请在系统设置允许麦克风和语音识别。")
            case .unavailable: return l("当前设备或语言不支持本地转写。不会上传到云端；可保留音频后重试。")
            case .recording: return l("录音未成功完成，请检查音频设备。")
            case .interrupted: return l("录音被系统中断，已结束任务；保留的片段可手动重试转写。")
            case .busy: return l("已有录音或转写任务，请稍后重试。")
            case .timeout: return l("本地转写超时，可稍后重试。")
            }
        }
    }
    func permissions() async -> Bool {
        let mic = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        guard mic else { return false }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
    @discardableResult
    func start(url: URL, maximumDuration: TimeInterval, completion: @escaping (Result<URL, Error>) -> Void) throws -> Date {
        guard recorder == nil, speechSlot.current == nil, transcriptionSlot.current == nil else { throw CaptureError.busy }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                 AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            r.delegate = self
            recorder = r; self.url = url; finished = completion
            guard r.prepareToRecord() else { throw CaptureError.recording }
            let startedAt = Date()
            guard r.record(forDuration: min(180 * 60, max(60, maximumDuration))) else { throw CaptureError.recording }
            return startedAt
        } catch {
            recorder?.delegate = nil; recorder?.stop()
            recorder = nil; self.url = nil; finished = nil
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }
    func stop() {
        guard let recorder else { return }
        recorder.stop()
        // Never depend on a delegate callback to release the application lock.
        completeRecording(recorder, error: nil)
    }
    func interrupt() {
        guard let recorder else { return }
        recorder.stop()
        completeRecording(recorder, error: CaptureError.interrupted)
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.completeRecording(recorder, error: flag ? nil : CaptureError.recording) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.completeRecording(recorder, error: error ?? CaptureError.recording) }
    }
    private func completeRecording(_ sender: AVAudioRecorder, error: Error?) {
        guard recorder === sender, let completion = finished, let url else { return }
        sender.delegate = nil; sender.stop()
        finished = nil; recorder = nil; self.url = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let error { completion(.failure(error)) } else { completion(.success(url)) }
    }
    func transcribe(url: URL, language: AppLanguage,
                    progress: @escaping @MainActor (Int, Int) -> Void) async throws -> TranscriptionResult {
        guard recorder == nil, let operation = transcriptionSlot.begin() else { throw CaptureError.busy }
        defer { transcriptionSlot.finish(operation) }
        let asset = AVURLAsset(url: url)
        guard let support = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocaleIdentifier)),
              support.isAvailable, support.supportsOnDeviceRecognition else { throw CaptureError.unavailable }
        let time = try await asset.load(.duration)
        let duration = time.seconds
        let ranges = RecordingPolicy.chunks(duration: duration)
        guard !ranges.isEmpty else { throw CaptureError.recording }
        var text: [String] = [], segments: [TranscriptSegment] = []
        var failures = 0, completed = 0
        var lastError: Error = CaptureError.unavailable
        progress(0, ranges.count)
        for range in ranges {
            let temporary = url.deletingLastPathComponent().appendingPathComponent("chunk-" + UUID().uuidString + ".m4a")
            do {
                let input: URL
                if ranges.count == 1 { input = url }
                else {
                    try await export(asset: asset, range: range, to: temporary)
                    input = temporary
                }
                let (chunkText, chunkSegments) = try await recognize(url: input, language: language)
                text.append(chunkText)
                segments += chunkSegments.map { .init(text: $0.text, offset: $0.offset + range.lowerBound, duration: $0.duration) }
                completed += 1
            } catch { failures += 1; lastError = error }
            try? FileManager.default.removeItem(at: temporary)
            progress(completed + failures, ranges.count)
        }
        guard completed > 0 else { throw lastError }
        return TranscriptionResult(text: text.joined(separator: "\n"), segments: segments, failedChunks: failures)
    }
    private func export(asset: AVURLAsset, range: Range<Double>, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureError.recording }
        session.outputURL = url; session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 600))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: session.error ?? CaptureError.recording) }
            }
        }
    }
    private func recognize(url: URL, language: AppLanguage) async throws -> (String, [TranscriptSegment]) {
        guard recorder == nil, let id = speechSlot.begin() else { throw CaptureError.busy }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocaleIdentifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            speechSlot.finish(id); throw CaptureError.unavailable
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            speechCompletion = { continuation.resume(with: $0) }
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.speechSlot.owns(id) else { return }
                    if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map {
                            TranscriptSegment(text: $0.substring, offset: $0.timestamp, duration: $0.duration)
                        }
                        self.completeSpeech(id, .success((result.bestTranscription.formattedString, segments)))
                    } else if let error { self.completeSpeech(id, .failure(error)) }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                self?.completeSpeech(id, .failure(CaptureError.timeout))
            }
        }
    }
    private func completeSpeech(_ id: UUID, _ result: Result<(String, [TranscriptSegment]), Error>) {
        guard speechSlot.owns(id), let completion = speechCompletion else { return }
        speechSlot.finish(id)
        speechCompletion = nil; deadline?.cancel(); deadline = nil
        let previous = speechTask; speechTask = nil; recognizer = nil
        previous?.cancel(); completion(result)
    }
}
