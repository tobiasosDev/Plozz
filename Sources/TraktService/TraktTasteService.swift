import CoreModels
import CoreNetworking
import Foundation

/// A movie as Trakt describes it, with the viewer's own plays and rating when
/// the call is about the viewer's history.
public struct TraktTasteMovie: Hashable, Sendable {
    public var title: String // l10n:content - provider-supplied media title
    public var year: Int?
    public var traktID: Int?
    public var slug: String?
    public var imdb: String?
    public var tmdb: Int?
    public var genres: [String]
    public var runtimeMinutes: Int?
    public var overview: String?
    /// Community rating, 0–10, and its vote count.
    public var communityRating: Double?
    public var votes: Int?
    public var plays: Int
    public var lastWatchedAt: Date?
    /// The viewer's own rating, 1–10.
    public var userRating: Int?
    public var certification: String?

    public init(
        title: String, // l10n:content - provider-supplied media title
        year: Int? = nil,
        traktID: Int? = nil,
        slug: String? = nil,
        imdb: String? = nil,
        tmdb: Int? = nil,
        genres: [String] = [],
        runtimeMinutes: Int? = nil,
        overview: String? = nil,
        communityRating: Double? = nil,
        votes: Int? = nil,
        plays: Int = 0,
        lastWatchedAt: Date? = nil,
        userRating: Int? = nil,
        certification: String? = nil
    ) {
        self.title = title
        self.year = year
        self.traktID = traktID
        self.slug = slug
        self.imdb = imdb
        self.tmdb = tmdb
        self.genres = genres
        self.runtimeMinutes = runtimeMinutes
        self.overview = overview
        self.communityRating = communityRating
        self.votes = votes
        self.plays = plays
        self.lastWatchedAt = lastWatchedAt
        self.userRating = userRating
        self.certification = certification
    }
}

/// Read-only Trakt calls that feed "Tonight": the viewer's watched movies,
/// ratings and watchlist, related films for a seed, and personal
/// recommendations. Nothing here writes to Trakt.
public actor TraktTasteService {
    private let client: TraktClient
    private let auth: TraktAuthService
    private let tokenStore: TraktTokenStoring
    private let http: HTTPClient
    private let config: TraktConfig

    public init(config: TraktConfig, http: HTTPClient, tokenStore: TraktTokenStoring) {
        self.config = config
        self.http = http
        self.client = TraktClient(config: config, http: http)
        self.auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
    }

    /// Whether this profile is signed in to Trakt at all.
    public nonisolated var isConnected: Bool { tokenStore.load() != nil }

    /// `GET /sync/watched/movies` — every watched movie with plays and last watch.
    public func watchedMovies() async throws -> [TraktTasteMovie] {
        let rows: [WatchedRow] = try await get("/sync/watched/movies", query: [.init(name: "extended", value: "full")], authenticated: true)
        return rows.compactMap { row in
            row.movie.map { Self.movie($0, plays: row.plays ?? 1, lastWatchedAt: row.lastWatchedAt.flatMap(Self.parseTimestamp)) }
        }
    }

    /// `GET /sync/ratings/movies` — the viewer's own 1–10 ratings.
    public func ratedMovies() async throws -> [TraktTasteMovie] {
        let rows: [RatingRow] = try await get("/sync/ratings/movies", query: [.init(name: "extended", value: "full")], authenticated: true)
        return rows.compactMap { row in
            row.movie.map { movie in
                var mapped = Self.movie(movie, plays: 0, lastWatchedAt: nil)
                mapped.userRating = row.rating
                return mapped
            }
        }
    }

    /// The movies on the viewer's Trakt watchlist.
    public func watchlistMovies() async throws -> [TraktTasteMovie] {
        let token = try await accessToken()
        return try await client.watchlist(accessToken: token).compactMap { item in
            guard item.kind == .movie else { return nil }
            return TraktTasteMovie(
                title: item.title.title ?? "", year: item.title.year,
                traktID: item.title.ids.trakt, slug: nil, imdb: item.title.ids.imdb, tmdb: item.title.ids.tmdb,
                genres: [], runtimeMinutes: nil, overview: nil, communityRating: nil, votes: nil,
                plays: 0, lastWatchedAt: nil, userRating: nil, certification: nil
            )
        }
    }

    /// `GET /movies/{id}/related` — films Trakt considers related to one seed.
    /// `id` is a Trakt id, slug or IMDb id.
    public func relatedMovies(to id: String, limit: Int = 20) async throws -> [TraktTasteMovie] {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encoded.isEmpty else { return [] }
        let rows: [MovieDTO] = try await get(
            "/movies/\(encoded)/related",
            query: [.init(name: "extended", value: "full"), .init(name: "limit", value: String(limit))],
            authenticated: false
        )
        return rows.map { Self.movie($0, plays: 0, lastWatchedAt: nil) }
    }

    /// `GET /recommendations/movies` — personal recommendations for this account.
    public func recommendedMovies(limit: Int = 50) async throws -> [TraktTasteMovie] {
        let rows: [MovieDTO] = try await get(
            "/recommendations/movies",
            query: [.init(name: "extended", value: "full"), .init(name: "limit", value: String(limit))],
            authenticated: true
        )
        return rows.map { Self.movie($0, plays: 0, lastWatchedAt: nil) }
    }

    // MARK: - Transport

    private func accessToken() async throws -> String {
        guard let token = try await TraktTokenCoordinator.shared.accessToken(store: tokenStore.snapshot(), auth: auth) else {
            throw AppError.unauthorized
        }
        return token
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem], authenticated: Bool) async throws -> T {
        var headers = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": config.clientID ?? "",
        ]
        if authenticated { headers["Authorization"] = "Bearer \(try await accessToken())" }
        let endpoint = Endpoint(method: .get, path: path, queryItems: query, headers: headers)
        return try await http.decode(T.self, from: endpoint, baseURL: config.apiBaseURL)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static func movie(_ dto: MovieDTO, plays: Int, lastWatchedAt: Date?) -> TraktTasteMovie {
        TraktTasteMovie(
            title: dto.title ?? "",
            year: dto.year,
            traktID: dto.ids?.trakt,
            slug: dto.ids?.slug,
            imdb: dto.ids?.imdb,
            tmdb: dto.ids?.tmdb,
            genres: dto.genres ?? [],
            runtimeMinutes: dto.runtime,
            overview: dto.overview,
            communityRating: dto.rating,
            votes: dto.votes,
            plays: plays,
            lastWatchedAt: lastWatchedAt,
            userRating: nil,
            certification: dto.certification
        )
    }

    struct IDs: Decodable {
        var trakt: Int?
        var slug: String?
        var imdb: String?
        var tmdb: Int?
    }

    struct MovieDTO: Decodable {
        var title: String? // l10n:content - provider-supplied media title
        var year: Int?
        var ids: IDs?
        var genres: [String]?
        var runtime: Int?
        var overview: String?
        var rating: Double?
        var votes: Int?
        var certification: String?
    }

    struct WatchedRow: Decodable {
        var plays: Int?
        var lastWatchedAt: String?
        var movie: MovieDTO?

        enum CodingKeys: String, CodingKey {
            case plays
            case lastWatchedAt = "last_watched_at"
            case movie
        }
    }

    struct RatingRow: Decodable {
        var rating: Int?
        var movie: MovieDTO?
    }
}
