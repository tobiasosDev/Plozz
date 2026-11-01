import Foundation

/// Where a film can be played: one item on one connected server.
public struct TonightLocation: Codable, Hashable, Sendable {
    public var accountID: String
    public var itemID: String

    public init(accountID: String, itemID: String) {
        self.accountID = accountID
        self.itemID = itemID
    }
}

/// One movie as the taste model sees it: merged across servers and Trakt,
/// carrying only the facts the model reasons with.
public struct TonightFilm: Codable, Hashable, Sendable, Identifiable {
    /// Stable merge key: `tmdb:949`, `imdb:tt0113277` or `title:heat|1995`.
    public var key: String
    public var tmdb: Int?
    public var imdb: String?
    public var trakt: Int?
    public var traktSlug: String?
    public var title: String // l10n:content - catalog media title
    public var originalTitle: String?
    public var year: Int?
    public var genres: [TonightGenre]
    public var runtimeMinutes: Int?
    public var overview: String?
    public var directors: [String]
    public var keywords: [String]
    /// The viewer's own rating, 1–10 (Trakt first, then the server).
    public var myRating: Double?
    /// A rating from the in-app quick round (3/6/9); never written anywhere else.
    public var localRating: Double?
    public var plays: Int
    public var lastWatched: Date?
    public var isFavorite: Bool
    public var onWatchlist: Bool
    /// Community rating, 0–10, and how many votes back it.
    public var community: Double?
    public var votes: Int?
    /// The content rating the server reports ("PG-13", "FSK 12", "16").
    public var officialRating: String?
    public var locations: [TonightLocation]

    public var id: String { key }

    public init(
        key: String? = nil,
        tmdb: Int? = nil,
        imdb: String? = nil,
        trakt: Int? = nil,
        traktSlug: String? = nil,
        title: String,
        originalTitle: String? = nil,
        year: Int? = nil,
        genres: [TonightGenre] = [],
        runtimeMinutes: Int? = nil,
        overview: String? = nil,
        directors: [String] = [],
        keywords: [String] = [],
        myRating: Double? = nil,
        localRating: Double? = nil,
        plays: Int = 0,
        lastWatched: Date? = nil,
        isFavorite: Bool = false,
        onWatchlist: Bool = false,
        community: Double? = nil,
        votes: Int? = nil,
        officialRating: String? = nil,
        locations: [TonightLocation] = []
    ) {
        self.tmdb = tmdb
        self.imdb = imdb
        self.trakt = trakt
        self.traktSlug = traktSlug
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.genres = genres
        self.runtimeMinutes = runtimeMinutes
        self.overview = overview
        self.directors = directors
        self.keywords = keywords
        self.myRating = myRating
        self.localRating = localRating
        self.plays = plays
        self.lastWatched = lastWatched
        self.isFavorite = isFavorite
        self.onWatchlist = onWatchlist
        self.community = community
        self.votes = votes
        self.officialRating = officialRating
        self.locations = locations
        self.key = key ?? Self.filmKey(tmdb: tmdb, imdb: imdb, title: title, year: year)
    }

    /// Whether any connected server can play this film.
    public var isOnServer: Bool { !locations.isEmpty }

    /// The rating the taste model sees: the viewer's own first, then a quick tap.
    public var effectiveRating: Double? { myRating ?? localRating }

    /// Directors joined for display and matching.
    public var directorLine: String? { directors.isEmpty ? nil : directors.joined(separator: ", ") }

    public static func filmKey(tmdb: Int?, imdb: String?, title: String, year: Int?) -> String {
        if let tmdb { return "tmdb:\(tmdb)" }
        if let imdb, !imdb.isEmpty { return "imdb:\(imdb)" }
        return "title:\(TonightText.normalize(title))|\(year.map(String.init) ?? "")"
    }

