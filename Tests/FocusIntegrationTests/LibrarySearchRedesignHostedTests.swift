#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import FeatureHomeCore
import FeatureSearch
import SwiftUI
import UIKit
import Vision
import XCTest

/// Renders Library Browse and Search the way the TV app lays them out — a
/// centred mode control on the sidebar row, query pills, a seven-column grid,
/// and search results in rows captioned with their server — and keeps the
/// screenshots as attachments for visual review.
@MainActor
final class LibrarySearchRedesignHostedTests: XCTestCase {
    private static let titles: [(String, Int, Double?)] = [
        ("Sintel", 2010, 0.4), ("Tears of Steel", 2012, nil), ("Cosmos Laundromat", 2015, 0.25),
        ("Spring", 2019, nil), ("Sprite Fright", 2021, nil), ("Big Buck Bunny", 2008, nil),
        ("Elephants Dream", 2006, nil), ("Hero", 2018, 0.7), ("Coffee Run", 2020, nil),
        ("Metropolis", 1927, nil), ("Das Cabinet des Dr. Caligari", 1920, nil), ("The General", 1926, nil),
        ("Sherlock Jr.", 1924, nil), ("Caminandes: Llamigos", 2016, nil)
    ]

    func testLibraryBrowseCentresModesBesideTheSidebarAndFillsSevenColumns() async throws {
        let posters = try cachePosters()
        defer { posters.forEach(removeCachedPoster) }
        let provider = RedesignLibraryProvider(items: Self.items(posters: posters))
        let name = "LibraryRedesign.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults
        )
        await model.loadRecommendationsIfNeeded()
        await model.setContentMode(.titles)
        // Loaded content takes entry focus, so the sidebar collapses to its page button.
        await model.loadFirstPage()
        try await withWindow(SidebarFixture(tabTitle: "Movies", systemImage: "film") {
            LibraryBrowseView(viewModel: model, title: Text(verbatim: "Movies"), isNavigationRoot: true) { _ in }
        }) { window, root in
            let collection = try await self.waitForView(UICollectionView.self, in: window) {
                $0.visibleCells.count >= 10
            }
            try await Task.sleep(for: .milliseconds(1200))
            let cells = collection.visibleCells.compactMap { $0 as? NativeTVLibraryCell }
                .sorted { (collection.indexPath(for: $0)?.item ?? 0) < (collection.indexPath(for: $1)?.item ?? 0) }
            let firstRows = Array(cells.prefix(8))
            XCTAssertEqual(firstRows.count, 8)
            let rows = firstRows.map { $0.convert($0.bounds, to: window).minY.rounded() }
            XCTAssertEqual(Set(rows.prefix(7)).count, 1, "Seven posters share the first row.")
            XCTAssertGreaterThan(try XCTUnwrap(rows.last), try XCTUnwrap(rows.first), "The eighth starts row two.")
            // Focus a poster, as the concept does; the selected mode turns white.
            try await self.focus(cells[9], root: root, in: window)
            let image = self.capture(window, name: "06-library-browse")
            let text = try self.recognizedText(in: image)
            XCTAssertTrue(text.contains { $0.string.hasSuffix("Filter") }, "\(text.map(\.string))")
            XCTAssertTrue(text.contains { $0.string.contains("Sort") && $0.string.contains("Name") },
                          "\(text.map(\.string))")
            let browse = try XCTUnwrap(text.first { $0.string == "Browse" })
            let sintel = try XCTUnwrap(text.first { $0.string == "Sintel" })
            let firstCell = try XCTUnwrap(cells.first).convert(try XCTUnwrap(cells.first).bounds, to: window)
            XCTAssertLessThan(sintel.frame.minX - firstCell.minX, 24, "Captions start at the poster's leading edge.")
            XCTAssertLessThan(browse.frame.maxY, 140, "The modes share the sidebar page button's row.")
        }
    }

    func testSearchShowsRowsPerKindWithServerCaptions() async throws {
        let posters = try cachePosters()
        defer { posters.forEach(removeCachedPoster) }
        let provider = RedesignLibraryProvider(items: Self.items(posters: posters))
        let account = ResolvedAccount(account: Account(id: "fixture", from: provider.session), provider: provider)
        let model = SearchViewModel(accounts: [account], debounceMilliseconds: 0)
        model.query = "s"
        try await withWindow(SidebarFixture(tabTitle: "Search", systemImage: "magnifyingglass") {
            SearchView(viewModel: model) { _ in }
        }.environment(\.plozzMediaSourceIdentities, [
            "fixture": MediaSourceIdentity(provider: .jellyfin, serverName: "Jellyfin")
        ])) { window, root in
            let deadline = ContinuousClock.now + .seconds(10)
            while model.state.value == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let sections = try XCTUnwrap(model.state.value)
            XCTAssertEqual(sections.map(\.kind), [.movies, .tvShows, .episodes])
            XCTAssertEqual(Array(model.suggestions.prefix(2)), ["sintel", "tears of steel"])
            // The app's SearchPageFocusObserver hands entry focus to the keyboard.
            let search = try XCTUnwrap(self.searchController(in: root))
            try await self.focus(search, root: root, in: window)
            let image = self.capture(window, name: "07-search-results")
            let text = try self.recognizedText(in: image)
            let strings = text.map(\.string)
            XCTAssertTrue(strings.contains("Movies"), "\(strings)")
            XCTAssertTrue(strings.contains("TV Shows"), "\(strings)")
            XCTAssertTrue(strings.contains { $0.contains("2010") && $0.contains("Jellyfin") }, "\(strings)")
            XCTAssertTrue(strings.contains("sintel"), "Title completions show as chips: \(strings)")
            let sintel = try XCTUnwrap(text.first { $0.string == "Sintel" })
            let tears = try XCTUnwrap(text.first { $0.string == "Tears of Steel" })
            XCTAssertEqual(sintel.frame.midY, tears.frame.midY, accuracy: 8, "Movies read along one row.")
            let poster = try XCTUnwrap(self.focusables(in: window).first {
                $0.convert($0.bounds, to: window).minY > sintel.frame.minY - 420
                    && $0.convert($0.bounds, to: window).maxY < sintel.frame.minY
            })
            try await self.focus(poster, root: root, in: window)
            self.capture(window, name: "07-search-results-focused")
        }
    }

    // MARK: Fixture

    private static func items(posters: [URL]) -> [MediaItem] {
        var items = titles.enumerated().map { index, entry in
            let runtime = 3600 + Double(index) * 300
            return MediaItem(
                id: "movie-\(index)", title: entry.0, kind: .movie, productionYear: entry.1,
                runtime: runtime, resumePosition: entry.2.map { runtime * $0 }, playedPercentage: entry.2,
                posterURL: posters[index % posters.count]
            )
        }
        items.append(MediaItem(id: "show", title: "Spring Stories", kind: .series, productionYear: 2022,
                               posterURL: posters[3]))
        items.append(MediaItem(id: "episode", title: "Seeds", kind: .episode, parentTitle: "Spring Stories",
                               seasonNumber: 1, episodeNumber: 1, productionYear: 2022, posterURL: posters[4]))
        return items
    }

    private func cachePosters() throws -> [URL] {
        let palette: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemGreen, .systemPink, .systemBrown]
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        return try palette.enumerated().map { index, color in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
                let colors = [color.cgColor, UIColor.black.cgColor] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
                context.cgContext.drawLinearGradient(
                    try! XCTUnwrap(gradient), start: .zero, end: CGPoint(x: 0, y: 600), options: []
                )
            }
            let url = try XCTUnwrap(URL(string: "https://redesign-poster.example.test/\(UUID())-\(index).png"))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: URLRequest(url: url)
            )
            return url
        }
    }

    private func removeCachedPoster(_ url: URL) {
        ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
    }

    private func withWindow<Content: View>(
        _ content: Content, body: (UIWindow, FocusRoot) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = FocusRoot()
        let host = UIHostingController(rootView: AnyView(content
            .environment(\.plozzNavigationStyle, .sidebar)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.plozzCardStyle, .borderless)
            .background(Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1A / 255).ignoresSafeArea())
            .preferredColorScheme(.dark)))
        root.addChild(host)
        root.view.addSubview(host.view)
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: root)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await body(window, root)
    }

    /// Best effort: these are screenshots, and the system sidebar may keep focus.
    private func focus(_ target: any UIFocusEnvironment, root: FocusRoot, in window: UIWindow) async throws {
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        root.target = target
        system.requestFocusUpdate(to: root)
        system.updateFocusIfNeeded()
        root.target = nil
        try await Task.sleep(for: .milliseconds(1200))
        print("REDESIGN_FOCUS target=\(type(of: target)) focused=\(String(describing: system.focusedItem))")
    }

    private func searchController(in controller: UIViewController) -> UISearchController? {
        if let search = controller as? UISearchController { return search }
        if let search = controller.presentedViewController.flatMap(searchController(in:)) { return search }
        return controller.children.lazy.compactMap { self.searchController(in: $0) }.first
    }

    private func focusables(in view: UIView) -> [UIView] {
        (view.canBecomeFocused ? [view] : []) + view.subviews.flatMap { focusables(in: $0) }
    }

    private func waitForView<V: UIView>(
        _ type: V.Type, in window: UIWindow, until ready: (V) -> Bool
    ) async throws -> V {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let view = find(type, in: window), ready(view) { return view }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(find(type, in: window), "\(type) never became ready")
    }

    private func find<V: UIView>(_ type: V.Type, in view: UIView) -> V? {
        if let match = view as? V { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func capture(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Opt in with TEST_RUNNER_PLOZZ_REDESIGN_SHOTS=<directory> to also write PNGs.
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_REDESIGN_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return image
    }

    private struct Recognized {
        let string: String
        let frame: CGRect
    }

    private func recognizedText(in image: UIImage) throws -> [Recognized] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let string = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Recognized(string: string, frame: CGRect(
                x: box.minX * image.size.width, y: (1 - box.maxY) * image.size.height,
                width: box.width * image.size.width, height: box.height * image.size.height
            ))
        }
    }
}

