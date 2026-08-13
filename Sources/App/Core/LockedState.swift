import Foundation

/// Protects mutable state with a lock that is available on every supported
/// macOS version.
final class LockedState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        self.state = initialState
    }

    @discardableResult
    func withLock<Result>(
        _ body: (inout State) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
