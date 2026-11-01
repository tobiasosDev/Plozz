@testable import FeatureTonightCore
import XCTest

final class TonightEngineTests: XCTestCase {
    private let now = TonightFixtures.now

    private func recommend(
        _ request: TonightRequest,
        library: [TonightFilm] = TonightFixtures.library,
        memory: TonightMemory = TonightMemory(),
        engine: TonightEngine = TonightEngine(),
        seed: UInt32 = 1
    ) async -> (TonightResult, TonightMemory) {
        let output = await engine.recommend(request, library: library, memory: memory, now: now, seed: seed)
        return (output.result, output.memory)
    }

    func testFirstWatchPrefersTheProfileAndCitesRatedEvidence() async throws {
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, count: 3))
        XCTAssertEqual(result.picks.count, 3)
        XCTAssertFalse(result.titles.contains { ["Pixels", "Blended"].contains($0) }, "\(result.titles)")
        XCTAssertTrue(result.picks.allSatisfy { !$0.film.isSeen })
        // Sichtung's cap: at most two films by one director in a list of three.
        XCTAssertLessThanOrEqual(result.picks.filter { $0.film.directorLine == "Michael Mann" }.count, 2)
        let mann = try XCTUnwrap(result.picks.first { $0.film.directorLine == "Michael Mann" && $0.film.isOnServer }, "\(result.titles)")
        guard case let .rated(verdicts, sameDirector) = mann.reason else {
            return XCTFail("Expected a rated reason, got \(mann.reason)")
        }
        XCTAssertTrue(verdicts.contains { ($0.title == "Heat" && $0.rating == 10) || ($0.title == "Collateral" && $0.rating == 9) })
        XCTAssertEqual(sameDirector, "Michael Mann")
        XCTAssertTrue(mann.evidence.contains { $0.title == "Heat" || $0.title == "Collateral" })
    }

    func testFiltersHoldInEveryCombination() async {
        for mode in TonightMode.allCases {
            for genre in [nil, TonightGenre.crime, .scienceFiction] {
                for onlyOnServers in [false, true] {
                    for maxRuntime in [nil, 120] {
                        let request = TonightRequest(mode: mode, genre: genre, onlyOnServers: onlyOnServers, maxRuntime: maxRuntime, count: 4)
                        let (result, _) = await recommend(request)
                        for pick in result.picks {
                            if let genre { XCTAssertTrue(pick.film.genres.contains(genre), "\(request) \(pick.film.title)") }
                            if onlyOnServers { XCTAssertTrue(pick.film.isOnServer, "\(request) \(pick.film.title)") }
                            if let maxRuntime { XCTAssertLessThanOrEqual(pick.film.runtimeMinutes ?? 0, maxRuntime) }
                            XCTAssertEqual(pick.film.isSeen, mode == .rewatch, "\(request) \(pick.film.title)")
                        }
                    }
                }
            }
        }
    }

    func testRewatchSkipsDislikedFilmsAndExplainsTheGap() async throws {
        let (result, _) = await recommend(TonightRequest(mode: .rewatch, count: 6))
        XCTAssertFalse(result.titles.contains("Grown Ups 2"))
        XCTAssertFalse(result.titles.contains("Jack and Jill"))
        let blade = try XCTUnwrap(result.picks.first { $0.film.title == "Blade Runner 2049" }, "\(result.titles)")
        guard case let .rewatch(_, years) = blade.reason else { return XCTFail("\(blade.reason)") }
        XCTAssertEqual(years, 2)
        // Watched a month ago: pushed behind films not seen for years.
        if let love = result.titles.firstIndex(of: "Love Actually"), let heat = result.titles.firstIndex(of: "Heat") {
            XCTAssertLessThan(heat, love)
        }
    }

    func testReferenceFilmSteersTowardItsGenreAndDirector() async throws {
        let heat = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Heat" })
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, like: TonightFilmRef(heat), count: 2))
        XCTAssertEqual(Set(result.titles), ["Thief", "Miami Vice"])
    }

    func testExcludedNeverAndSeenMarksDisappearFromFirstWatches() async throws {
        var memory = TonightMemory()
        let thief = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Thief" })
        let moon = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Moon" })
        memory.apply(.never, to: thief, mode: .firstWatch, now: now)
        memory.apply(.seen, to: moon, mode: .firstWatch, now: now)
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, exclude: ["tmdb:none", "title:dune|2021"], count: 10), memory: memory)
        XCTAssertFalse(result.titles.contains("Thief"))
        XCTAssertFalse(result.titles.contains("Moon"))
        XCTAssertFalse(result.titles.contains("Dune"))
        // Seen is allowed as a neutral rewatch.
        let (rewatch, _) = await recommend(TonightRequest(mode: .rewatch, count: 10), memory: memory)
        XCTAssertTrue(rewatch.titles.contains("Moon"), "\(rewatch.titles)")
        XCTAssertFalse(rewatch.titles.contains("Thief"))
    }

    func testEmptySelectionIsValidAndSaysWhichFilterToRelax() async {
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, genre: .western, onlyOnServers: true))
        XCTAssertTrue(result.picks.isEmpty)
        XCTAssertEqual(result.note, .nothingMatchesRelaxServers)
    }

    func testIdenticalRequestsRotateTheMainPick() async {
        var memory = TonightMemory()
        var mains: [String] = []
        for _ in 0..<3 {
            let output = await TonightEngine().recommend(TonightRequest(mode: .firstWatch, count: 1), library: TonightFixtures.library, memory: memory, now: now, seed: 3)
            memory = output.memory
            mains.append(output.result.picks.first?.film.title ?? "")
        }
        XCTAssertEqual(Set(mains).count, 3, "\(mains)")
    }

    func testChristmasMoodFindsTheChristmasFilm() async throws {
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, mood: "something for Christmas", count: 1))
        XCTAssertEqual(result.titles.first, "Elf")
        let (german, _) = await recommend(TonightRequest(mode: .firstWatch, mood: "etwas für Weihnachten", count: 1))
        XCTAssertEqual(german.titles.first, "Elf")
    }

    func testParentalGateIsAppliedToEveryPick() async {
        let engine = TonightEngine(isAllowed: { $0.isOnServer && $0.title != "Thief" })
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, count: 10), engine: engine)
        XCTAssertFalse(result.titles.contains("Thief"))
        XCTAssertFalse(result.titles.contains("The Insider"))
        XCTAssertFalse(result.picks.isEmpty)
    }

    func testNeverPushesCloseNeighboursDownButLessThanABadRating() async throws {
        var memory = TonightMemory()
        let miami = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Miami Vice" })
        let (before, _) = await recommend(TonightRequest(mode: .firstWatch, count: 10))
        memory.apply(.never, to: miami, mode: .firstWatch, now: now)
        let (after, _) = await recommend(TonightRequest(mode: .firstWatch, count: 10), memory: memory)
        XCTAssertFalse(after.titles.contains("Miami Vice"))
        // Thief (same director) is still suggested: Never is a whisper, not a ban.
        XCTAssertTrue(before.titles.contains("Thief"))
        XCTAssertTrue(after.titles.contains("Thief"))
    }

    func testSavedFirstWatchIsSuppressedForSixtyDaysUnlessAskedForByTitle() async throws {
        var memory = TonightMemory()
        let moon = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Moon" })
        memory.apply(.save, to: moon, mode: .firstWatch, now: now)
        let (hidden, _) = await recommend(TonightRequest(mode: .firstWatch, count: 10), memory: memory)
        XCTAssertFalse(hidden.titles.contains("Moon"))
        let (asked, _) = await recommend(TonightRequest(mode: .firstWatch, mood: "Moon", count: 10), memory: memory)
        XCTAssertTrue(asked.titles.contains("Moon"))
    }

    func testExternalCandidatesComeFromSourcesAndCarryTheirSeed() async throws {
        struct Source: TonightCandidateSource {
            func related(to seed: TonightFilm) async throws -> [TonightFilm] {
                seed.title == "Heat" ? [TonightFilm(tmdb: 5, title: "Manhunter", year: 1986, genres: [.crime, .thriller], directors: ["Michael Mann"])] : []
            }
            func recommendations() async throws -> [TonightFilm] { [] }
        }
        let heat = try XCTUnwrap(TonightFixtures.library.first { $0.title == "Heat" })
        let engine = TonightEngine(sources: [Source()])
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, like: TonightFilmRef(heat), count: 3), engine: engine)
        XCTAssertTrue(result.titles.contains("Manhunter"), "\(result.titles)")
        let (servers, _) = await recommend(TonightRequest(mode: .firstWatch, like: TonightFilmRef(heat), onlyOnServers: true, count: 3), engine: engine)
        XCTAssertFalse(servers.titles.contains("Manhunter"))
    }

    func testAFailingSourceKeepsTheResultAndSaysSo() async {
        struct Broken: TonightCandidateSource {
            func related(to seed: TonightFilm) async throws -> [TonightFilm] { throw URLError(.timedOut) }
            func recommendations() async throws -> [TonightFilm] { throw URLError(.timedOut) }
        }
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, count: 3), engine: TonightEngine(sources: [Broken()]))
        XCTAssertEqual(result.picks.count, 3)
        XCTAssertEqual(result.note, .someSourcesUnavailable)
    }

    func testRerankerOrderIsUsedOnlyForShortlistedFilmsThatPassTheFilters() async {
        struct Curator: TonightReranker {
            func rerank(request: TonightRequest, candidates: [TonightFilm], history: [TonightFilm], context: TonightRerankContext) async -> TonightRerankResult {
                TonightRerankResult(picks: [
                    .init(key: "title:invented|2020", reason: "Made up"),
                    .init(key: candidates.last!.key, reason: "Quiet and strange."),
                ])
            }
        }
        let (result, _) = await recommend(TonightRequest(mode: .firstWatch, count: 3), engine: TonightEngine(reranker: Curator()))
        XCTAssertTrue(result.chosenByReranker)
        XCTAssertEqual(result.picks.count, 3)
        XCTAssertEqual(result.picks.first?.reason, .written("Quiet and strange."))
        XCTAssertFalse(result.titles.contains("invented"))
    }

    func testThreeThousandSeenAndFifteenHundredCandidatesStayBounded() async {
        let library = TonightFixtures.large(seen: 3000, unseen: 1500)
        let started = Date()
        let (first, _) = await recommend(TonightRequest(mode: .firstWatch, count: 20), library: library)
        let (rewatch, _) = await recommend(TonightRequest(mode: .rewatch, count: 20), library: library)
        XCTAssertEqual(first.picks.count, 20)
        XCTAssertEqual(rewatch.picks.count, 20)
        XCTAssertTrue(first.picks.allSatisfy { !$0.film.isSeen })
        // Generous ceiling for a debug simulator build; real timing is measured on device.
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)
    }

    func testJellyfinFavouritesAreCitedAsFavouritesNotAsRatings() async throws {
        let library = [
            TonightFilm(tmdb: 1, title: "Heat", year: 1995, genres: [.crime, .thriller], directors: ["Michael Mann"],
                        plays: 1, isFavorite: true, locations: [TonightLocation(accountID: "jf", itemID: "1")]),
            TonightFilm(tmdb: 2, title: "Thief", year: 1981, genres: [.crime, .thriller], directors: ["Michael Mann"],
                        locations: [TonightLocation(accountID: "jf", itemID: "2")]),
        ]
        let (first, _) = await recommend(TonightRequest(mode: .firstWatch, count: 1), library: library)
        let pick = try XCTUnwrap(first.picks.first)
        guard case let .rated(verdicts, sameDirector) = pick.reason else { return XCTFail("\(pick.reason)") }
        XCTAssertEqual(verdicts.first?.title, "Heat")
        XCTAssertEqual(verdicts.first?.favorite, true)
        XCTAssertNil(verdicts.first?.rating)
        XCTAssertEqual(sameDirector, "Michael Mann")

        let (rewatch, _) = await recommend(TonightRequest(mode: .rewatch, count: 1), library: library)
        XCTAssertEqual(rewatch.picks.first?.reason, .rewatch(.favorite, yearsSinceLastWatch: nil))
    }
}
