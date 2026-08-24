import Dispatch
import XCTest
@testable import ActionHalo

final class LockedStateTests: XCTestCase {
    func testWithLockMutatesAndReturnsState() {
        let state = LockedState(initialState: 1)

        let updatedValue = state.withLock { value in
            value += 2
            return value
        }

        XCTAssertEqual(updatedValue, 3)
        XCTAssertEqual(state.withLock { $0 }, 3)
    }

    func testWithLockSerializesConcurrentMutations() {
        let state = LockedState(initialState: 0)

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            state.withLock { $0 += 1 }
        }

        XCTAssertEqual(state.withLock { $0 }, 1_000)
    }
}
