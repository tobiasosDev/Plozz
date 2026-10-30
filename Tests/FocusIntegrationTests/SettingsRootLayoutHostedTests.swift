import CoreModels
import CoreUI
@testable import FeatureSettings
import SwiftUI
import UIKit
import XCTest

/// The split Settings root keeps both halves inside the side margins: the
/// preview on the leading side, the list column ending at the trailing margin.
@MainActor
final class SettingsRootLayoutHostedTests: XCTestCase {
    func testPreviewAndListStayInsideTheSideMargins() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for style in [NavigationStyle.tabBar, .sidebar] {
                let frames = RootFrames()
                let navigation = SettingsNavigationModel()
                window.rootViewController = UIHostingController(rootView:
                    SettingsWorkspace(navigation: navigation) {
                        SettingsRootLayout {
                            ScrollView {
                                Button("Playback") {}
                                    .frame(maxWidth: .infinity)
                                    .background { RootFrameProbe(id: "row", frames: frames) }
                                Color.red.frame(height: 2000)
                            }
                            .scrollClipDisabled()
                            .background { RootFrameProbe(id: "list", frames: frames) }
                        } preview: {
                            Color.blue.frame(width: 400, height: 400)
                                .background { RootFrameProbe(id: "preview", frames: frames) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background { RootFrameProbe(id: "previewArea", frames: frames) }
                        }
                        .background { RootFrameProbe(id: "root", frames: frames) }
                    } detail: { _ in
                        EmptyView()
                    }
                    // Like production: the page reaches the window's 80pt
                    // title-safe edges, so the list column touches them.
                    .environment(\.layoutDirection, direction)
                    .environment(\.plozzNavigationStyle, style)
                )
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                let report = XCTAttachment(string: "\(style) \(direction) \(frames.values)")
                report.name = "root-frames-\(style)-\(direction)"
                report.lifetime = .keepAlways
                add(report)
                let list = try XCTUnwrap(frames.values["row"], "\(style) \(direction)")
                let preview = try XCTUnwrap(frames.values["preview"], "\(style) \(direction)")
                let column = SettingsRootMetrics.listWidth - SettingsRowCardMetrics.focusOutset
                XCTAssertEqual(list.width, column, accuracy: 1, "\(style) \(direction)")
                let (trailingEdge, previewCenter): (CGFloat, CGFloat) = direction == .leftToRight
                    ? (list.maxX, preview.midX) : (window.bounds.width - list.minX, window.bounds.width - preview.midX)
                // The focused card's outset fills the gap up to the side margin.
                XCTAssertEqual(trailingEdge + SettingsRowCardMetrics.focusOutset, window.bounds.width - 80, accuracy: 1,
                               "The list must end at the side margin (\(style) \(direction)): \(list)")
                // Where the list's content is actually drawn, not only laid out.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let shot = XCTAttachment(image: image)
                shot.name = "root-layout-\(style)-\(direction)"
                shot.lifetime = .keepAlways
                add(shot)
                let drawn = try redColumns(in: XCTUnwrap(image.cgImage), row: 600)
                XCTAssertEqual(drawn.lowerBound, Int(list.minX), accuracy: 2, "Drawn \(drawn), laid out \(list)")
                XCTAssertEqual(drawn.upperBound, Int(list.maxX) - 1, accuracy: 2, "Drawn \(drawn), laid out \(list)")
                // Centred in the space left of the list, less the trailing inset.
                let previewSpace = window.bounds.width - 160 - SettingsRootMetrics.listWidth
                XCTAssertEqual(previewCenter, 80 + (previewSpace - SettingsRootMetrics.previewTrailingInset) / 2,
                               accuracy: 1, "\(style) \(direction): \(preview)")
            }
        }
    }
}

/// The first and last columns of the red list content on one pixel row.
private func redColumns(in image: CGImage, row: Int) throws -> ClosedRange<Int> {
    let width = image.width
    var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
    let context = try XCTUnwrap(CGContext(
        data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
    let columns = (0..<width).filter { x in
        let index = (row * width + x) * 4
        return pixels[index] > 200 && pixels[index + 1] < 80 && pixels[index + 2] < 80
    }
    return try XCTUnwrap(columns.first) ... XCTUnwrap(columns.last)
}

@MainActor
private final class RootFrames {
    var values: [String: CGRect] = [:]
}

private struct RootFrameProbe: View {
    let id: String
    let frames: RootFrames

    var body: some View {
        Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            frames.values[id] = frame
        }
    }
}
