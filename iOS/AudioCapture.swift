import AVFoundation
import Speech
import WatchMindCore

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    struct CapturedAudio { var url: URL; var duration: TimeInterval }
    private var finished: ((Result<CapturedAudio, Error>) -> Void)?
    private var url: URL?
    struct TranscriptionResult {
        var text: String
        var segments: [TranscriptSegment]
        var failedChunks: Int
        var duration: TimeInterval
        var spans: [(Range<Double>, ProcessingSpan.Outcome)]
    }
    private var transcriptionSlot = OperationSlot()
    private var cancelledTranscription: UUID?
    private var exportSession: AVAssetExportSession?
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
            case .interrupted: return l("录音被系统中断，已保留片段；可继续录音或结束并转写。")
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
    func start(url: URL, maximumDuration: TimeInterval, completion: @escaping (Result<CapturedAudio, Error>) -> Void) throws -> Date {
        guard recorder == nil, speechSlot.current == nil, transcriptionSlot.current == nil else { throw CaptureError.busy }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try audio.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                 AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            r.delegate = self
            recorder = r; self.url = url; finished = completion
            guard r.prepareToRecord() else { throw CaptureError.recording }
            let startedAt = Date()
            guard r.record(forDuration: min(86400, max(0.1, maximumDuration))) else { throw CaptureError.recording }
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
        // Never depend on a delegate callback to release the application lock.
        completeRecording(recorder, error: nil)
    }
    func interrupt() {
        guard let recorder else { return }
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
        let recordedTime = sender.currentTime
        sender.delegate = nil; sender.stop()
        finished = nil; recorder = nil; self.url = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let error { completion(.failure(error)) }
        else {
            // Read the finalized file, not elapsed wall time (the delegate can be delayed).
            let file = try? AVAudioFile(forReading: url)
            let measured = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? recordedTime
            let duration = measured.isFinite ? max(0, measured) : 0
            completion(.success(CapturedAudio(url: url, duration: duration)))
        }
    }
    /// Cancel the active recognizer/export and release the caller at the next safe boundary.
    /// Already delivered checkpoints remain durable; cancellation never changes saved audio.
    func cancelTranscription() {
        guard let operation = transcriptionSlot.current else { return }
        cancelTranscription(operation: operation)
    }
    private func cancelTranscription(operation: UUID) {
        guard transcriptionSlot.owns(operation) else { return }
        cancelledTranscription = operation
        exportSession?.cancelExport()
        if let speech = speechSlot.current { completeSpeech(speech, .failure(CancellationError())) }
    }
    private func checkTranscription(_ operation: UUID) throws {
        try Task.checkCancellation()
        if cancelledTranscription == operation || !transcriptionSlot.owns(operation) { throw CancellationError() }
    }
    func transcribe(url: URL, language: AppLanguage, filterQuiet: Bool = false, sensitivity: Int = 3, protectedOffsets: [Double] = [],
                    resuming: TranscriptionResult? = nil,
                    checkpoint: (@MainActor (TranscriptionResult) throws -> Void)? = nil,
                    progress: @escaping @MainActor (Int, Int) -> Void) async throws -> TranscriptionResult {
        guard recorder == nil, let operation = transcriptionSlot.begin() else { throw CaptureError.busy }
        cancelledTranscription = nil
        defer {
            transcriptionSlot.finish(operation)
            if cancelledTranscription == operation { cancelledTranscription = nil }
        }
        return try await withTaskCancellationHandler(operation: {
            try checkTranscription(operation)
            let asset = AVURLAsset(url: url)
            guard let support = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocaleIdentifier)),
                  support.isAvailable, support.supportsOnDeviceRecognition else { throw CaptureError.unavailable }
            let time = try await asset.load(.duration)
            let duration = time.seconds
            let ranges = RecordingPolicy.chunks(duration: duration)
            guard !ranges.isEmpty else { throw CaptureError.recording }
            let seed = FileTranscript(audioName: url.lastPathComponent, text: resuming?.text ?? "", segments: resuming?.segments ?? [])
            var file = seed
            // A legacy full transcript has no word alignment. Its successful processing spans
            // cannot prove which words were retained by a partial checkpoint. Re-read every
            // range, while preserving the old text until a complete fresh result is available.
            let legacyUnaligned = !seed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seed.segments.isEmpty
            let resumableSpans = legacyUnaligned ? [] : (resuming?.spans ?? [])
            let resumedSpans = resumableSpans.map { TranscriptionChunkSpan($0.0, outcome: $0.1) }
            var incomingSegments = seed.segments.filter { segment in resumedSpans.contains { $0.succeeded && $0.range.contains(segment.offset) } }
            var chunkTexts: [(Range<Double>, String)] = []
            for span in resumedSpans where span.succeeded {
                chunkTexts.append((span.range, seed.segments.filter { span.range.contains($0.offset) }.map(\.text).joined(separator: " ")))
            }
            var spans = resumableSpans.filter { $0.0.lowerBound >= 0 && $0.0.upperBound <= duration }
            var completed = 0, skipped = 0, done = 0
            var lastError: Error = CaptureError.unavailable
            progress(0, ranges.count)
            for range in ranges {
                try checkTranscription(operation)
                let oldSpans = spans.map { TranscriptionChunkSpan($0.0, outcome: $0.1) }
                if TranscriptionMerge.isCompleted(range, spans: oldSpans) {
                    completed += 1; done += 1; progress(done, ranges.count); continue
                }
                let temporary = url.deletingLastPathComponent().appendingPathComponent("chunk-" + UUID().uuidString + ".m4a")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let outcome: ProcessingSpan.Outcome
                var chunkText = "", chunkSegments: [TranscriptSegment] = []
                do {
                    let input: URL
                    if ranges.count == 1 { input = url }
                    else { try await export(asset: asset, range: range, to: temporary); input = temporary }
                    try checkTranscription(operation)
                    let protected = protectedOffsets.contains { $0 >= range.lowerBound - 20 && $0 <= range.upperBound + 20 }
                    var shouldSkip = false
                    if filterQuiet && !protected {
                        let quality = await Task.detached(priority: .utility) { AudioQuality.analyze(url: input, sensitivity: sensitivity) }.value
                        try checkTranscription(operation)
                        shouldSkip = AudioEnergy.shouldSkip(quality, range: range, protectedOffsets: protectedOffsets)
                    }
                    if shouldSkip { outcome = .skipped; skipped += 1 }
                    else {
                        let recognized = try await recognize(url: input, language: language)
                        try checkTranscription(operation)
                        chunkText = recognized.0
                        chunkSegments = recognized.1.map { .init(text: $0.text, offset: $0.offset + range.lowerBound, duration: $0.duration) }
                        outcome = chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .recognized
                        completed += 1
                    }
                } catch {
                    try checkTranscription(operation)
                    if error is CancellationError { throw error }
                    lastError = error; outcome = .failed
                }
                spans.removeAll { $0.0.overlaps(range) }
                spans.append((range, outcome)); spans.sort { $0.0.lowerBound < $1.0.lowerBound }
                incomingSegments.removeAll { range.contains($0.offset) }
                incomingSegments += chunkSegments
                chunkTexts.removeAll { $0.0.overlaps(range) }
                if outcome == .recognized || outcome == .empty { chunkTexts.append((range, chunkText)) }
                file = TranscriptionMerge.merge(previous: seed, audioName: url.lastPathComponent,
                    text: chunkTexts.sorted { $0.0.lowerBound < $1.0.lowerBound }.map(\.1).joined(separator: "\n"),
                    segments: incomingSegments, spans: spans.map { .init($0.0, outcome: $0.1) }, completeRange: 0..<duration)
                let result = TranscriptionResult(text: file.text, segments: file.segments,
                    failedChunks: spans.filter { $0.1 == .failed }.count, duration: duration, spans: spans)
                // A durable checkpoint is delivered after every outcome, not after the entire file.
                // A failed persistence callback aborts the job instead of doing more unprotected work.
                try checkpoint?(result)
                try checkTranscription(operation)
                done += 1; progress(done, ranges.count)
            }
            guard completed > 0 || skipped > 0 else { throw lastError }
            return TranscriptionResult(text: file.text, segments: file.segments,
                failedChunks: spans.filter { $0.1 == .failed }.count, duration: duration, spans: spans)
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelTranscription(operation: operation) }
        })
    }
    private func export(asset: AVURLAsset, range: Range<Double>, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureError.recording }
        exportSession = session
        defer { if exportSession === session { exportSession = nil } }
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
