import AVFoundation
import Speech
import WatchMindCore

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var finished: ((Result<URL, Error>) -> Void)?
    private var url: URL?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechCompletion: ((Result<(String, [TranscriptSegment]), Error>) -> Void)?
    private var deadline: Task<Void, Never>?
    enum CaptureError: LocalizedError {
        case permission, unavailable, recording
        var errorDescription: String? {
            switch self {
            case .permission: return "请在系统设置允许麦克风和语音识别。"
            case .unavailable: return "当前设备或语言不支持本地转写。不会上传到云端；可保留音频后重试。"
            case .recording: return "录音未成功完成，请检查音频设备。"
            }
        }
    }
    func permissions() async -> Bool {
        let mic = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        return mic && speech
    }
    func start(url: URL, completion: @escaping (Result<URL, Error>) -> Void) throws {
        guard recorder == nil else { throw CaptureError.recording }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [])
        try audio.setActive(true)
        let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
             AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        r.delegate = self
        guard r.prepareToRecord(), r.record(forDuration: 30) else {
            try? audio.setActive(false); throw CaptureError.recording
        }
        recorder = r; self.url = url; finished = completion
    }
    func stop() { recorder?.stop() }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.completeRecording(success: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.completeRecording(success: false) }
    }
    private func completeRecording(success: Bool) {
        guard let completion = finished, let url else { return }
        finished = nil; recorder = nil; self.url = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        completion(success ? .success(url) : .failure(CaptureError.recording))
    }
    func transcribe(url: URL) async throws -> (String, [TranscriptSegment]) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw CaptureError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            speechCompletion = { continuation.resume(with: $0) }
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map {
                            TranscriptSegment(text: $0.substring, offset: $0.timestamp, duration: $0.duration)
                        }
                        self.completeSpeech(.success((result.bestTranscription.formattedString, segments)))
                    } else if let error { self.completeSpeech(.failure(error)) }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.completeSpeech(.failure(CaptureError.unavailable))
            }
        }
    }
    private func completeSpeech(_ result: Result<(String, [TranscriptSegment]), Error>) {
        guard let completion = speechCompletion else { return }
        speechCompletion = nil; deadline?.cancel(); deadline = nil
        speechTask?.cancel(); speechTask = nil; completion(result)
    }
}
