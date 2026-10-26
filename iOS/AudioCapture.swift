import AVFoundation
import Speech
import WatchMindCore

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var finished: ((Result<URL, Error>) -> Void)?
    private var url: URL?
    private var speechTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var speechSlot = OperationSlot()
    private var speechCompletion: ((Result<(String, [TranscriptSegment]), Error>) -> Void)?
    private var deadline: Task<Void, Never>?
    enum CaptureError: LocalizedError {
        case permission, unavailable, recording, interrupted, busy, timeout
        var errorDescription: String? {
            switch self {
            case .permission: return "请在系统设置允许麦克风和语音识别。"
            case .unavailable: return "当前设备或语言不支持本地转写。不会上传到云端；可保留音频后重试。"
            case .recording: return "录音未成功完成，请检查音频设备。"
            case .interrupted: return "录音被系统中断，已结束任务；保留的片段可手动重试转写。"
            case .busy: return "已有录音或转写任务，请稍后重试。"
            case .timeout: return "本地转写超时，可稍后重试。"
            }
        }
    }
    func permissions() async -> Bool {
        let mic = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        guard mic else { return false }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
    @discardableResult
    func start(url: URL, completion: @escaping (Result<URL, Error>) -> Void) throws -> Date {
        guard recorder == nil, speechSlot.current == nil else { throw CaptureError.busy }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                 AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            r.delegate = self
            recorder = r; self.url = url; finished = completion
            let startedAt = Date()
            guard r.prepareToRecord(), r.record(forDuration: 30) else { throw CaptureError.recording }
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
    func transcribe(url: URL) async throws -> (String, [TranscriptSegment]) {
        guard recorder == nil, let id = speechSlot.begin() else { throw CaptureError.busy }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
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
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
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
