import XCTest

/// Remote navigation through the Home hero's action pills: Left/Right move between
/// pills natively, a move past either end pages the carousel, and focus stays on
/// the pill it was on.
@MainActor
final class HomeHeroPagingRemoteTests: XCTestCase {
    func testRightFromLastActionPagesAndKeepsFocusOnIt() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = launch(["--production-home-fixture"])
        defer { app.terminate() }
        let hero = app.homeHero
        XCTAssertTrue(wait { hero.hasFocus }, "Home starts on the hero. \(focusedDescription(app))")
        XCTAssertEqual(hero.focusedKind, "play")
        XCTAssertFalse(app.buttons["home-hero-action-next"].exists, "The paging chevron is gone.")

        let firstSlide = hero.slideTitle
        let pillCount = hero.pills.count
        XCTAssertGreaterThanOrEqual(pillCount, 2, app.debugDescription)
        for step in 1..<pillCount {
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(wait { hero.pills.element(boundBy: step).hasFocus }, "Right moves to pill \(step).")
            XCTAssertEqual(hero.slideTitle, firstSlide, "Moving between pills never pages.")
        }
        let lastKind = try XCTUnwrap(hero.focusedKind)

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(wait { hero.slideTitle != firstSlide }, "Right past the last pill pages.")
        let secondSlide = hero.slideTitle
        XCTAssertTrue(hero.hasFocus, "Paging keeps focus in the hero.")
        let lastIndex = hero.pills.count - 1
        XCTAssertTrue(hero.pills.element(boundBy: lastIndex).hasFocus, "Focus stays on the last pill.")
        if hero.pills.count == pillCount { XCTAssertEqual(hero.focusedKind, lastKind) }
        capture("hero after right past last pill", app)

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(wait { hero.slideTitle != secondSlide }, "Each further Right is one more page.")

        // Back to the first pill of this slide, then one more Left pages back.
        let thirdSlide = hero.slideTitle
        for _ in 0..<(hero.pills.count - 1) {
            XCUIRemote.shared.press(.left)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(wait { hero.pills.firstMatch.hasFocus }, "Left walks back to the first pill.")
        XCTAssertEqual(hero.slideTitle, thirdSlide)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(wait { hero.slideTitle == secondSlide }, "Left past the first pill pages back.")
        XCTAssertTrue(hero.pills.firstMatch.hasFocus, "Focus stays on the first pill.")

        // Down leaves the hero; Up comes back to the pill that was focused.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(wait { !hero.hasFocus }, "Down leaves the hero.")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(wait { hero.hasFocus }, "Up returns to the hero.")
        XCTAssertTrue(hero.pills.firstMatch.hasFocus, "Up lands on the pill focused before Down.")
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    func testLeftOnFirstSlideOpensTheNativeSidebar() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = launch(["--production-home-fixture", "--native-sidebar-home"])
        defer { app.terminate() }
        let hero = app.homeHero
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        if !wait({ hero.hasFocus }, timeout: 3) { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(wait { hero.hasFocus }, app.debugDescription)
        let firstSlide = hero.slideTitle
        XCTAssertTrue(hero.pills.firstMatch.hasFocus)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(wait { !hero.hasFocus }, "Left on the first pill of the first slide leaves for the sidebar.")
        XCTAssertEqual(hero.slideTitle, firstSlide, "Opening the sidebar does not page.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(wait { hero.hasFocus }, "Right comes back into the hero.")

        // On a later slide the same Left pages back instead.
        for _ in 0..<hero.pills.count { XCUIRemote.shared.press(.right); Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertTrue(wait { hero.slideTitle != firstSlide })
        for _ in 0..<hero.pills.count { XCUIRemote.shared.press(.left); Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertTrue(wait { hero.slideTitle == firstSlide }, "Left past the first pill pages back. \(focusedDescription(app))")
        XCTAssertTrue(hero.hasFocus, "Paging back keeps focus in the hero.")
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    /// Profiling workload: page the hero with the remote, then move to Continue
    /// Watching and back. Presses only, no assertions on pill structure, so the
    /// same sequence runs against any hero implementation.
    func testProfileHeroPaging() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let attach = ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_ATTACH"] == "1"
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        if !attach {
            app.launchArguments = ["--production-home-fixture"]
            app.launch()
        }
        defer { if !attach { app.terminate() } }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.homeHero
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let shell = ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_HOME_SHELL"]
        if let entry: XCUIRemote.Button = shell == "top-bar" ? .down : shell == "sidebar" ? .right : nil {
            Thread.sleep(forTimeInterval: 2)
            if !hero.hasFocus { XCUIRemote.shared.press(entry) }
        }
        XCTAssertTrue(wait { hero.hasFocus })
        print("HERO_PAGING_READY \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 4)
        for cycle in 0..<3 {
            print("HERO_PAGING_CYCLE \(cycle) \(Date().timeIntervalSince1970)")
            for _ in 0..<10 {
                XCUIRemote.shared.press(.right)
                Thread.sleep(forTimeInterval: 0.6)
            }
            for _ in 0..<6 {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: 0.6)
            }
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1.2)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 1.2)
            XCTAssertTrue(hero.hasFocus)
        }
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = arguments
        app.launchEnvironment["PLZHFOCUS"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.homeHero.waitForExistence(timeout: 20))
        return app
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )], timeout: timeout) == .completed
    }

    private func focusedDescription(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? "Focused: \(focused.debugDescription)" : "Nothing focused."
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
