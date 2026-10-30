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
        let window = try await host(hidden: false)
        defer { window.isHidden = true; window.rootViewController = nil }
        let samples = try await brightnessDuringFirstPass(window)
        XCTAssertGreaterThan(samples.max()! - samples.min()!, 20,
                             "The visible placeholder keeps its loading sweep: \(samples)")
        XCTAssertFalse(containsRenderBoxLayer(window.layer),
                       "The sweep must not be a RenderBox drawing re-rendered every frame.")
    }

    func testHiddenDestinationPlaceholderDoesNotShimmer() async throws {
        let window = try await host(hidden: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        let samples = try await brightnessDuringFirstPass(window)
        XCTAssertLessThanOrEqual(samples.max()! - samples.min()!, 2,
                                 "A hidden destination must not run the sweep: \(samples)")
    }

    /// In light mode the band is strong enough to measure on a mid-grey card.
    private func host(hidden: Bool) async throws -> UIWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: Rectangle()
            .fill(Color(white: 0.5))
            .frame(width: 960, height: 540)
            .shimmering()
            .environment(\.plozzHiddenDestination, hidden)
            .environment(\.colorScheme, .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// The brightest red value along the card's middle row, every 100 ms across
    /// most of the 2.3 s first pass (the band starts and ends off the card).
    private func brightnessDuringFirstPass(_ window: UIWindow) async throws -> [Int] {
        var samples: [Int] = []
        for _ in 0..<22 {
            try await Task.sleep(for: .milliseconds(100))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let row = cgImage.height / 2
            let reds = stride(from: 500, to: 1420, by: 20).map { Int(pixels[(row * cgImage.width + $0) * 4]) }
            samples.append(try XCTUnwrap(reds.max()))
        }
        return samples
    }

    private func containsRenderBoxLayer(_ layer: CALayer) -> Bool {
        if NSStringFromClass(type(of: layer)).contains("RBDrawingLayer") { return true }
        return (layer.sublayers ?? []).contains { containsRenderBoxLayer($0) }
    }
}
#endif
