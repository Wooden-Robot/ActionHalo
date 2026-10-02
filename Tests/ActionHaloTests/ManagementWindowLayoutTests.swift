import AppKit
import XCTest
@testable import ActionHalo

@MainActor
final class ManagementWindowLayoutTests: GlobalStateTestCase {
    func testHeadersStayVisibleAndAnchoredWhenManagementWindowsResize() throws {
        let controllers: [NSWindowController] = [
            CurrentAppPluginsWindow(appName: "Test App", bundleID: "com.test.layout"),
            PerAppOverridesWindow(),
            BlacklistWindow(),
            DiagnosticsWindow()
        ]
        defer { controllers.forEach { $0.close() } }

        for controller in controllers {
            let window = try XCTUnwrap(controller.window)
            let contentView = try XCTUnwrap(window.contentView)
            let scrollView = try XCTUnwrap(contentView.subviews.compactMap { $0 as? NSScrollView }.first)
            let originalSize = contentView.bounds.size
            let headers = contentView.subviews.filter { $0 !== scrollView }.map {
                (view: $0, topInset: contentView.bounds.maxY - $0.frame.maxY,
                 rightInset: contentView.bounds.maxX - $0.frame.maxX)
            }
            XCTAssertFalse(headers.isEmpty)
            XCTAssertEqual(window.contentMinSize, originalSize)

            for size in [
                NSSize(width: originalSize.width + 120, height: originalSize.height + 100),
                originalSize
            ] {
                window.setContentSize(size)
                contentView.layoutSubtreeIfNeeded()

                for header in headers {
                    XCTAssertTrue(contentView.bounds.contains(header.view.frame), window.title)
                    XCTAssertFalse(scrollView.frame.intersects(header.view.frame), window.title)
                    XCTAssertEqual(
                        contentView.bounds.maxY - header.view.frame.maxY,
                        header.topInset, accuracy: 0.01, window.title
                    )
                    XCTAssertEqual(
                        contentView.bounds.maxX - header.view.frame.maxX,
                        header.rightInset, accuracy: 0.01, window.title
                    )
                }
            }
        }
    }
}
