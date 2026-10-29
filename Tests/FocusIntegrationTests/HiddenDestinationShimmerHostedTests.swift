#if os(tvOS)
import SwiftUI
import XCTest
@testable import CoreUI

/// A loading placeholder inside a destination that is mounted but not shown
/// (an unselected native sidebar tab) must not run its sweep, and a visible one
/// must sweep without a RenderBox drawing layer: the earlier additive drawing
/// group was re-rendered through Metal on every frame, and a hidden tab's
/// Continue Watching skeleton kept ten of them running indefinitely at idle.
@MainActor
final class HiddenDestinationShimmerHostedTests: XCTestCase {
    func testVisiblePlaceholderShimmers() async throws {
        let window = try host(hidden: false)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(containsSweep(window.layer), "The visible placeholder keeps its loading sweep.")
        XCTAssertFalse(containsRenderBoxLayer(window.layer),
                       "The sweep must not be a RenderBox drawing re-rendered every frame.")
    }

    func testHiddenDestinationPlaceholderDoesNotShimmer() async throws {
        let window = try host(hidden: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(containsSweep(window.layer), "A hidden destination must not run the sweep.")
    }

    private func host(hidden: Bool) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray)
            .frame(width: 384, height: 216)
            .shimmering()
            .environment(\.plozzHiddenDestination, hidden)
            .environment(\.colorScheme, .dark))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func containsRenderBoxLayer(_ layer: CALayer) -> Bool {
        if NSStringFromClass(type(of: layer)).contains("RBDrawingLayer") { return true }
        return (layer.sublayers ?? []).contains { containsRenderBoxLayer($0) }
    }

    /// The band is the only gradient in the fixture.
    private func containsSweep(_ layer: CALayer) -> Bool {
        if NSStringFromClass(type(of: layer)).contains("GradientLayer") { return true }
        return (layer.sublayers ?? []).contains { containsSweep($0) }
    }
}
#endif
