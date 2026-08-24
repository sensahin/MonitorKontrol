import CoreGraphics
import XCTest

final class MonitorKontrolUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuBarShowsCurrentDisplayState() throws {
        let app = XCUIApplication()
        // Keep the status item visible in hardware-free CI without changing
        // the user's saved visibility preference.
        app.launchEnvironment["MONITORKONTROL_UI_QA"] = "1"
        app.launch()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 8),
            "MonitorKontrol did not publish its menu-bar item.\n\(app.debugDescription)"
        )

        // MenuBarExtra exposes its popover as an AXSystemDialog. Scoping the
        // queries to that dialog avoids XCTest intermittently omitting the
        // separate menu-extra window from application-wide static-text queries.
        let panel = app.dialogs.firstMatch
        openPanel(panel, from: statusItem)
        XCTAssertTrue(
            panel.exists,
            "MonitorKontrol's menu panel did not open.\n\(app.debugDescription)"
        )
        XCTAssertTrue(panel.staticTexts["monitorkontrol-title"].exists)
        XCTAssertTrue(panel.buttons["Settings…"].exists)
        XCTAssertTrue(panel.buttons["Quit"].exists)
        // XCTest exposes SwiftUI sliders through the application-wide query,
        // even though the surrounding AXSystemDialog is separately scoped.
        // A headless Mac can legitimately have no displays, while a Mac mini
        // may only expose external controls, so this smoke test accepts every
        // valid discovery state instead of assuming a built-in panel exists.
        let firstDisplaySlider = app.sliders.firstMatch
        let noDisplaysMessage = panel.staticTexts["No Displays Found"]
        XCTAssertTrue(
            firstDisplaySlider.waitForExistence(timeout: 8)
                || noDisplaysMessage.waitForExistence(timeout: 1),
            "The menu showed neither display controls nor the empty state.\n\(app.debugDescription)"
        )

        let lgSlider = app.sliders["external-brightness-1E6D-5B55"]
        if targetLGIsOnline {
            XCTAssertTrue(lgSlider.waitForExistence(timeout: 8))
            if onlineDisplayCount > 1 {
                XCTAssertTrue(app.sliders["all-displays-brightness"].exists)
            }
        }
    }

    @MainActor
    func testMenuBarClosesAndReopensWithProductionVisibility() throws {
        guard targetLGIsOnline else {
            throw XCTSkip("The production visibility policy requires an external display.")
        }

        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 8))

        let panel = app.dialogs.firstMatch
        openPanel(panel, from: statusItem)
        XCTAssertTrue(panel.exists)

        clickStatusItem(statusItem)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))

        clickStatusItem(statusItem)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["monitorkontrol-title"].exists)
    }

    private var targetLGIsOnline: Bool {
        onlineDisplayIDs.contains {
            CGDisplayVendorNumber($0) == 0x1E6D && CGDisplayModelNumber($0) == 0x5B55
        }
    }

    private var onlineDisplayCount: Int {
        onlineDisplayIDs.count
    }

    private var onlineDisplayIDs: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return Array(displayIDs.prefix(Int(count)))
    }

    private func clickStatusItem(_ statusItem: XCUIElement) {
        if statusItem.isHittable {
            statusItem.click()
            return
        }

        clickStatusItemAtGlobalPoint(statusItem)
    }

    private func openPanel(_ panel: XCUIElement, from statusItem: XCUIElement) {
        clickStatusItem(statusItem)
        if panel.waitForExistence(timeout: 3) { return }

        // Menu-bar extras occasionally report themselves as hittable before
        // XCTest can deliver the accessibility click. A real global click is
        // the deterministic fallback used for unusual screen arrangements.
        clickStatusItemAtGlobalPoint(statusItem)
        if panel.waitForExistence(timeout: 3) { return }

        // If the first click opened a panel that AX published late, the second
        // click may have closed it. A final click leaves the toggle in the open
        // state while still keeping the failure bounded and observable.
        clickStatusItemAtGlobalPoint(statusItem)
        _ = panel.waitForExistence(timeout: 5)
    }

    private func clickStatusItemAtGlobalPoint(_ statusItem: XCUIElement) {
        // XCTest refuses to click a status item on a display arranged above
        // the MacBook because that screen has a negative global Y origin.
        // Quartz accepts the real global point, so synthesize the same click
        // there instead of skipping coverage for that common arrangement.
        let point = CGPoint(x: statusItem.frame.midX, y: statusItem.frame.midY)
        let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        XCTAssertNotNil(down)
        XCTAssertNotNil(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
