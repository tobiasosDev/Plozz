import Foundation

/// A source of uniform numbers in [0, 1). Injected so tests are deterministic.
public protocol TonightRandom: Sendable {
    mutating func next() -> Double
}

/// Mulberry32, bit-for-bit the generator Sichtung's tests use.
public struct TonightSeededRandom: TonightRandom {
    private var state: UInt32

    public init(seed: UInt32) { state = seed }

    public mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (1 | t)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

public struct TonightSystemRandom: TonightRandom {
    public init() {}

    public mutating func next() -> Double {
        Double.random(in: 0..<1)
    }
}

public enum TonightSampling {
    static func unit(_ value: Double) -> Double { min(1 - 1e-9, max(1e-9, value)) }

    /// Exponential race: weighted sampling without replacement.
    public static func weightedSample<T>(
        _ items: [T],
        count: Int,
        weight: (T) -> Double,
        random: inout some TonightRandom
    ) -> [T] {
        var ranked: [(item: T, rank: Double)] = []
        ranked.reserveCapacity(items.count)
        for item in items {
            ranked.append((item, log(unit(random.next())) / max(1e-9, weight(item))))
        }
        return ranked.sorted { $0.rank > $1.rank }.prefix(count).map(\.item)
    }
}

/// How strongly a history film relates to tonight's request. Used to pick
/// seeds and feedback examples from the right corner of the history.
public enum TonightRelevance {
    static let moodStopwords: Set<String> = [
        "einen", "eine", "einem", "heute", "abend", "film", "etwas", "eher", "gerne", "bitte",
        "tonight", "something", "movie", "please", "maybe", "rather", "some",
    ]

    public static func score(
        _ film: TonightFilm,
        request: TonightRequest,
        reference: TonightFilm?,
        cache: TonightFeatureCache
    ) -> Double {
        var score = (request.genre.map { film.genres.contains($0) } ?? false) ? 4.0 : 0
        if let reference {
            score += TonightSimilarity.similarity(cache.features(film), cache.features(reference)) * 5
        }
        let text = TonightText.normalize(request.mood ?? "")
        guard !text.isEmpty else { return score }
        let haystack = TonightText.normalize(
            ([film.title, film.directorLine ?? "", film.overview ?? ""]
                + film.genres.flatMap { [$0.rawValue] + $0.aliases }
                + film.keywords).joined(separator: " ")
        )
        for token in text.split(separator: " ") where token.count >= 4 && !moodStopwords.contains(String(token)) {
            if haystack.contains(token) { score += 2 }
        }
        if TonightMood.christmas(text), TonightMood.christmasStory(haystack) { score += 5 }
        if TonightMood.scary(text), film.genres.contains(.horror) { score += 5 }
        if let start = TonightMood.decadeStart(text), let year = film.year, year >= start, year < start + 10 { score += 4 }
        return score
    }

    public static func sample(
        _ films: [TonightFilm],
        count: Int,
        request: TonightRequest,
        reference: TonightFilm?,
        cache: TonightFeatureCache,
        random: inout some TonightRandom
    ) -> [TonightFilm] {
        let rated = films.map { (film: $0, area: score($0, request: request, reference: reference, cache: cache)) }
        let matches = rated.filter { $0.area > 0.3 }
        let pool = matches.isEmpty ? rated : matches
        return TonightSampling.weightedSample(pool, count: count, weight: { row in
            let base = 0.15 + row.area
            let lift = 1 + max(0, TonightSignal.affinity(row.film)) * 3
            return base * base * lift * lift
        }, random: &random).map(\.film)
    }
}

/// Mood keywords understood without a language model, in English and German.
public enum TonightMood {
    static func matches(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    public static func christmas(_ text: String) -> Bool {
        matches(text, ["christmas", "xmas", "weihnacht", "advent", "heiligabend"])
    }

    public static func christmasStory(_ text: String) -> Bool {
        matches(text, ["christmas", "weihnacht", "heiligabend"])
    }

    public static func winter(_ text: String) -> Bool { matches(text, ["winter", "snow", "schnee"]) }

    public static func winterStory(_ text: String) -> Bool {
        matches(text, ["winter", "snow", "schnee", "verschneit", "christmas", "weihnacht", "heiligabend"])
    }

    public static func scary(_ text: String) -> Bool {
        matches(text, ["halloween", "grusel", "horror", "scary", "spooky"])
    }

    public static func light(_ text: String) -> Bool {
        matches(text, ["kopf aus", "abschalten", "leicht", "lustig", "light", "funny", "switch off", "easy"])
    }

    public static func cosy(_ text: String) -> Bool {
        matches(text, ["regen", "sonntag", "gemutlich", "rain", "sunday", "cozy", "cosy"])
    }

    public static func short(_ text: String) -> Bool {
        matches(text, ["kurz", "knackig", "short", "quick"])
    }

    /// "80s", "80er", "1980s", "1990" → the decade's first year.
    public static func decadeStart(_ text: String) -> Int? {
        for token in text.split(separator: " ") {
            var digits = String(token)
            for suffix in ["er", "s"] where digits.hasSuffix(suffix) { digits = String(digits.dropLast(suffix.count)) }
            guard let number = Int(digits) else { continue }
            if (1900...2020).contains(number), number % 10 == 0 { return number }
            if (20...90).contains(number), number % 10 == 0 { return number >= 30 ? 1900 + number : 2000 + number }
        }
        return nil
    }
}
