import CoreModels
@testable import FeatureTonightCore
import TraktService
import XCTest

final class TonightModelTests: XCTestCase {
    func testGenreNamesFromServersInEnglishAndGermanFoldOntoOneVocabulary() {
        XCTAssertEqual(TonightGenre.normalize(["Science Fiction", "Komödie", "Krimi", "Sci-Fi & Fantasy"]),
                       [.scienceFiction, .comedy, .crime])
        XCTAssertEqual(TonightGenre.normalize(["Action/Adventure"]), [.action, .adventure])
        XCTAssertEqual(TonightGenre.normalize(["Biography", "Unknown Thing"]), [.history])
        XCTAssertNil(TonightGenre.normalize("Reality-TV"))
    }

    func testSeededRandomMatchesSichtungsMulberry32() {
        var random = TonightSeededRandom(seed: 42)
        XCTAssertEqual(random.next(), 0.601103751920, accuracy: 1e-11)
        XCTAssertEqual(random.next(), 0.448290558998, accuracy: 1e-11)
        XCTAssertEqual(random.next(), 0.852465793490, accuracy: 1e-11)
        var other = TonightSeededRandom(seed: 7)
        XCTAssertEqual(other.next(), 0.011704753153, accuracy: 1e-11)
    }

    func testMergeJoinsTMDbIMDbAndTitleTransitivelyAndKeepsWatchState() {
        let trakt = TonightFilm(imdb: "tt0113277", trakt: 1, title: "Heat", year: 1995, myRating: 10, plays: 2)
        let plex = TonightFilm(tmdb: 949, imdb: "tt0113277", title: "Heat", year: 1995, genres: [.crime],
                               locations: [TonightLocation(accountID: "plex", itemID: "1")])
        let jellyfin = TonightFilm(tmdb: 949, title: "Heat", year: 1995, plays: 1, isFavorite: true,
                                   locations: [TonightLocation(accountID: "jf", itemID: "a")])
        let merged = TonightMerge.merge([[trakt], [plex], [jellyfin]])
        XCTAssertEqual(merged.count, 1)
        let film = try! XCTUnwrap(merged.first)
        XCTAssertEqual(film.key, "tmdb:949")
        XCTAssertEqual(film.trakt, 1)
        XCTAssertEqual(film.myRating, 10)
        XCTAssertEqual(film.plays, 2)
        XCTAssertTrue(film.isFavorite)
        XCTAssertEqual(film.locations.count, 2)
    }

    func testAffinityRisesWithEveryRewatchAndUsesQuickRatings() {
        var film = TonightFilm(title: "A", plays: 1)
        let once = TonightSignal.affinity(film)
        film.plays = 2
        let twice = TonightSignal.affinity(film)
        film.plays = 4
        let often = TonightSignal.affinity(film)
        XCTAssertLessThan(once, twice)
        XCTAssertLessThan(twice, often)
        film.localRating = TonightQuickRating.bad.value
        XCTAssertLessThan(TonightSignal.affinity(film), 0)
        XCTAssertEqual(TonightSignal.weight(film), 3)
        let unratedOnce = TonightFilm(title: "B", plays: 1)
        XCTAssertEqual(TonightSignal.weight(unratedOnce), 0.25)
    }

    func testAJellyfinFavouriteCountsLikeANineWithoutClaimingARating() {
        let favourite = TonightFilm(title: "Fav", plays: 1, isFavorite: true)
        let nine = TonightFilm(title: "Nine", myRating: 9, plays: 1)
        XCTAssertEqual(TonightSignal.affinity(favourite), TonightSignal.affinity(nine), accuracy: 1e-9)
        XCTAssertEqual(TonightSignal.weight(favourite), TonightSignal.weight(nine))
        XCTAssertNil(favourite.myRating)
    }

    func testDecadeMoodsInBothLanguages() {
        XCTAssertEqual(TonightMood.decadeStart("80er krimi"), 1980)
        XCTAssertEqual(TonightMood.decadeStart("something from the 90s"), 1990)
        XCTAssertEqual(TonightMood.decadeStart("1970s"), 1970)
        XCTAssertEqual(TonightMood.decadeStart("20er"), 2020)
        XCTAssertNil(TonightMood.decadeStart("2 hours"))
    }

    func testServerMovieMapsHistoryRatingDirectorsAndLocation() {
        var item = MediaItem(id: "42", title: "Moon", kind: .movie)
        item.productionYear = 2009
        item.genres = ["Science Fiction", "Drama"]
        item.people = [MediaPerson(id: "d", name: "Duncan Jones", kind: "Director"), MediaPerson(id: "a", name: "Sam Rockwell", kind: "Actor")]
        item.providerIDs = ["Tmdb": "17431", "Imdb": "tt1182345"]
        item.runtime = 97 * 60
        item.lastPlayedAt = TonightFixtures.daysAgo(10)
        item.librarySortValues = LibrarySortValues(audienceRating: 79, userRating: 90, playCount: 2)
        let film = try! XCTUnwrap(TonightLibraryMapping.film(from: item, accountID: "plex-1"))
        XCTAssertEqual(film.key, "tmdb:17431")
        XCTAssertEqual(film.genres, [.scienceFiction, .drama])
        XCTAssertEqual(film.directors, ["Duncan Jones"])
        XCTAssertEqual(film.myRating, 9)
        XCTAssertEqual(film.plays, 2)
        XCTAssertEqual(film.runtimeMinutes, 97)
        XCTAssertEqual(film.community ?? 0, 7.9, accuracy: 1e-9)
        XCTAssertEqual(film.locations, [TonightLocation(accountID: "plex-1", itemID: "42")])

        let episode = MediaItem(id: "e", title: "Pilot", kind: .episode)
        XCTAssertNil(TonightLibraryMapping.film(from: episode, accountID: "plex-1"))
    }

    func testTraktMovieMapsIdsCommunityAndUserRating() {
        let movie = TraktTasteMovie(
            title: "Thief", year: 1981, traktID: 7, slug: "thief-1981", imdb: "tt0083190", tmdb: 11524,
            genres: ["crime", "drama"], runtimeMinutes: 123, overview: "A safecracker.", communityRating: 7.2, votes: 3000,
            plays: 0, lastWatchedAt: nil, userRating: 8, certification: "R"
        )
        let film = try! XCTUnwrap(TonightLibraryMapping.film(from: movie))
        XCTAssertEqual(film.key, "tmdb:11524")
        XCTAssertEqual(film.traktSlug, "thief-1981")
        XCTAssertEqual(film.genres, [.crime, .drama])
        XCTAssertEqual(film.myRating, 8)
        XCTAssertFalse(film.isOnServer)
    }

    func testASubMinuteRuntimeIsNotARuntime() {
        var item = MediaItem(id: "x", title: "Sample", kind: .movie)
        item.runtime = 3
        XCTAssertNil(TonightLibraryMapping.film(from: item, accountID: "a")?.runtimeMinutes)
    }
}
