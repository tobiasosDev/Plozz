import CoreModels
import Foundation
import TraktService

/// One connected server account the library is read from.
public struct TonightAccountSource: Sendable {
    public var accountID: String
    public var provider: any MediaProvider

    public init(accountID: String, provider: any MediaProvider) {
        self.accountID = accountID
        self.provider = provider
    }
}

/// The merged movie library "Tonight" reasons over, with what failed to load.
public struct TonightLibrarySnapshot: Codable, Hashable, Sendable {
    public var films: [TonightFilm]
    public var builtAt: Date
    /// Accounts whose movies could not be read this time.
    public var failedAccountIDs: [String]
    public var traktFailed: Bool

    public init(films: [TonightFilm], builtAt: Date, failedAccountIDs: [String] = [], traktFailed: Bool = false) {
        self.films = films
        self.builtAt = builtAt
        self.failedAccountIDs = failedAccountIDs
        self.traktFailed = traktFailed
    }

    public var seenCount: Int { films.filter(\.isSeen).count }
    public var ratedCount: Int { films.filter { $0.myRating != nil }.count }
}

public enum TonightLibraryMapping {
    /// A server movie as the taste model sees it. Non-movies are skipped.
    public static func film(from item: MediaItem, accountID: String) -> TonightFilm? {
        guard item.kind == .movie, !item.id.isEmpty else { return nil }
        let sort = item.librarySortValues
        let userRating = sort?.userRating.flatMap { $0 > 0 ? $0 / 10 : nil }
        let plays = max(sort?.playCount ?? 0, item.hasBeenPlayed || item.isPlayed ? 1 : 0)
        return TonightFilm(
            tmdb: item.providerID(.tmdb).flatMap(Int.init),
            imdb: item.providerID(.imdb),
            title: item.title,
            originalTitle: item.originalTitle,
            year: item.productionYear,
            genres: TonightGenre.normalize(item.genres),
            // Under a minute is a trailer, sample or broken file, not a runtime.
            runtimeMinutes: item.runtime.flatMap { $0 >= 60 ? Int(($0 / 60).rounded()) : nil },
            overview: item.overview,
            directors: item.people.filter { $0.kind?.caseInsensitiveCompare("Director") == .orderedSame }.map(\.name),
            myRating: userRating,
            plays: plays,
            lastWatched: item.lastPlayedAt,
            isFavorite: item.isFavorite,
            onWatchlist: item.watchlistAddedAt != nil,
            community: sort?.audienceRating.map { $0 / 10 },
            officialRating: item.officialRating,
            locations: [TonightLocation(accountID: accountID, itemID: item.id)]
        )
    }

    public static func film(from movie: TraktTasteMovie) -> TonightFilm? {
        guard !movie.title.isEmpty else { return nil }
        return TonightFilm(
            tmdb: movie.tmdb,
            imdb: movie.imdb,
            trakt: movie.traktID,
            traktSlug: movie.slug,
            title: movie.title,
            year: movie.year,
            genres: TonightGenre.normalize(movie.genres),
            runtimeMinutes: movie.runtimeMinutes,
            overview: movie.overview,
            myRating: movie.userRating.map(Double.init),
            plays: movie.plays,
            lastWatched: movie.lastWatchedAt,
            community: movie.communityRating,
            votes: movie.votes,
            officialRating: movie.certification
        )
    }
}

/// Reads every movie from every connected server, plus the viewer's Trakt
/// history, and merges them into one library.
public struct TonightLibraryLoader: Sendable {
    public var pageSize: Int

    public init(pageSize: Int = 300) {
        self.pageSize = pageSize
    }

    public func load(
        accounts: [TonightAccountSource],
        trakt: TraktTasteService?,
        now: Date = Date()
    ) async -> TonightLibrarySnapshot {
        var serverFilms: [TonightFilm] = []
        var failed: [String] = []
        await withTaskGroup(of: (String, [TonightFilm]?).self) { group in
            for account in accounts {
                group.addTask { [pageSize] in
                    do {
                        return (account.accountID, try await Self.movies(of: account, pageSize: pageSize))
                    } catch {
                        return (account.accountID, nil)
                    }
                }
            }
            for await (accountID, films) in group {
                if let films { serverFilms += films } else { failed.append(accountID) }
            }
        }

        var traktGroups: [[TonightFilm]] = []
        var traktFailed = false
        if let trakt, trakt.isConnected {
            async let watchlist = try? trakt.watchlistMovies()
            async let watched = try? trakt.watchedMovies()
            async let rated = try? trakt.ratedMovies()
            let (list, seen, ratings) = await (watchlist, watched, rated)
            traktFailed = list == nil || seen == nil || ratings == nil
            traktGroups.append((list ?? []).compactMap(TonightLibraryMapping.film).map { film in
                var copy = film
                copy.onWatchlist = true
                return copy
            })
            traktGroups.append((seen ?? []).compactMap(TonightLibraryMapping.film))
            traktGroups.append((ratings ?? []).compactMap(TonightLibraryMapping.film))
        }
        // Trakt first so server facts (localized titles and synopses, playable
        // locations) win; a Trakt rating still fills in where the server has none.
        var films = TonightMerge.merge(traktGroups + [serverFilms])
        // A Trakt rating is the viewer's deliberate verdict and wins over a server rating.
        if let ratedGroup = traktGroups.last, !ratedGroup.isEmpty {
            var ratingByKey: [String: Double] = [:]
            for film in ratedGroup { if let rating = film.myRating { for key in film.identityKeys { ratingByKey[key] = rating } } }
            for index in films.indices {
                if let rating = films[index].identityKeys.lazy.compactMap({ ratingByKey[$0] }).first {
                    films[index].myRating = rating
                }
            }
        }
        return TonightLibrarySnapshot(films: films, builtAt: now, failedAccountIDs: failed.sorted(), traktFailed: traktFailed)
    }

    static func movies(of account: TonightAccountSource, pageSize: Int) async throws -> [TonightFilm] {
        let libraries = try await account.provider.libraries().filter { $0.kind == .movie && !$0.isMusic && !$0.isServerCollectionDirectory }
        var films: [TonightFilm] = []
        for library in libraries {
            var page = PageRequest(startIndex: 0, limit: pageSize, detail: .taste)
            while true {
                try Task.checkCancellation()
                let result = try await account.provider.items(in: library.id, kind: .movie, page: page)
                films += result.items.compactMap { TonightLibraryMapping.film(from: $0, accountID: account.accountID) }
                if result.items.isEmpty || page.startIndex + result.items.count >= result.totalCount { break }
                page = page.next()
            }
        }
        return films
    }
}

/// Trakt's related films and personal recommendations as candidates.
public struct TraktTonightSource: TonightCandidateSource {
    private let trakt: TraktTasteService

    public init(trakt: TraktTasteService) {
        self.trakt = trakt
    }

    public func related(to seed: TonightFilm) async throws -> [TonightFilm] {
        guard let id = seed.trakt.map(String.init) ?? seed.traktSlug ?? seed.imdb else { return [] }
        return try await trakt.relatedMovies(to: id).compactMap(TonightLibraryMapping.film)
    }

    public func recommendations() async throws -> [TonightFilm] {
        try await trakt.recommendedMovies().compactMap(TonightLibraryMapping.film)
    }
}
