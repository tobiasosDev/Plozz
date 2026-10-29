import XCTest

/// Captures the Apple TV-style guide with real listings, logos and programme
/// art from a loopback M3U/XMLTV source. Opt in with
/// `TEST_RUNNER_PLOZZ_LIVE_TV_CAPTURE=<folder>` and
/// `TEST_RUNNER_PLOZZ_LIVE_TV_LOOPBACK=http://127.0.0.1:<port>`.
@MainActor
final class LiveTVRedesignCaptureTests: XCTestCase {
    func testGuideHeaderChipsAndFocusedCell() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["PLOZZ_LIVE_TV_CAPTURE"], !folder.isEmpty,
              let loopback = environment["PLOZZ_LIVE_TV_LOOPBACK"], !loopback.isEmpty else {
            throw XCTSkip("Design capture needs a loopback Live TV source.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--preview-introduction-fixture", "--preview-suite=Capture.\(UUID().uuidString)",
            "--reset-preview-choice", "--preview-native-sidebar", "--preview-loopback=\(loopback)",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        defer { app.terminate() }

        let current = app.buttons.matching(NSPredicate(format: "label == %@", "NETZ NATUR")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 30), app.debugDescription)
        // The guide's first focus can be its first channel; its programme is beside it.
        let station = app.buttons["live-tv-channel-channels-1"]
        let entered = NSPredicate { _, _ in self.containsFocus(current) || self.containsFocus(station) }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: entered, object: nil)], timeout: 10
        ), .completed, app.debugDescription)
        for _ in 0..<3 where !containsFocus(current) { XCUIRemote.shared.press(.right) }
        assertFocused(current, in: app)
        // The header's art waits for focus to settle, then decodes.
        Thread.sleep(forTimeInterval: 2.5)
        try save("livetv-guide", app: app, folder: folder)

        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons.matching(NSPredicate(format: "label == %@", "Fussball: Super League")).firstMatch,
                      in: app)
        Thread.sleep(forTimeInterval: 2.5)
        try save("livetv-guide-second-row", app: app, folder: folder)

        // Left from the channels opens the categories, as the sidebar did.
        let secondStation = app.buttons["live-tv-channel-channels-2"]
        for _ in 0..<4 where !containsFocus(secondStation) { XCUIRemote.shared.press(.left) }
        assertFocused(secondStation, in: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["live-tv-sidebar-category-all"], in: app)
        Thread.sleep(forTimeInterval: 0.6)
        try save("livetv-chips", app: app, folder: folder)

        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["live-tv-info-watch"], in: app)
        Thread.sleep(forTimeInterval: 0.6)
        try save("livetv-header", app: app, folder: folder)

        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["live-tv-sidebar-category-all"], in: app)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 0.6)
        try save("livetv-chip-focused", app: app, folder: folder)
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        try save("livetv-category-chosen", app: app, folder: folder)
        XCUIRemote.shared.press(.down)
        let guideFocused = NSPredicate { _, _ in
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.frame.minY > 600
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: guideFocused, object: nil)], timeout: 5
        ), .completed, app.debugDescription)
    }

    private func save(_ name: String, app: XCUIApplication, folder: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }

    private func assertFocused(
        _ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        let focused = NSPredicate { _, _ in self.containsFocus(element) }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5
        ), .completed, app.debugDescription, file: file, line: line)
    }

    private func containsFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
    }
}