    /// Every key this film can be recognised by. Two films that share any key
    /// are the same film.
    public var identityKeys: [String] {
        var keys: [String] = [key, Self.filmKey(tmdb: tmdb, imdb: imdb, title: title, year: year)]
        if let tmdb { keys.append("tmdb:\(tmdb)") }
        if let imdb, !imdb.isEmpty { keys.append("imdb:\(imdb)") }
        if let trakt { keys.append("trakt:\(trakt)") }
        let yearText = year.map(String.init) ?? ""
        keys.append("title:\(TonightText.normalize(title))|\(yearText)")
        if let originalTitle, !originalTitle.isEmpty {
            keys.append("title:\(TonightText.normalize(originalTitle))|\(yearText)")
        }
        var seen: Set<String> = []
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func isSameFilm(as other: TonightFilm) -> Bool {
        let mine = Set(identityKeys)
        return other.identityKeys.contains { mine.contains($0) }
    }

    /// A film the viewer has watched at least once.
    public var isSeen: Bool { plays > 0 }
}

/// A reference to a film chosen as the model ("like The Creator").
public struct TonightFilmRef: Codable, Hashable, Sendable {
    public var key: String
    public var title: String // l10n:content - catalog media title
    public var year: Int?
    public var tmdb: Int?

    public init(key: String, title: String, year: Int? = nil, tmdb: Int? = nil) {
        self.key = key
        self.title = title
        self.year = year
        self.tmdb = tmdb
    }

    public init(_ film: TonightFilm) {
        self.init(key: film.key, title: film.title, year: film.year, tmdb: film.tmdb)
    }
}

public enum TonightText {
    /// Lower-case, diacritic-free, punctuation collapsed to single spaces.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }
}

public enum TonightMerge {
    /// Joins films that share any identity key. Later inputs win for scalar
    /// facts they actually carry; genres, locations and watch state accumulate.
    public static func merge(_ groups: [[TonightFilm]]) -> [TonightFilm] {
        var films: [TonightFilm?] = []
        var owner: [String: Int] = [:]
        for incoming in groups.joined() {
            let keys = incoming.identityKeys
            var matches: [Int] = []
            for key in keys {
                if let index = owner[key], films[index] != nil, !matches.contains(index) { matches.append(index) }
            }
            var merged = incoming
            var aliases = Set(keys)
            for index in matches.sorted() {
                guard let old = films[index] else { continue }
                merged = combine(old: old, new: merged)
                aliases.formUnion(old.identityKeys)
                films[index] = nil
            }
            merged.key = TonightFilm.filmKey(tmdb: merged.tmdb, imdb: merged.imdb, title: merged.title, year: merged.year)
            films.append(merged)
            let newIndex = films.count - 1
            for key in aliases.union(merged.identityKeys) { owner[key] = newIndex }
        }
        return films.compactMap { $0 }
    }

    static func combine(old: TonightFilm, new: TonightFilm) -> TonightFilm {
        var out = old
        out.tmdb = new.tmdb ?? old.tmdb
        out.imdb = new.imdb ?? old.imdb
        out.trakt = new.trakt ?? old.trakt
        out.traktSlug = new.traktSlug ?? old.traktSlug
        out.title = new.title
        out.originalTitle = new.originalTitle ?? old.originalTitle
        out.year = new.year ?? old.year
        var genres = old.genres
        for genre in new.genres where !genres.contains(genre) { genres.append(genre) }
        out.genres = genres
        out.runtimeMinutes = new.runtimeMinutes ?? old.runtimeMinutes
        out.overview = (new.overview?.isEmpty == false ? new.overview : nil) ?? old.overview
        out.directors = new.directors.isEmpty ? old.directors : new.directors
        out.keywords = new.keywords.isEmpty ? old.keywords : new.keywords
        out.myRating = new.myRating ?? old.myRating
        out.localRating = new.localRating ?? old.localRating
        out.plays = max(old.plays, new.plays)
        out.lastWatched = [old.lastWatched, new.lastWatched].compactMap { $0 }.max()
        out.isFavorite = old.isFavorite || new.isFavorite
        out.onWatchlist = old.onWatchlist || new.onWatchlist
        out.community = new.community ?? old.community
        out.votes = new.votes ?? old.votes
        out.officialRating = new.officialRating ?? old.officialRating
        var locations = old.locations
        for location in new.locations where !locations.contains(location) { locations.append(location) }
        out.locations = locations
        return out
    }
}
