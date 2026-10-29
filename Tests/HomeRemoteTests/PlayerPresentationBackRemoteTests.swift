import XCTest

@MainActor
final class PlayerPresentationBackRemoteTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLoadedSurfaceMenuDismissesBeforeAnyTouchpadTap() {
        let app = launch()
        defer { app.terminate() }
        waitForLoadedSurface(app)
        expect(app, "player-back-controls", "false")
        expect(app, "player-back-make-count", "1")
        expect(app, "player-back-load-count", "1")
        XCUIRemote.shared.press(.menu)
        assertDismissed(app)
        expect(app, "player-back-stop-count", "1")
    }

    func testDownloadBackReturnsToChooserThenToolbarThenSurface() {
        let app = launch()
        defer { app.terminate() }
        waitForLoadedSurface(app)
        let subtitles = app.buttons["player-control-captions.bubble"]
        XCUIRemote.shared.press(.up)
        expect(app, "player-back-surface-focus", "false")
        expect(app, "player-back-controls", "true")
        XCTAssertTrue(subtitles.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        let download = app.buttons["Download Subtitles…"]
        waitUntil("Chooser should initially focus Download") {
            download.exists && download.hasFocus
        }
        XCUIRemote.shared.press(.select)
        let result = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "Back regression subtitle"
        )).firstMatch
        waitUntil("Real download/search screen must show its result") {
            result.exists && result.hasFocus
        }
        XCUIRemote.shared.press(.menu)
        waitUntil("Back must return only to the subtitle chooser") {
            !result.exists && download.exists && download.hasFocus
        }
        expect(app, "player-back-panel", "true")
        XCTAssertFalse(app.staticTexts["player-back-dismissed"].exists)
        XCUIRemote.shared.press(.menu)
        expect(app, "player-back-panel", "false")
        XCUIRemote.shared.press(.select)
        waitUntil("The restored toolbar button must reopen the subtitle chooser") {
            download.exists && download.hasFocus
        }
        XCUIRemote.shared.press(.menu)
        expect(app, "player-back-panel", "false")
        XCUIRemote.shared.press(.menu)
        expect(app, "player-back-surface-focus", "true")
        expect(app, "player-back-controls", "true")
        XCUIRemote.shared.press(.menu)
        expect(app, "player-back-controls", "false")
        XCTAssertFalse(app.staticTexts["player-back-dismissed"].exists)
        XCUIRemote.shared.press(.menu)
        assertDismissed(app)
    }

    func testMenuCancelsPreModelDetailResolution() {
        let app = launch(extra: ["--player-back-hold-details"])
        defer { app.terminate() }
        expect(app, "player-back-preparing", "true")
        expect(app, "player-back-make-count", "0")
        XCUIRemote.shared.press(.menu)
        assertDismissed(app)
        expect(app, "player-back-cancelled", "true")
        expect(app, "player-back-preparing", "false")
        expect(app, "player-back-make-count", "0")
        expect(app, "player-back-load-count", "0")
    }

    func testMenuCancelsActualInitialVersionChoice() {
        let app = launch(extra: ["--player-back-versions"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["version-choice-cancel"].waitForExistence(timeout: 10))
        expect(app, "player-back-preparing", "true")
        expect(app, "player-back-make-count", "0")
        XCUIRemote.shared.press(.menu)
        assertDismissed(app)
        expect(app, "player-back-cancelled", "true")
        expect(app, "player-back-preparing", "false")
        expect(app, "player-back-make-count", "0")
        expect(app, "player-back-load-count", "0")
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--player-presentation-back-fixture"] + extra
        app.launch()
        return app
    }

    private func waitForLoadedSurface(_ app: XCUIApplication) {
        expect(app, "player-back-phase", "ready")
        expect(app, "player-back-surface-focus", "true")
    }

    private func assertDismissed(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["player-back-dismissed"].waitForExistence(timeout: 10),
            "Menu must dismiss the actual PlayerPresentation cover."
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func expect(_ app: XCUIApplication, _ identifier: String, _ value: String) {
        waitUntil("\(identifier) should become \(value)") {
            let element = app.staticTexts[identifier]
            return element.exists && element.label == value
        }
    }

    private func waitUntil(_ message: String, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10), .completed, message
        )
    }
}
