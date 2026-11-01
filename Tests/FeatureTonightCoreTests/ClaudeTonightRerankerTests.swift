import CoreModels
import CoreNetworking
@testable import FeatureTonightCore
import XCTest

final class ClaudeTonightRerankerTests: XCTestCase {
    private actor StubHTTP: HTTPClient {
        var bodies: [[String: Any]] = []
        var headers: [[String: String]] = []
        var paths: [String] = []
        let reply: String
        let status: Int

        init(reply: String, status: Int = 200) {
            self.reply = reply
            self.status = status
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            paths.append(baseURL.absoluteString + endpoint.path)
            headers.append(endpoint.headers)
            bodies.append((try? JSONSerialization.jsonObject(with: endpoint.body ?? Data()) as? [String: Any]) ?? [:])
            if status != 200 { throw AppError.invalidResponse }
            let response = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(reply.utf8), response)
        }
    }

    private func message(_ text: String, stop: String = "end_turn") -> String {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), encoding: .utf8)!
        return #"{"content":[{"type":"text","text":"# + String(encoded.dropFirst().dropLast()) + #"}],"stop_reason":""# + stop + #""}"#
    }

    private let candidates = TonightFixtures.library.filter { !$0.isSeen }

    private func reranker(_ http: StubHTTP, token: String? = "tok", key: String? = nil) -> ClaudeTonightReranker {
        ClaudeTonightReranker(
            config: ClaudeTonightConfig(baseURL: URL(string: "http://gateway.test:8317")!, authToken: token, apiKey: key, model: "claude-sonnet-5-5"),
            language: "de-CH",
            http: http,
            now: { TonightFixtures.now }
        )
    }

    func testRequestUsesStructuredOutputLowEffortFallbacksAndBearerToken() async throws {
        let http = StubHTTP(reply: message(#"{"picks":[{"id":"c1","reason":"Weil du Heat mit 10 bewertet hast."}]}"#))
        let history = TonightFixtures.library.filter(\.isSeen)
        _ = await reranker(http).rerank(request: TonightRequest(mode: .firstWatch, mood: "verregneter Sonntag", count: 3),
                                        candidates: candidates, history: history, context: TonightRerankContext(savedTitles: ["Moon"]))
        let paths = await http.paths
        XCTAssertEqual(paths, ["http://gateway.test:8317/v1/messages"])
        let allHeaders = await http.headers
        let headers = try XCTUnwrap(allHeaders.first)
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
        XCTAssertNil(headers["x-api-key"])
        XCTAssertEqual(headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let bodies = await http.bodies
        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["temperature"])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let prompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(prompt.contains(#""language":"de-CH""#))
        XCTAssertTrue(prompt.contains(#""mood":"verregneter Sonntag""#))
        XCTAssertTrue(prompt.contains(#""id":"c0""#))
        XCTAssertTrue(prompt.contains("Heat"), "history examples are included")
        XCTAssertTrue(prompt.contains(#""saved":["Moon"]"#))
    }

    func testAnAPIKeyIsSentAsXAPIKey() async throws {
        let http = StubHTTP(reply: message(#"{"picks":[]}"#))
        _ = await reranker(http, token: nil, key: "sk").rerank(request: TonightRequest(), candidates: candidates, history: [], context: TonightRerankContext())
        let allHeaders = await http.headers
        let headers = try XCTUnwrap(allHeaders.first)
        XCTAssertEqual(headers["x-api-key"], "sk")
        XCTAssertNil(headers["Authorization"])
    }

    func testPicksMapShortlistIdsDeduplicateAndDropUnknownOnes() async {
        let reply = message(#"{"picks":[{"id":"c2","reason":"A"},{"id":"c2","reason":"dup"},{"id":"c99","reason":"x"},{"id":"c0","reason":"  B  "}]}"#)
        let result = await reranker(StubHTTP(reply: reply)).rerank(request: TonightRequest(count: 6), candidates: candidates, history: [], context: TonightRerankContext())
        XCTAssertEqual(result.picks.map(\.key), [candidates[2].key, candidates[0].key])
        XCTAssertEqual(result.picks.map(\.reason), ["A", "B"])
    }

    func testRefusalsErrorsAndBrokenJSONLeaveTheRulesInCharge() async {
        let refusal = await reranker(StubHTTP(reply: message(#"{"picks":[{"id":"c0","reason":"A"}]}"#, stop: "refusal")))
            .rerank(request: TonightRequest(), candidates: candidates, history: [], context: TonightRerankContext())
        XCTAssertTrue(refusal.picks.isEmpty)
        let failure = await reranker(StubHTTP(reply: "", status: 529))
            .rerank(request: TonightRequest(), candidates: candidates, history: [], context: TonightRerankContext())
        XCTAssertTrue(failure.picks.isEmpty)
        let broken = await reranker(StubHTTP(reply: message("not json")))
            .rerank(request: TonightRequest(), candidates: candidates, history: [], context: TonightRerankContext())
        XCTAssertTrue(broken.picks.isEmpty)
    }

    func testLongReasonsKeepWholeSentencesOrWords() {
        let text = "Weil du Heat mit 10 bewertet hast und Collateral mit 9. " + String(repeating: "Noch mehr Text ", count: 30)
        let short = ClaudeTonightReranker.shorten(text, limit: 140)
        XCTAssertLessThanOrEqual(short.count, 140)
        XCTAssertEqual(short, "Weil du Heat mit 10 bewertet hast und Collateral mit 9.")
        let words = ClaudeTonightReranker.shorten(String(repeating: "word ", count: 80), limit: 50)
        XCTAssertTrue(words.hasSuffix("…"))
        XCTAssertLessThanOrEqual(words.count, 50)
    }

    func testConfigNeedsACredentialAndIgnoresPlaceholders() {
        XCTAssertNil(ClaudeTonightConfig.resolved(info: [:]))
        XCTAssertNil(ClaudeTonightConfig.resolved(info: ["TonightClaudeAuthToken": "$(TONIGHT_CLAUDE_AUTH_TOKEN)"]))
        let gateway = ClaudeTonightConfig.resolved(info: [
            "TonightClaudeBaseURL": "http://gateway.local:8317", "TonightClaudeAuthToken": "t", "TonightClaudeModel": "claude-sonnet-5-5",
        ])
        XCTAssertEqual(gateway, ClaudeTonightConfig(baseURL: URL(string: "http://gateway.local:8317")!, authToken: "t", model: "claude-sonnet-5-5"))
        let direct = ClaudeTonightConfig.resolved(info: ["TonightClaudeAPIKey": "k", "TonightClaudeModel": ""])
        XCTAssertEqual(direct?.baseURL.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(direct?.model, "claude-opus-5-5")
    }
}
