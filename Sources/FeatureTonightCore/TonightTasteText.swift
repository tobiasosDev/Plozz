import Foundation

/// What a curator should know about the viewer, as compact text and examples.
/// Port of Sichtung's `profileSummary`, `tasteSummary` and `tasteExamples`.
/// This is model input, never user-facing copy.
enum TonightTasteText {
    private struct Bucket {
        var weighted = 0.0
        var weight = 0.0
        var count = 0
    }

    private static func summarize(
        _ history: [TonightFilm],
        keys: (TonightFilm) -> [String],
        shrink: Double
    ) -> [(name: String, score: Double, count: Int)] {
        var buckets: [String: Bucket] = [:]
        for film in history {
            let weight = TonightSignal.weight(film)
            guard weight > 0 else { continue }
            for key in keys(film) {
                var bucket = buckets[key] ?? Bucket()
                bucket.weighted += TonightSignal.affinity(film) * weight
                bucket.weight += weight
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        return buckets
            .filter { $0.value.count >= 2 }
            .map { (name: $0.key, score: $0.value.weighted / ($0.value.weight + shrink), count: $0.value.count) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    private static func format(_ rows: [(name: String, score: Double, count: Int)]) -> String {
        rows.isEmpty ? "not enough data yet" : rows.map {
            "\($0.name.prefix(60)) (\($0.score >= 0 ? "+" : "")\(String(format: "%.2f", $0.score)), \($0.count) films)"
        }.joined(separator: "; ")
    }

    /// Weighted likes and dislikes, not plain frequency.
    static func profile(_ history: [TonightFilm], requested: TonightGenre?) -> [String] {
        let genres = summarize(history, keys: { $0.genres.map(\.rawValue) }, shrink: 0)
        let directors = summarize(history, keys: { $0.directors }, shrink: 1.5)
        let decades = summarize(history, keys: { $0.year.map { ["\($0 / 10 * 10)s"] } ?? [] }, shrink: 0.5)
        let rated = history.filter { $0.effectiveRating != nil || $0.isFavorite }.count
        func top(_ rows: [(name: String, score: Double, count: Int)]) -> [(name: String, score: Double, count: Int)] {
            Array(rows.filter { $0.score > 0.02 }.prefix(6))
        }
        func bottom(_ rows: [(name: String, score: Double, count: Int)]) -> [(name: String, score: Double, count: Int)] {
            Array(rows.filter { $0.score < -0.02 }.suffix(4).reversed())
        }
        var lines = [
            "Taste profile from \(history.count) watched films (\(rated) rated or favorite). Values are weighted affection from -1 to +1, not frequency.",
            "Liked genres: \(format(top(genres)))",
            "Avoided genres: \(format(bottom(genres)))",
            "Liked directors: \(format(top(directors)))",
            "Avoided directors: \(format(bottom(directors)))",
            "Decades by affection: \(format(Array(decades.prefix(6))))",
        ]
        if let requested {
            let films = history.filter { $0.genres.contains(requested) }
            let total = films.reduce(0.0) { $0 + max(0, TonightSignal.affinity($1)) * TonightSignal.weight($1) }
            if total > 0 {
                let sides = TonightGenre.allCases.filter { $0 != requested }.map { side in
                    (side, films.filter { $0.genres.contains(side) }
                        .reduce(0.0) { $0 + max(0, TonightSignal.affinity($1)) * TonightSignal.weight($1) } / total)
                }.sorted { $0.1 > $1.1 }.prefix(3)
                lines.append("\(requested.rawValue) for this viewer usually comes with: "
                    + sides.map { "\($0.0.rawValue) (\(Int(($0.1 * 100).rounded())) %)" }.joined(separator: ", "))
            }
        }
        return lines
    }

    /// Plain counts with average ratings: how often, not how much liked.
    static func summary(_ history: [TonightFilm]) -> [String] {
        struct Aggregate { var count = 0, rated = 0; var sum = 0.0 }
        func collect(_ keys: (TonightFilm) -> [String]) -> [(String, Aggregate)] {
            var map: [String: Aggregate] = [:]
            for film in history {
                for key in keys(film) {
                    var row = map[key] ?? Aggregate()
                    row.count += 1
                    if let rating = film.myRating { row.rated += 1; row.sum += rating }
                    map[key] = row
                }
            }
            return map.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        }
        func format(_ rows: ArraySlice<(String, Aggregate)>) -> String {
            rows.map { name, row in
                "\(name.prefix(70)):\(row.count)" + (row.rated > 0 ? ",avg \(String(format: "%.1f", row.sum / Double(row.rated))) (\(row.rated) ratings)" : "")
            }.joined(separator: "; ")
        }
        let rated = history.filter { $0.myRating != nil }.count
        let directors = collect { $0.directors }.filter { $0.1.count >= 3 }
        return [
            "Total: \(history.count) watched, \(rated) rated. Averages cover existing ratings only.",
            "Genres (count, avg): \(format(collect { $0.genres.map(\.rawValue) }.prefix(18)))",
            "Often watched directors (3+ films, not evidence of liking): \(directors.isEmpty ? "no reliable group yet" : format(directors.prefix(10)))",
            "Decades: \(format(collect { $0.year.map { ["\($0 / 10 * 10)s"] } ?? [] }.prefix(12)))",
        ]
    }

    struct Examples {
        var loved: [TonightFilm]
        var watched: [TonightFilm]
        var recent: [TonightFilm]
        var disliked: [TonightFilm]
    }

    /// Strongest, most request-relevant examples first. Deterministic: the same
    /// history must teach the same taste.
    static func examples(history: [TonightFilm], request: TonightRequest, reference: TonightFilm?) -> Examples {
        let cache = TonightFeatureCache()
        func ranked(_ films: [TonightFilm], _ count: Int, direction: Double) -> [TonightFilm] {
            films.map { film in
                (film, TonightRelevance.score(film, request: request, reference: reference, cache: cache) * 2
                    + TonightSignal.affinity(film) * direction
                    + min(0.3, Double(max(0, film.plays - 1)) * 0.05))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
            .prefix(count)
            .map(\.0)
        }
        let explicit = history.filter { $0.effectiveRating != nil || $0.isFavorite }
        return Examples(
            loved: ranked(explicit.filter { TonightSignal.affinity($0) > 0.25 }, 25, direction: 1),
            watched: ranked(history.filter { $0.effectiveRating == nil && !$0.isFavorite && $0.plays > 0 }, 25, direction: 1),
            recent: Array(history.sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }.prefix(10)),
            disliked: ranked(history.filter { ($0.effectiveRating ?? 10) <= 4 }, 10, direction: -1)
        )
    }
}
