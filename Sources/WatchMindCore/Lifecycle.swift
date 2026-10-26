import Foundation

/// Owns one async operation. A late callback cannot release a newer operation.
public struct OperationSlot: Sendable {
    public private(set) var current: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard current == nil else { return nil }
        let id = UUID(); current = id; return id
    }
    public func owns(_ id: UUID) -> Bool { current == id }
    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard owns(id) else { return false }
        current = nil; return true
    }
    public mutating func cancel() { current = nil }
}

public struct WorkoutLifecycle: Sendable {
    public enum Phase: Sendable { case idle, starting, running, stopping }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID(); self.id = id; phase = .starting; return id
    }
    @discardableResult public mutating func started(_ id: UUID) -> Bool {
        guard self.id == id, phase == .starting else { return false }
        phase = .running; return true
    }
    @discardableResult public mutating func stop(_ id: UUID) -> Bool {
        guard self.id == id, phase == .running || phase == .starting else { return false }
        phase = .stopping; return true
    }
    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        self.id = nil; phase = .idle; return true
    }
}
