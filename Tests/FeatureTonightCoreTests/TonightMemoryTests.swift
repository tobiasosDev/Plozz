@testable import FeatureTonightCore
import XCTest

final class TonightMemoryTests: XCTestCase {
    private let now = TonightFixtures.now
    private let moon = TonightFixtures.film("Moon", year: 2009, genres: [.scienceFiction], director: "Duncan Jones", tmdb: 17431)

    func testLaterFadesOverSixtyDaysAndUndoRestoresTheEarlierState() {
        var memory = TonightMemory()
        memory.apply(.later, to: moon, mode: .firstWatch, now: now)
        XCTAssertEqual(memory.penalty(moon, now: now), 18, accuracy: 1e-9)
        XCTAssertEqual(memory.penalty(moon, now: now.addingTimeInterval(30 * 86_400)), 9, accuracy: 1e-6)
        XCTAssertEqual(memory.penalty(moon, now: now.addingTimeInterval(61 * 86_400)), 0, accuracy: 1e-9)

        memory.apply(.undo, to: moon, mode: .firstWatch, now: now)
        XCTAssertEqual(memory.penalty(moon, now: now), 0)
        // A second undo does nothing.
        XCTAssertFalse(memory.apply(.undo, to: moon, mode: .firstWatch, now: now))
    }

    func testANewLaterAfterWeeksStartsAFreshSixtyDaysAndUndoBringsBackTheOldOne() {
        var memory = TonightMemory()
        memory.apply(.later, to: moon, mode: .firstWatch, now: now)
        let weeksLater = now.addingTimeInterval(30 * 86_400)
        memory.apply(.later, to: moon, mode: .firstWatch, now: weeksLater)
        XCTAssertEqual(memory.penalty(moon, now: weeksLater), 18, accuracy: 1e-9)
        memory.apply(.undo, to: moon, mode: .firstWatch, now: weeksLater)
        XCTAssertEqual(memory.penalty(moon, now: weeksLater), 9, accuracy: 1e-6)
    }

    func testRepeatedTapsKeepOneUndoableAction() {
        var memory = TonightMemory()
        XCTAssertTrue(memory.apply(.never, to: moon, mode: .firstWatch, now: now))
        XCTAssertFalse(memory.apply(.never, to: moon, mode: .firstWatch, now: now.addingTimeInterval(100)))
        memory.apply(.undo, to: moon, mode: .firstWatch, now: now)
        XCTAssertFalse(memory.isNever(moon))
    }

    func testUndoRemovesOnlyAWatchlistEntryThisSaveCreated() {
        var memory = TonightMemory()
        memory.apply(.save, to: moon, mode: .firstWatch, watchlistAdded: true, now: now)
        XCTAssertTrue(memory.undoRemovesWatchlistEntry(moon))

        var existing = TonightMemory()
        existing.apply(.save, to: moon, mode: .firstWatch, watchlistAdded: false, now: now)
        XCTAssertFalse(existing.undoRemovesWatchlistEntry(moon))
    }

    func testShownFilmsArePenalisedForTwoWeeksThenFadeByDaySixty() {
        var memory = TonightMemory()
        memory.recordPicks([TonightPick(film: moon, reason: .matchesFilters, evidence: [])], mode: .firstWatch, now: now)
        XCTAssertEqual(memory.penalty(moon, now: now.addingTimeInterval(13 * 86_400)), 12, accuracy: 1e-9)
        XCTAssertLessThan(memory.penalty(moon, now: now.addingTimeInterval(37 * 86_400)), 12)
        XCTAssertEqual(memory.penalty(moon, now: now.addingTimeInterval(60 * 86_400)), 0, accuracy: 1e-9)
        XCTAssertTrue(memory.recentlyShown(moon, now: now.addingTimeInterval(13 * 86_400)))
        XCTAssertFalse(memory.recentlyShown(moon, now: now.addingTimeInterval(15 * 86_400)))
    }

    func testHistoryStaysBoundedAndOnlyTheLastFiveSeedSetsAreBlocked() {
        var memory = TonightMemory()
        let films = (0..<7).map { (index: Int) in TonightFilm(tmdb: index, title: "Seed \(index)") }
        for (index, film) in films.enumerated() {
            memory.recordSeeds([film], now: now.addingTimeInterval(Double(index)))
        }
        let unused = memory.unusedSeeds(films).map(\.title)
        XCTAssertEqual(unused, ["Seed 0", "Seed 1"])
        memory.recordSeeds([], now: now.addingTimeInterval(61 * 86_400))
        XCTAssertEqual(memory.unusedSeeds(films).count, 7)
    }

    func testPermanentMarksSurviveTheBoundedEventHistory() throws {
        var memory = TonightMemory()
        memory.apply(.never, to: moon, mode: .firstWatch, now: now)
        let farFuture = now.addingTimeInterval(400 * 86_400)
        memory.recordPicks([], mode: .firstWatch, now: farFuture)
        XCTAssertTrue(memory.isNever(moon))
        XCTAssertTrue(memory.events.isEmpty)

        let data = try JSONEncoder().encode(memory)
        let decoded = try JSONDecoder().decode(TonightMemory.self, from: data)
        XCTAssertEqual(decoded, memory)
    }

    func testQuickRatingQueueSpreadsGenresAndRatingsFeedTheModel() {
        var memory = TonightMemory()
        let library = [
            TonightFilm(tmdb: 1, title: "Crime A", genres: [.crime], plays: 3, lastWatched: TonightFixtures.daysAgo(5)),
            TonightFilm(tmdb: 2, title: "Crime B", genres: [.crime], plays: 2, lastWatched: TonightFixtures.daysAgo(5)),
            TonightFilm(tmdb: 3, title: "Comedy C", genres: [.comedy], plays: 1, lastWatched: TonightFixtures.daysAgo(5)),
            TonightFilm(tmdb: 4, title: "Drama D", genres: [.drama], plays: 1, lastWatched: TonightFixtures.daysAgo(9)),
            TonightFilm(tmdb: 5, title: "Rated", genres: [.drama], myRating: 8, plays: 1),
            TonightFilm(tmdb: 6, title: "Unseen", genres: [.drama]),
        ]
        // Most-watched first, then one per genre before a second film of any genre.
        let queue = TonightQuickRate.queue(library, memory: memory, count: 3)
        XCTAssertEqual(queue.map(\.title), ["Crime A", "Comedy C", "Drama D"])

        let before = TonightQuickRate.stats(library, memory: memory)
        XCTAssertEqual(before, TonightQuickRate.Stats(ratedCount: 1, openCount: 4))
        TonightQuickRate.apply(.good, to: queue[0], memory: &memory, now: now)
        TonightQuickRate.apply(nil, to: queue[1], memory: &memory, now: now)
        XCTAssertEqual(TonightQuickRate.stats(library, memory: memory), TonightQuickRate.Stats(ratedCount: 2, openCount: 2))
        XCTAssertEqual(memory.localRating(queue[0]), 9)
        XCTAssertEqual(TonightQuickRate.queue(library, memory: memory).map(\.title), ["Crime B", "Drama D"])
    }
}
