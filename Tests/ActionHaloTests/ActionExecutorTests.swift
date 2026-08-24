import XCTest
@testable import ActionHalo

final class ActionExecutorTests: XCTestCase {

    func testResolvedFileURLSupportsAbsolutePath() {
        let url = ActionExecutor.resolvedFileURL(from: "/tmp/example.txt")
        XCTAssertEqual(url?.path, "/tmp/example.txt")
    }

    func testResolvedFileURLSupportsTildePath() {
        let url = ActionExecutor.resolvedFileURL(from: "~/Desktop")
        XCTAssertEqual(url?.path, ("~/Desktop" as NSString).expandingTildeInPath)
    }

    func testResolvedFileURLSupportsQuotedPath() {
        let url = ActionExecutor.resolvedFileURL(from: "\"/tmp/hello world.txt\"")
        XCTAssertEqual(url?.path, "/tmp/hello world.txt")
    }

    func testResolvedFileURLSupportsFileURL() {
        let url = ActionExecutor.resolvedFileURL(from: "file:///tmp/example.txt")
        XCTAssertEqual(url?.path, "/tmp/example.txt")
    }

    func testResolvedFileURLRejectsNonPathText() {
        XCTAssertNil(ActionExecutor.resolvedFileURL(from: "just some text"))
        XCTAssertNil(ActionExecutor.resolvedFileURL(from: "relative/path.txt"))
    }
}
