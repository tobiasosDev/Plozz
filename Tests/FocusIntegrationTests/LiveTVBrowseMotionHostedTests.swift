import Observation
import SwiftUI
import UIKit
import XCTest
import FeatureLiveTVCore
@testable import AppShell
@testable import FeatureLiveTV
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class LiveTVBrowseMotionHostedTests: XCTestCase {
    func testCategoryFastScrollKeepsVisibleRowsFocusableAfterEntry() async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<30 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let initial = try XCTUnwrap(system.focusedItem)
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        let initialFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: initial, relativeTo: scroll))
        XCTAssertTrue(scroll.bounds.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)))
        XCTAssertLessThan(initialFrame.minY - scroll.bounds.minY, PrototypeLayout.controlHeight)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 3)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "The initial category entry must complete before the scrolling reproduction.")

        for fraction in [0.7, 0.9, 0.45] {
            scroll.setContentOffset(
                CGPoint(x: 0, y: (scroll.contentSize.height - scroll.bounds.height) * fraction),
                animated: false
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        let visible = visibleCategoryFocusItems(in: window, scroll: scroll)
        XCTAssertGreaterThan(visible.count, 2, "Fast scrolling must not disable the newly visible categories.")
        let target = try XCTUnwrap(visible.first)
        host.target = target
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === target, "A visible category must still accept real native focus.")
    }

    func testCategoryEntryRestoresSelectionAfterFocusLeavesThePane() async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        state.allowsExternalFocus = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<30 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        let initial = try XCTUnwrap(system.focusedItem)
        let initialFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: initial, relativeTo: scroll))
        XCTAssertTrue(scroll.bounds.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)))
        XCTAssertLessThan(initialFrame.minY - scroll.bounds.minY, PrototypeLayout.controlHeight)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "The initial category entry must complete before moving focus away.")
        let otherPane = try XCTUnwrap(categoryFocusItems(in: window).first {
            (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.minX ?? 0) > 500
        })
        host.target = otherPane
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === otherPane)
        let category = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first)
        let targetFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: category, relativeTo: scroll))
        XCTAssertEqual(targetFrame.minY, initialFrame.minY, accuracy: 1,
                       "A real departure must retain selected-category entry rather than preferring Search.")
        host.target = category
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === category)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "Returning to the selected category must release the entry gate again.")

        host.target = nil
        let next = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first {
            (NavigationRowFocusRequester.frame(of: $0, relativeTo: scroll)?.minY ?? 0) > initialFrame.maxY
        })
        host.target = next
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.target = nil
        state.request += 1
        try await Task.sleep(for: .milliseconds(250))
        let restored = try XCTUnwrap(system.focusedItem)
        let restoredFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: restored, relativeTo: scroll))
        XCTAssertEqual(restoredFrame.minY, initialFrame.minY, accuracy: 1,
                       "A new explicit entry request must still restore the selected category.")
    }

    private func categoryScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.categoryScrollView(in: $0) }.first
    }

    private func categoryFocusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
    }

    private func visibleCategoryFocusItems(in window: UIWindow, scroll: UIScrollView) -> [any UIFocusItem] {
        categoryFocusItems(in: window).filter { item in
            guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: scroll) else { return false }
            return scroll.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                && frame.width > 300 && frame.height > 30
        }
    }

    @MainActor @Observable final class CategoryFocusFixtureState {
        var active = false
        var request = 1
        var allowsExternalFocus = false
        let model = LiveTVPrototypeModel(channels: (0..<80).map {
            LiveTVPrototypeChannel(
                id: "category-\($0)", number: $0, name: "Channel \($0)",
                category: String(format: "Category %02d", $0), symbol: "tv", accent: 0,
                source: .iptv, tagline: ""
            )
        })
    }

    private struct CategoryFocusPage: View {
        @Bindable var state: CategoryFocusFixtureState

        var body: some View {
            HStack(alignment: .top, spacing: 80) {
                PrototypeBrowseSidebar(
                    model: state.model, active: $state.active, focusRequest: 0,
                    categoryFocusRequest: state.request, restoresCategoryFocus: true,
                    search: {}, enterGuide: {}
                )
                .frame(width: 384, height: 900)
                Button("Guide") {}
                    .frame(width: 300, height: 100)
                    .disabled(!state.allowsExternalFocus)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(60)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        }
    }

    private final class CategoryFocusHost: UIHostingController<CategoryFocusPage> {
        weak var target: (any UIFocusEnvironment)?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    func testDisappearanceStopsPlaybackUnlessActiveFullscreenOwnsIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var stops = 0
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        fixture.window.rootViewController = host

        for (active, fullscreen) in [
            (true, true), (true, false), (false, true), (false, false)
        ] {
            host.rootView = AnyView(Color.black.modifier(LiveChannelPlayerView.LiveChannelActivityObserver(
                isActive: active, isAuthorized: true, scenePhase: .active, networkBlock: nil,
                currentModel: { nil }, fullscreenOwnsSurface: { fullscreen },
                updateSource: {}, stopPlayback: { stops += 1 }
            )))
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let before = stops
            host.rootView = AnyView(EmptyView())
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(stops - before, active && fullscreen ? 0 : 1)
        }
    }

    private func makeFixture(disablesAnimations: Bool = false, realSidebar: Bool = false) async throws -> Fixture {
        let scene = try await foregroundScene()
        let fixture = Fixture(scene: scene, disablesAnimations: disablesAnimations, realSidebar: realSidebar)
        var prepared = false
        defer { if !prepared { fixture.close() } }
        let displayDeadline = ContinuousClock.now + .seconds(2)
        while fixture.renderedGuideX(afterScreenUpdates: true) == nil, ContinuousClock.now < displayDeadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
        }
        _ = try fixture.guideX()
        prepared = true
        return fixture
    }

    private func foregroundScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, disablesAnimations: Bool, realSidebar: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model, realSidebar: realSidebar)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .transaction { $0.disablesAnimations = disablesAnimations })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func sidebarImage() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 384, height: 360), format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
            }
        }

        func guideX() throws -> CGFloat {
            try XCTUnwrap(renderedGuideX(), "The guide must be present in the rendered frame")
        }

        func renderedGuideX(afterScreenUpdates: Bool = false) -> CGFloat? {
            guard let view = model.guide, !view.bounds.isEmpty else { return nil }
            let row = view.convert(view.bounds, to: window).midY
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            var drawn = false
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: window.bounds.width, height: 1), format: format
            ).image { context in
                context.cgContext.translateBy(x: 0, y: -row)
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates)
            }
            guard drawn, let pixels = image.cgImage else { return nil }
            var rgba = [UInt8](repeating: 0, count: pixels.width * 4)
            guard let context = CGContext(
                data: &rgba, width: pixels.width, height: 1, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: 1))
            let leading = (0..<pixels.width).first { x in
                rgba[x * 4 + 1] > 180 && rgba[x * 4] < 50 && rgba[x * 4 + 2] < 50
            }
            return leading.map(CGFloat.init)
        }

        func sample(duration: Duration = .milliseconds(450)) async throws -> [CGFloat] {
            let deadline = ContinuousClock.now + duration
            var samples: [CGFloat] = []
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                samples.append(try guideX())
                try await Task.sleep(for: .milliseconds(16))
            }
            return samples
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @Observable final class Model {
        var collapsed = true
        var sidebarActive = false
        let sidebar = LiveTVPrototypeModel(now: Date(), scenario: .noGuide, channels: [])
        @ObservationIgnored weak var guide: UIView?
    }

    private struct Page: View {
        let model: Model
        let realSidebar: Bool

        var body: some View {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080), hidesSidebar: model.collapsed
            )
            PrototypeBrowseLayout(layout: layout) {
                Color.blue.frame(height: layout.heroHeight)
            } sidebar: {
                if realSidebar {
                    PrototypeBrowseSidebar(
                        model: model.sidebar,
                        active: Binding(get: { model.sidebarActive }, set: { model.sidebarActive = $0 }),
                        focusRequest: 0, search: {}, enterGuide: {}, multiviews: {}
                    )
                    .disabled(true)
                } else {
                    Color.red
                }
            } guide: {
                GuideMarker(model: model)
            }
            .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }

    private struct GuideMarker: UIViewRepresentable {
        let model: Model

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .green
            model.guide = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

}
