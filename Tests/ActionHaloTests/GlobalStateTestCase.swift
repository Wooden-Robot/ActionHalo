import Darwin
import Foundation
import XCTest

/// Serializes tests that exercise process-wide AppKit singletons or the app's
/// shared UserDefaults domain. SwiftPM may run individual XCTest methods in
/// separate processes, so an in-process lock alone is not sufficient.
class GlobalStateTestCase: XCTestCase {
    private static let processLock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var isolatedDefaultsKeys: Set<String> = []
    private var savedDefaultsValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()

        Self.processLock.lock()
        let lockPath = "/tmp/com.actionhalo.tests.\(getuid()).global-state.lock"
        fileDescriptor = lockPath.withCString {
            open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        precondition(fileDescriptor >= 0, "Unable to open the ActionHalo test isolation lock.")
        precondition(flock(fileDescriptor, LOCK_EX) == 0, "Unable to acquire the ActionHalo test isolation lock.")
    }

    func isolateStandardUserDefaults(keys: [String]) {
        for key in keys where isolatedDefaultsKeys.insert(key).inserted {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedDefaultsValues[key] = value
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in isolatedDefaultsKeys {
            if let value = savedDefaultsValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        isolatedDefaultsKeys.removeAll()
        savedDefaultsValues.removeAll()

        if fileDescriptor >= 0 {
            _ = flock(fileDescriptor, LOCK_UN)
            _ = close(fileDescriptor)
            fileDescriptor = -1
        }
        Self.processLock.unlock()

        super.tearDown()
    }
}
