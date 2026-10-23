import Cocoa
import XCTest
@testable import ActionHalo

final class MenuCopyTests: GlobalStateTestCase {
    @MainActor
    func testExplicitCopyUsesCapturedTextAfterSourceAppLosesFocus() throws {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(
            #"{"name":"Copy","identifier":"com.actionhalo.copy","action":{"type":"copy"}}"#.utf8
        ))
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/copy-test"))
        let pasteboard = NSPasteboard.general
        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(from: pasteboard))
        var ownedState: AccessibilityManager.PasteboardState?
        defer {
            if let ownedState {
                _ = AccessibilityManager.restorePasteboardSnapshot(snapshot, to: pasteboard, ifCurrentStateMatches: ownedState)
            }
            snapshot.discardTemporaryFiles()
        }

        let text = "  已选文字 👩🏽‍💻\ne\u{301}\t"
        for action in [RadialMenuAction.plugin(plugin), .builtIn(.copy)] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("previous clipboard", forType: .string))
            let delegate = AppDelegate()
            // The ring can still be clicked while macOS restores the source app's focus.
            delegate.handleMenuAction(
                RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: action),
                text: text,
                targetProcessIdentifier: .max,
                targetFocusedElement: nil
            )
            let state = AccessibilityManager.stablePasteboardState(
                readChangeCount: { pasteboard.changeCount },
                readString: { pasteboard.string(forType: .string) }
            )
            if state?.string == text || state?.string == "previous clipboard" { ownedState = state }
            XCTAssertEqual(state?.string.map { Array($0.utf8) }, Array(text.utf8))
        }
    }
}
