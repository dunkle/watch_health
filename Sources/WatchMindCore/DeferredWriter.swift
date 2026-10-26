/// Keeps the latest snapshot in memory until protected storage becomes available.
/// The caller still owns initialization, corruption handling and user-visible status.
public struct DeferredWriter<Value> {
    private var pending: Value?
    public var hasPending: Bool { pending != nil }
    public init() {}
    @discardableResult
    public mutating func save(_ value: Value, isAvailable: () -> Bool, write: (Value) throws -> Void) throws -> Bool {
        pending = value
        return try flush(isAvailable: isAvailable, write: write)
    }
    @discardableResult
    public mutating func flush(isAvailable: () -> Bool, write: (Value) throws -> Void) throws -> Bool {
        guard let value = pending else { return true }
        guard isAvailable() else { return false }
        do { try write(value) }
        catch {
            // Handle a lock that happened between the availability check and the write.
            if !isAvailable() { return false }
            throw error
        }
        pending = nil
        return true
    }
}
