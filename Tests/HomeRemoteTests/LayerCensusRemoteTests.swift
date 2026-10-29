import XCTest
#if canImport(notify)
import notify
#endif

/// Asks the production Home fixture for `LayerCensus` snapshots at rest on the
/// hero, in the first rows, deeper in the rows and on an opened detail page,
/// inside the navigation shell named by `PLOZZ_PERFORMANCE_HOME_SHELL`
/// (`none`, `top-bar`, `sidebar` or `rail`). It records structure, not timing,
/// so it runs separately from the sampled navigation profile.
@MainActor
final class LayerCensusRemoteTests: XCTestCase {
    func testCaptureProductionHomeLayerCensus() throws {
        #if targetEnvironment(simulator) && canImport(notify)
        continueAfterFailure = false
        let shell = ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_HOME_SHELL"] ?? "none"
        let shellArguments = [
            "top-bar": ["--top-bar-home"], "sidebar": ["--native-sidebar-home"], "rail": ["--pinned-home"],
        ][shell] ?? []
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--home-performance-fixture", "--distinct-home-artwork",
            "--home-artwork-cache-namespace=layer-census",
        ] + shellArguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        if let entry: XCUIRemote.Button = shell == "top-bar" ? .down : shell == "sidebar" ? .right : nil {
            Thread.sleep(forTimeInterval: 2)
            if !hero.hasFocus { XCUIRemote.shared.press(entry) }
        }
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(hero.hasFocus)
        census("hero")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 3)
        census("rows")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 1)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 3)
        census("rows-deep")
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 5)
        census("detail")
        #else
        throw XCTSkip("This uses an isolated simulator with local fixture data.")
        #endif
    }

    private func census(_ label: String) {
        #if canImport(notify)
        notify_post("com.thatcube.Plozz.FocusHost.LayerCensus." + label)
        #endif
        Thread.sleep(forTimeInterval: 2)
    }
}
