import XCTest
@testable import CoreModels

/// `providerID(_:)` answers without building the whole normalized map; these pin
/// that it still agrees with `normalizedProviderIDs` across spellings.
final class ProviderIDLookupTests: XCTestCase {
    func testSpellingsResolveLikeTheNormalizedMap() {
        let cases: [[String: String]] = [
            ["Tmdb": "1"],
            ["TheMovieDb": " 2 "],
            ["TMDb ID": "3"],
            ["themoviedb.com": "4", "Imdb": "tt5"],
            ["IMDb ID": "tt6", "Tvdb": "7"],
            ["Séries Tmdb": "8"],
            ["Tmdb": "   ", "TheMovieDb": "9"],
        ]
        for ids in cases {
            let normalized = ids.normalizedProviderIDs
            for namespace in [ProviderIDNamespace.tmdb, .imdb, .tvdb, .seriesTmdb] {
                let expected = namespace.aliasesForTesting.lazy.compactMap { normalized[$0] }.first
                XCTAssertEqual(ids.providerID(namespace), expected, "\(ids) \(namespace)")
            }
        }
    }

    func testAliasOrderDecidesBetweenSpellings() {
        // "tmdb" precedes "themoviedb" in the alias table.
        XCTAssertEqual(["TheMovieDb": "b", "Tmdb": "a"].providerID(.tmdb), "a")
        // A blank value never hides a later spelling.
        XCTAssertEqual(["Tmdb": " ", "TheMovieDb": "b"].providerID(.tmdb), "b")
        XCTAssertNil(["Tmdb": " "].providerID(.tmdb))
    }

    func testNonASCIIKeysStillNormalize() {
        XCTAssertEqual(["Ｔｍｄｂ": "x"].normalizedProviderIDs.count, 1)
        XCTAssertEqual(["IMDb-ID": "tt1"].providerID(.imdb), "tt1")
    }
}
