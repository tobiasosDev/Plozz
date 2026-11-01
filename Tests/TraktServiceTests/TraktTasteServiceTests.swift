import CoreModels
import CoreNetworking
import Foundation
@testable import TraktService
import XCTest

final class TraktTasteServiceTests: XCTestCase {
    private func service(_ http: TasteHTTP) -> TraktTasteService {
        TraktTasteService(
            config: TraktConfig(clientID: "CLIENT"),
            http: http,
            tokenStore: InMemoryTraktTokenStore(tokens: TraktTokens(accessToken: "acc", refreshToken: "ref", expiresAt: .distantFuture))
        )
    }

    func testWatchedMoviesCarryPlaysLastWatchAndFullMetadata() async throws {
        let http = TasteHTTP()
        let movies = try await service(http).watchedMovies()
        XCTAssertEqual(movies.count, 1)
        let heat = try XCTUnwrap(movies.first)
        XCTAssertEqual(heat.title, "Heat")
        XCTAssertEqual(heat.plays, 3)
        XCTAssertEqual(heat.tmdb, 949)
        XCTAssertEqual(heat.slug, "heat-1995")
        XCTAssertEqual(heat.genres, ["crime", "drama"])
        XCTAssertEqual(heat.lastWatchedAt, ISO8601DateFormatter().date(from: "2025-02-28T19:27:03Z"))
        let requests = await http.requests
        XCTAssertEqual(requests.first?.path, "/sync/watched/movies")
        XCTAssertEqual(requests.first?.authorization, "Bearer acc")
        XCTAssertEqual(requests.first?.extended, "full")
    }

    func testRatingsAreTheViewersOwnScore() async throws {
        let rated = try await service(TasteHTTP()).ratedMovies()
        XCTAssertEqual(rated.first?.userRating, 10)
        XCTAssertEqual(rated.first?.plays, 0)
    }

    func testRelatedFilmsNeedNoUserTokenAndAreBounded() async throws {
        let http = TasteHTTP()
        let related = try await service(http).relatedMovies(to: "heat-1995", limit: 5)
        XCTAssertEqual(related.map(\.title), ["Thief"])
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/movies/heat-1995/related")
        XCTAssertNil(request.authorization)
        XCTAssertEqual(request.limit, "5")
    }

    func testRecommendationsUseTheProfilesToken() async throws {
        let http = TasteHTTP()
        _ = try await service(http).recommendedMovies(limit: 10)
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/recommendations/movies")
        XCTAssertEqual(request.authorization, "Bearer acc")
    }

    func testNoTokenMeansUnauthorizedRatherThanAnEmptyHistory() async {
        let service = TraktTasteService(config: TraktConfig(clientID: "CLIENT"), http: TasteHTTP(), tokenStore: InMemoryTraktTokenStore())
        XCTAssertFalse(service.isConnected)
        do {
            _ = try await service.watchedMovies()
            XCTFail("Expected an authorization failure")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
    }
}

private actor TasteHTTP: HTTPClient {
    struct Request: Sendable {
        var path: String
        var authorization: String?
        var extended: String?
        var limit: String?
    }

    private(set) var requests: [Request] = []

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
        requests.append(Request(
            path: endpoint.path,
            authorization: endpoint.headers["Authorization"],
            extended: query["extended"],
            limit: query["limit"]
        ))
        let movie = #"{"title":"Heat","year":1995,"ids":{"trakt":1,"slug":"heat-1995","imdb":"tt0113277","tmdb":949},"genres":["crime","drama"],"runtime":170,"overview":"A heist.","rating":8.2,"votes":12000,"certification":"R"}"#
        let json: String
        switch endpoint.path {
        case "/sync/watched/movies":
            json = #"[{"plays":3,"last_watched_at":"2025-02-28T19:27:03.000Z","movie":"# + movie + "}]"
        case "/sync/ratings/movies":
            json = #"[{"rating":10,"rated_at":"2025-01-01T00:00:00.000Z","movie":"# + movie + "}]"
        case let path where path.hasSuffix("/related"):
            json = #"[{"title":"Thief","year":1981,"ids":{"trakt":2,"slug":"thief-1981","tmdb":11524}}]"#
        default:
            json = "[" + movie + "]"
        }
        let response = HTTPURLResponse(url: baseURL.appendingPathComponent(endpoint.path), statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}
