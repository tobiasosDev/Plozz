import Foundation
import CoreModels

/// Pure, UI-free decision logic for the search screen, factored out so the
/// debounce / stale-response / grouping rules can be unit-tested without a view
/// or a network.
public enum SearchPolicy {
    /// Canonical form of a raw query: trimmed of surrounding whitespace so
    /// "  dune " and "dune" are treated as the same search.
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a (normalized) query warrants a network request. Empty queries
    /// should reset the screen to its idle prompt rather than hit the server.
    public static func shouldSearch(_ normalizedQuery: String) -> Bool {
        !normalizedQuery.isEmpty
    }

    /// Whether a completed response is still relevant. A response is stale (and
    /// must be discarded) if the live query no longer matches the query the
    /// request was issued for — e.g. the user kept typing while it was in
    /// flight.
    public static func isCurrent(requestedQuery: String, liveQuery: String) -> Bool {
        requestedQuery == normalized(liveQuery)
    }

    /// Completions offered under the search field, the way the TV app offers
    /// "sintel", "spring"… after a single letter: the distinct titles of the
    /// playable results, in result order, lowercased like the system's own
    /// suggestions. An episode suggests its show. "Not in Your Library" titles
    /// are left out — a suggestion should lead to something the user can play.
    public static func suggestions(
        from sections: [SearchSection], query: String, limit: Int = 5, locale: Locale = .current
    ) -> [String] {
        let current = normalized(query).lowercased(with: locale)
        var seen: Set<String> = [current]
        var result: [String] = []
        for section in sections where section.kind != .notInLibrary {
            for item in section.items {
                let title = item.kind == .episode ? (item.parentTitle ?? item.title) : item.title
                let suggestion = normalized(title).lowercased(with: locale)
                guard !suggestion.isEmpty, seen.insert(suggestion).inserted else { continue }
                result.append(suggestion)
                if result.count == limit { return result }
            }
        }
        return result
    }
}
