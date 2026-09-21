import XCTest
import Cocoa
@testable import ActionHalo

// Opt-in: select a single line in a disposable TextEdit document, then run
// ACTIONHALO_LIVE_LATENCY=1 swift test --filter SelectionLatencyTests.
final class SelectionLatencyTests: XCTestCase {
    @MainActor
    func testLiveTextEditDragAcquisitionLatency() async throws {
        guard ProcessInfo.processInfo.environment["ACTIONHALO_LIVE_LATENCY"] == "1" else {
            throw XCTSkip("Opt-in measurement against the disposable TextEdit fixture")
        }
        XCTAssertTrue(AXIsProcessTrusted())
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first)
        var raw: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &raw), .success)
        let focused = try XCTUnwrap(raw)
        XCTAssertEqual(CFGetTypeID(focused), AXUIElementGetTypeID())
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var selectedRange: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange), .success)
        var selectedBounds: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, try XCTUnwrap(selectedRange), &selectedBounds), .success)
        let boundsValue = try XCTUnwrap(selectedBounds)
        XCTAssertEqual(CFGetTypeID(boundsValue), AXValueGetTypeID())
        var bounds = CGRect.zero
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(boundsValue, to: AXValue.self), .cgRect, &bounds))
        let points = try [CGPoint(x: bounds.minX + 0.5, y: bounds.midY), CGPoint(x: bounds.maxX - 0.5, y: bounds.midY)].map {
            try XCTUnwrap(AccessibilityManager.appKitScreenPoint(for: $0))
        }
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let result: (candidate: AXUIElement, assessment: AccessibilityManager.AssessedFocusedElement)? = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
                retryDelays: AccessibilityManager.focusedElementRetryDelays,
                attempt: {
                    guard let assessment = await AccessibilityManager.shared.assessFocusedElement(
                        element, bundleID: "com.apple.TextEdit", points: points,
                        requireUsableSelection: true, retryDelays: []
                    ) else { return nil as (candidate: AXUIElement, assessment: AccessibilityManager.AssessedFocusedElement)? }
                    return (candidate: element, assessment: assessment)
                },
                isTerminal: { $0.assessment.protection == .protectedContent },
                canAcceptEarly: { _, result in result.assessment.selectionMatchesGesture },
                wait: { delay in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return true
                }
            )
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let assessment = try XCTUnwrap(result?.assessment.assessment)
            XCTAssertEqual(assessment.protection, .unprotected)
            XCTAssertNotNil(assessment.selectionSnapshot?.usableText)
            print(String(format: "LIVE_DRAG_ACQUISITION %.1f ms", milliseconds))
            XCTAssertLessThan(milliseconds, 100, "Verified drag acquisition must fit inside the immediate-response budget")
        }
    }
}
