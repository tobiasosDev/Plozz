import Foundation
@testable import FeatureTonightCore

/// A deterministic synthetic library in the spirit of Sichtung's test
/// fixtures: clear taste clusters, so the expected ranking is obvious.
enum TonightFixtures {
    static let now = Date(timeIntervalSince1970: 1_793_000_000) // Nov 2026

    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static func film(
        _ title: String,
        year: Int,
        genres: [TonightGenre],
        director: String,
        rating: Double? = nil,
        plays: Int = 0,
        lastWatched: Date? = nil,
        runtime: Int = 110,
        overview: String? = nil,
        onServer: Bool = true,
        community: Double? = nil,
        votes: Int? = nil,
        tmdb: Int? = nil
    ) -> TonightFilm {
        TonightFilm(
            tmdb: tmdb,
            title: title,
            year: year,
            genres: genres,
            runtimeMinutes: runtime,
            overview: overview,
            directors: [director],
            myRating: rating,
            plays: plays,
            lastWatched: lastWatched ?? (plays > 0 ? daysAgo(400) : nil),
            community: community,
            votes: votes,
            locations: onServer ? [TonightLocation(accountID: "plex", itemID: title)] : []
        )
    }

    /// Loves Michael Mann crime and slow science fiction, dislikes broad comedy.
    static var library: [TonightFilm] {
        [
            film("Heat", year: 1995, genres: [.crime, .thriller], director: "Michael Mann", rating: 10, plays: 3,
                 overview: "A professional heist crew and an obsessive detective collide in Los Angeles."),
            film("Collateral", year: 2004, genres: [.crime, .thriller], director: "Michael Mann", rating: 9, plays: 1,
                 overview: "A taxi driver is forced to drive a contract killer through Los Angeles at night."),
            film("The Creator", year: 2023, genres: [.scienceFiction, .drama], director: "Gareth Edwards", rating: 10, plays: 1,
                 overview: "A soldier hunts an artificial intelligence weapon in a future war."),
            film("Arrival", year: 2016, genres: [.scienceFiction, .drama, .mystery], director: "Denis Villeneuve", plays: 2,
                 overview: "A linguist works to communicate with alien visitors."),
            film("Blade Runner 2049", year: 2017, genres: [.scienceFiction, .thriller, .drama], director: "Denis Villeneuve", plays: 4,
                 lastWatched: daysAgo(900), overview: "A replicant blade runner uncovers a secret buried in the desert."),
            film("Grown Ups 2", year: 2013, genres: [.comedy], director: "Dennis Dugan", rating: 2, plays: 1,
                 overview: "Old friends reunite for a summer of pranks."),
            film("Jack and Jill", year: 2011, genres: [.comedy, .family], director: "Dennis Dugan", rating: 1, plays: 1,
                 overview: "A man dreads the visit of his twin sister."),
            film("Love Actually", year: 2003, genres: [.comedy, .romance], director: "Richard Curtis", rating: 8, plays: 2,
                 lastWatched: daysAgo(30), overview: "Intertwined love stories in London before Christmas."),
            // Unseen candidates.
            film("Thief", year: 1981, genres: [.crime, .thriller], director: "Michael Mann", runtime: 123,
                 overview: "A safecracker plans one last heist in Chicago."),
            film("Miami Vice", year: 2006, genres: [.crime, .action, .thriller], director: "Michael Mann", runtime: 134,
                 overview: "Two detectives go undercover with a drug cartel."),
            film("Moon", year: 2009, genres: [.scienceFiction, .drama], director: "Duncan Jones", runtime: 97,
                 overview: "An astronaut nearing the end of his contract on a lunar base makes a discovery."),
            film("Dune", year: 2021, genres: [.scienceFiction, .adventure, .drama], director: "Denis Villeneuve", runtime: 155,
                 overview: "A noble family becomes embroiled in a war for a desert planet."),
            film("Pixels", year: 2015, genres: [.comedy, .action], director: "Chris Columbus", runtime: 105,
                 overview: "Video game characters attack the Earth."),
            film("Blended", year: 2014, genres: [.comedy, .romance], director: "Frank Coraci", runtime: 117,
                 overview: "Two single parents end up on the same family vacation."),
            film("The Insider", year: 1999, genres: [.drama, .thriller], director: "Michael Mann", runtime: 157,
                 overview: "A tobacco industry whistleblower and a journalist take on big tobacco.", onServer: false),
            film("Elf", year: 2003, genres: [.comedy, .family], director: "Jon Favreau", runtime: 97,
                 overview: "Raised by elves at the North Pole, Buddy travels to New York at Christmas."),
        ]
    }

    /// Thousands of films for scale checks: `seen` watched, `unseen` candidates.
    static func large(seen: Int, unseen: Int) -> [TonightFilm] {
        let genres = TonightGenre.allCases
        let words = ["heist", "space", "family", "detective", "war", "love", "robot", "island", "secret", "journey",
                     "storm", "village", "kingdom", "doctor", "music", "prison", "ocean", "desert", "winter", "city"]
        var films: [TonightFilm] = []
        for index in 0..<(seen + unseen) {
            let g1 = genres[index % genres.count], g2 = genres[(index * 7 + 3) % genres.count]
            let overview = (0..<12).map { words[(index * 31 + $0 * 17) % words.count] }.joined(separator: " ")
            let isSeen = index < seen
            films.append(TonightFilm(
                tmdb: 100_000 + index,
                title: "Film \(index)",
                year: 1950 + index % 75,
                genres: g1 == g2 ? [g1] : [g1, g2],
                runtimeMinutes: 80 + index % 90,
                overview: overview,
                directors: ["Director \(index % 400)"],
                myRating: isSeen && index % 9 == 0 ? Double(1 + index % 10) : nil,
                plays: isSeen ? 1 + index % 3 : 0,
                lastWatched: isSeen ? daysAgo(Double(index % 2000)) : nil,
                community: 5 + Double(index % 50) / 10,
                votes: index % 4000,
                locations: index % 3 == 0 ? [] : [TonightLocation(accountID: "plex", itemID: "\(index)")]
            ))
        }
        return films
    }
}

extension TonightResult {
    var titles: [String] { picks.map(\.film.title) }
}
