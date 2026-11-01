import CoreModels
@testable import FeatureTonightCore
import XCTest

@MainActor
final class TonightScreenModelTests: XCTestCase {
    private actor Watchlist: TonightWatchlistWriting {
        var added: [String] = []
        var removed: [String] = []
        func add(_ film: TonightFilm) async throws -> Bool { added.append(film.key); return true }
        func remove(_ film: TonightFilm) async throws { removed.append(film.key) }
    }

    private final class Loader: @unchecked Sendable {
        var snapshot: TonightLibrarySnapshot
        var calls = 0
        init(_ snapshot: TonightLibrarySnapshot) { self.snapshot = snapshot }
    }

    private func makeModel(
        store: TonightMemoryStore = TonightMemoryStore(),
        loader: Loader = Loader(TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now)),
        watchlist: Watchlist? = nil
    ) -> TonightModel {
        TonightModel(
            engine: TonightEngine(),
            store: store,
            loadLibrary: { loader.calls += 1; return loader.snapshot },
            watchlist: watchlist,
            resolveItem: { location in MediaItem(id: location.itemID, title: location.itemID, kind: .movie) },
            now: { TonightFixtures.now }
        )
    }

    func testStartReadsTheLibraryOnceAndShowsPicks() async {
        let loader = Loader(TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now))
        let model = makeModel(loader: loader)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.picks.count, 6)
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(model.libraryStats?.seen, 8)
        XCTAssertTrue(model.references.contains { $0.title == "Heat" })
        XCTAssertFalse(model.references.contains { $0.title == "Grown Ups 2" })
    }

    func testAFreshCacheOpensWithoutRescanningAndAStaleOneRefreshes() async {
        let store = TonightMemoryStore(library: TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now))
        let loader = Loader(TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now))
        let model = makeModel(store: store, loader: loader)
        await model.start()
        XCTAssertEqual(loader.calls, 0)

        let staleStore = TonightMemoryStore(library: TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.daysAgo(2)))
        let staleLoader = Loader(TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now))
        let stale = makeModel(store: staleStore, loader: staleLoader)
        await stale.start()
        XCTAssertEqual(staleLoader.calls, 1)
    }

    func testAFailedEmptyScanDoesNotReplaceAGoodLibrary() async {
        let loader = Loader(TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now))
        let model = makeModel(loader: loader)
        await model.start()
        loader.snapshot = TonightLibrarySnapshot(films: [], builtAt: TonightFixtures.now, failedAccountIDs: ["plex"])
        await model.refreshLibrary()
        XCTAssertEqual(model.libraryStats?.films, TonightFixtures.library.count)
        XCTAssertFalse(model.picks.isEmpty)
    }

    func testNeverRemovesThePickAndUndoBringsItBack() async throws {
        let model = makeModel()
        await model.start()
        let pick = try XCTUnwrap(model.picks.first)
        await model.decide(.never, on: pick)
        XCTAssertFalse(model.picks.contains { $0.film.key == pick.film.key })
        await model.undoLastDecision()
        XCTAssertTrue(model.picks.contains { $0.film.key == pick.film.key })
        XCTAssertNil(model.lastDecision)
    }

    func testSavingAFirstWatchAddsItToTheWatchlistOnceAndUndoRemovesOnlyThatEntry() async throws {
        let watchlist = Watchlist()
        let model = makeModel(watchlist: watchlist)
        await model.start()
        let pick = try XCTUnwrap(model.picks.first)
        await model.decide(.save, on: pick)
        await model.decide(.save, on: pick)
        let added = await watchlist.added
        XCTAssertEqual(added, [pick.film.key])
        XCTAssertTrue(model.picks.contains { $0.film.key == pick.film.key }, "Save keeps the film on screen")
        await model.undoLastDecision()
        let removed = await watchlist.removed
        XCTAssertEqual(removed, [pick.film.key])
    }

    func testDecisionsAndTheRequestAreSavedPerProfile() async throws {
        let store = TonightMemoryStore()
        let model = makeModel(store: store)
        await model.start()
        await model.setGenre(.scienceFiction)
        let pick = try XCTUnwrap(model.picks.first)
        XCTAssertTrue(pick.film.genres.contains(.scienceFiction))
        await model.decide(.later, on: pick)
        let saved = await store.load()
        XCTAssertEqual(saved.request.genre, .scienceFiction)
        XCTAssertGreaterThan(saved.memory.penalty(pick.film, now: TonightFixtures.now), 0)
    }

    func testShowMoreExcludesEverythingAlreadyShown() async {
        let model = makeModel()
        await model.start()
        let first = Set(model.picks.map(\.film.key))
        await model.showMore()
        XCTAssertTrue(Set(model.picks.map(\.film.key)).isDisjoint(with: first))
    }

    func testQuickRatingsLeaveTheQueueAndCountAsRated() async throws {
        let model = makeModel()
        await model.start()
        let before = model.quickStats
        let film = try XCTUnwrap(model.quickQueue.first)
        await model.rate(film, .good)
        XCTAssertEqual(model.quickStats.ratedCount, before.ratedCount + 1)
        XCTAssertFalse(model.quickQueue.contains { $0.key == film.key })
    }

    func testPlayableItemResolvesTheServerLocation() async throws {
        let model = makeModel()
        await model.start()
        let pick = try XCTUnwrap(model.picks.first { $0.film.isOnServer })
        let item = await model.playableItem(for: pick)
        XCTAssertEqual(item?.id, pick.film.locations.first?.itemID)
    }

    /// A curator that waits for the test to release it, then picks the last candidate.
    private actor GatedCurator: TonightReranker {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var calls = 0

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func rerank(request: TonightRequest, candidates: [TonightFilm], history: [TonightFilm], context: TonightRerankContext) async -> TonightRerankResult {
            calls += 1
            if !released { await withCheckedContinuation { waiters.append($0) } }
            return TonightRerankResult(picks: [.init(key: candidates.last!.key, reason: "Claude says so.")])
        }
    }

    private func curatedModel(_ curator: GatedCurator) -> TonightModel {
        TonightModel(
            engine: TonightEngine(reranker: curator),
            store: TonightMemoryStore(),
            loadLibrary: { TonightLibrarySnapshot(films: TonightFixtures.library, builtAt: TonightFixtures.now) },
            resolveItem: { _ in nil },
            now: { TonightFixtures.now }
        )
    }

    func testRulePicksShowFirstAndTheCuratedPassReplacesThem() async throws {
        let curator = GatedCurator()
        let model = curatedModel(curator)
        let start = Task { await model.start() }
        for _ in 0..<200 where !model.isCurating { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isCurating)
        XCTAssertFalse(model.picks.isEmpty, "rule picks are on screen while Claude works")
        XCTAssertEqual(model.result?.chosenByReranker, false)
        await curator.release()
        await start.value
        XCTAssertFalse(model.isCurating)
        XCTAssertEqual(model.result?.chosenByReranker, true)
        XCTAssertEqual(model.picks.first?.reason, .written("Claude says so."))
    }

    func testADecisionDuringCurationKeepsTheRulePicksAndTheDecision() async throws {
        let curator = GatedCurator()
        let model = curatedModel(curator)
        let start = Task { await model.start() }
        for _ in 0..<200 where !model.isCurating { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        let pick = try XCTUnwrap(model.picks.first)
        await model.decide(.never, on: pick)
        await curator.release()
        await start.value
        XCTAssertEqual(model.result?.chosenByReranker, false)
        XCTAssertFalse(model.picks.contains { $0.film.key == pick.film.key })
        XCTAssertNotNil(model.lastDecision)
    }
}