private final class FocusRoot: UIViewController {
    weak var target: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

/// A one-tab sidebar so the system page button ("‹ Movies") is on screen.
private struct SidebarFixture<Content: View>: View {
    let tabTitle: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        TabView(selection: .constant(0)) {
            Tab(tabTitle, systemImage: systemImage, value: 0) {
                NavigationStack { content() }
            }
            Tab("Home", systemImage: "house", value: 1) { Color.clear }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private actor RedesignLibraryProvider: MediaLibraryQueryProviding, CapabilityReporting {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let capabilities: ProviderCapability = [.libraryCollections, .videoPlaylists]
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "fixture", name: "Jellyfin", baseURL: URL(string: "https://fixture.test")!, provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    private let catalog: [MediaItem]

    init(items: [MediaItem]) { catalog = items }

    nonisolated func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        SortField.legacyFields
    }
    nonisolated func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        .init(filters: [.all, .unwatched], nativeFilters: [.all, .unwatched],
              supportsGenres: true, supportsYears: true, nativeFacets: true)
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets { .init() }
    func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await items(in: containerID, kind: kind, page: page)
    }
    func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func libraryQueryLetterIndex(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws
        -> [LibraryLetterIndexEntry] { [] }
    func libraryQueryLetterPosition(
        in containerID: String, kind: MediaItemKind, letter: String, page: PageRequest
    ) async throws -> Int? { nil }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let movies = catalog.filter { $0.kind == .movie }
        let wall = (0..<42).map { index in
            var item = movies[index % movies.count]
            if index >= movies.count { item = item.withID("\(item.id)-\(index)") }
            return item
        }
        let end = min(wall.count, page.startIndex + page.limit)
        return MediaPage(items: Array(wall[min(page.startIndex, end)..<end]), startIndex: page.startIndex,
                         totalCount: wall.count)
    }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        [LibrarySection(id: "featured", title: "Featured", items: Array(catalog.prefix(4)))]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        catalog.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private extension MediaItem {
    func withID(_ id: String) -> MediaItem {
        MediaItem(
            id: id, title: title, kind: kind, productionYear: productionYear, runtime: runtime,
            resumePosition: resumePosition, playedPercentage: playedPercentage, posterURL: posterURL
        )
    }
}
#endif
