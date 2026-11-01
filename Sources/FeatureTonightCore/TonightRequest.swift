import Foundation

/// First watch or rewatch: two different questions with their own rules.
public enum TonightMode: String, Codable, Hashable, Sendable, CaseIterable {
    case firstWatch
    case rewatch
}

/// What the viewer asked for tonight.
public struct TonightRequest: Codable, Hashable, Sendable {
    public var mode: TonightMode
    public var genre: TonightGenre?
    public var like: TonightFilmRef?
    /// Free text such as "rainy Sunday"; matched on keywords and themes.
    public var mood: String?
    public var onlyOnServers: Bool
    /// Upper runtime bound in minutes. Films without a known runtime still pass.
    public var maxRuntime: Int?
    /// Keys already shown on earlier pages; excluded strictly.
    public var exclude: [String]
    /// How many picks to return, 1...30. Defaults to 6.
    public var count: Int

    public init(
        mode: TonightMode = .firstWatch,
        genre: TonightGenre? = nil,
        like: TonightFilmRef? = nil,
        mood: String? = nil,
        onlyOnServers: Bool = false,
        maxRuntime: Int? = nil,
        exclude: [String] = [],
        count: Int = 6
    ) {
        self.mode = mode
        self.genre = genre
        self.like = like
        self.mood = mood
        self.onlyOnServers = onlyOnServers
        self.maxRuntime = maxRuntime
        self.exclude = exclude
        self.count = count
    }

    /// The bounded pick count.
    public var pickCount: Int { max(1, min(30, count)) }

    /// How many candidates an optional reranker sees.
    public var shortlistSize: Int { min(100, max(mode == .firstWatch ? 40 : 60, pickCount * 3)) }
}

/// One verdict the viewer gave a history film, as a reason can cite it.
public struct TonightVerdict: Codable, Hashable, Sendable {
    public var title: String // l10n:content - catalog media title
    /// The viewer's own 1–10 rating, when there is one.
    public var rating: Int?
    /// A quick-round verdict, when that is all there is.
    public var quick: TonightQuickRating?
    /// A server favourite without any rating (Jellyfin's only verdict).
    public var favorite: Bool

    public init(_ film: TonightFilm) {
        title = film.title
        rating = film.myRating.map { Int($0.rounded()) }
        quick = film.myRating == nil ? film.localRating.map(TonightQuickRating.init(value:)) : nil
        favorite = film.isFavorite && film.effectiveRating == nil
    }
}

/// How the request itself matches a film. The UI turns each case into copy.
public enum TonightRequestFit: Codable, Hashable, Sendable {
    case christmas
    case winter
    case decade(year: Int)
    case director(String)
    case genreKeyword(TonightGenre)
    case keyword(String)
    case overviewWord(String)
    case referenceDirector(reference: String, director: String)
    case referenceGenre(reference: String, genre: TonightGenre)
    case referenceDecade(reference: String, decade: Int)
    case requestedGenre(TonightGenre)
}

/// Why a rewatch suits tonight.
public enum TonightRewatchLead: Codable, Hashable, Sendable {
    case fit(TonightRequestFit)
    case sameDirector(director: String, verdict: TonightVerdict)
    case relatedGenre(verdict: TonightVerdict, genre: TonightGenre)
    case favorite
    case watchedTimes(Int)
    case ownRating(Int)
    case quickRating(TonightQuickRating)
    case fromHistory
}

/// A structured reason. The core never produces copy; the interface phrases
/// each case through the string catalog so every language reads naturally.
public enum TonightReason: Codable, Hashable, Sendable {
    /// "Because you rated The Creator 10 and Avatar 10." Optionally "Also by …".
    case rated([TonightVerdict], sameDirector: String?)
    /// Films watched several times that share genre or director.
    case watchedRepeatedly([String])
    /// Seen once, no rating: a careful "might suit".
    case watched([String])
    case requestFit(TonightRequestFit)
    case onWatchlist
    case matchesFilters
    case rewatch(TonightRewatchLead, yearsSinceLastWatch: Int?)
    /// Text from an optional reranker, already in the viewer's language.
    case written(String)
}

/// A history film that backs a pick.
public struct TonightEvidence: Codable, Hashable, Sendable {
    public var key: String
    public var title: String // l10n:content - catalog media title
    public var year: Int?
    public var rating: Int?
    public var plays: Int

    public init(_ film: TonightFilm) {
        key = film.key
        title = film.title
        year = film.year
        rating = film.myRating.map { Int($0.rounded()) }
        plays = film.plays
    }
}

public struct TonightPick: Codable, Hashable, Sendable, Identifiable {
    public var film: TonightFilm
    public var reason: TonightReason
    public var evidence: [TonightEvidence]
    public var id: String { film.key }
}

public enum TonightNote: Codable, Hashable, Sendable {
    case nothingMatchesRelaxServers
    case nothingMatchesRelaxRuntime
    case nothingMatchesRelaxGenre
    case picksChangedMeanwhile
    case onlyRecentRepeats
    case someSourcesUnavailable
    case moodMatchedByKeywords
}

public struct TonightResult: Codable, Hashable, Sendable {
    public var picks: [TonightPick]
    public var considered: Int
    public var chosenByReranker: Bool
    public var note: TonightNote?

    public init(picks: [TonightPick], considered: Int, chosenByReranker: Bool = false, note: TonightNote? = nil) {
        self.picks = picks
        self.considered = considered
        self.chosenByReranker = chosenByReranker
        self.note = note
    }
}

/// What the viewer did with a pick.
public enum TonightAction: String, Codable, Hashable, Sendable {
    /// Started playback.
    case play
    /// Generally interesting; a first watch also goes to the Trakt watchlist.
    case save
    /// Hide for about two months with a fading penalty.
    case later
    /// Hide for good; a mild negative signal for close neighbours.
    case never
    /// Counts as seen from now on, without writing any history.
    case seen
    /// Takes back the last action for this film.
    case undo
}

public enum TonightQuickRating: String, Codable, Hashable, Sendable, CaseIterable {
    case good
    case okay
    case bad

    /// The 1–10 value the taste model uses.
    public var value: Double {
        switch self {
        case .good: return 9
        case .okay: return 6
        case .bad: return 3
        }
    }

    public init(value: Double) {
        self = value >= 8 ? .good : value >= 5 ? .okay : .bad
    }
}
