import XCTest

/// Something a remote test can wait to see focused: a single element, or the
/// Home hero, whose focus is spread over its pills.
protocol RemoteFocusTarget {
    var exists: Bool { get }
    var hasFocus: Bool { get }
}

extension XCUIElement: RemoteFocusTarget {}

/// The Home hero as remote tests see it. Each action pill is its own focus item
/// (`home-hero-action-<kind>`), so "the hero has focus" means one pill does.
struct HomeHeroRemoteElement: RemoteFocusTarget {
    static let identifierPrefix = "home-hero-action-"

    let app: XCUIApplication

    var pills: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.identifierPrefix))
    }

    var focusedPill: XCUIElement {
        pills.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    var exists: Bool { pills.firstMatch.exists }
    var hasFocus: Bool { focusedPill.exists }
    var frame: CGRect { pills.firstMatch.frame }

    /// The focused pill's kind ("play", "watchlist", "moreInfo"…), or `nil`.
    var focusedKind: String? {
        let pill = focusedPill
        guard pill.exists else { return nil }
        return String(pill.identifier.dropFirst(Self.identifierPrefix.count))
    }

    /// "<slide title>, <action>": the slide's title is each pill's value.
    var label: String {
        let pill = focusedPill.exists ? focusedPill : pills.firstMatch
        return "\(pill.value as? String ?? ""), \(pill.label)"
    }

    /// The slide in front, read from the pills' shared value.
    var slideTitle: String { pills.firstMatch.value as? String ?? "" }

    func waitForExistence(timeout: TimeInterval) -> Bool {
        pills.firstMatch.waitForExistence(timeout: timeout)
    }

    static func isPillIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }
}

extension XCUIApplication {
    var homeHero: HomeHeroRemoteElement { HomeHeroRemoteElement(app: self) }
}
