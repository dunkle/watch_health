import Foundation

public enum ProcessingStage: String, Sendable {
    case unavailable, pending, running, paused, complete, partial, failed, unknown
    public var title: String {
        switch self {
        case .unavailable: return "不适用"
        case .pending: return "尚未开始"
        case .running: return "处理中"
        case .paused: return "已暂停"
        case .complete: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败，可检查后重试"
        case .unknown: return "状态待核对"
        }
    }
}
public extension Episode {
    var recordingStage: ProcessingStage {
        if status == .recording { return .running }
        if status == .paused { return .paused }
        guard captureStarted != nil else { return status == .missed ? .unavailable : .failed }
        return captureEnded != nil ? .complete : .unknown
    }
    var transcriptionStage: ProcessingStage {
        switch status {
        case .ready: return .complete
        case .partial: return .partial
        case .transcribing: return .running
        case .failed: return transcriptionAttempted == true ? .failed : .unknown
        case .recording, .paused: return .pending
        case .missed, .linked: return .unavailable
        }
    }
}
