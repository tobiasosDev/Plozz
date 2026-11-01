import Foundation

/// How much a film says about taste, and in which direction.
public enum TonightSignal {
    /// Liking, in [-1, 1]. Ratings speak for themselves; unrated films lean
    /// slightly positive, more so the more often they were watched.
    public static func affinity(_ film: TonightFilm) -> Double {
        if let rating = film.effectiveRating { return max(-1, min(1, (rating - 5.5) / 4.5)) }
        // A favourite without a rating counts like a 9 (Jellyfin has no 1–10 scale).
        if film.isFavorite { return (9 - 5.5) / 4.5 }
        if film.plays >= 2 { return min(0.9, 0.55 + 0.12 * Double(film.plays - 2)) }
        return 0.12
    }

    /// How loudly a viewing speaks. Ratings speak loudest, one unrated viewing
    /// barely whispers.
    public static func weight(_ film: TonightFilm) -> Double {
        if film.effectiveRating != nil { return 3 }
        if film.isFavorite { return 3 }
        if film.plays >= 2 { return min(2, 1 + 0.25 * Double(film.plays - 2)) }
        return film.plays > 0 ? 0.25 : 0
    }
}

/// The feature channels. A genre, a keyword and a synopsis word never collide
/// because each id belongs to exactly one channel.
public enum TonightChannel: UInt8, Sendable {
    case genre, combo, keyword, word, director, decade, directorLine

    /// How much one shared trait of this channel weighs in the taste vector.
    var weight: Double {
        switch self {
        case .genre: return 1
        case .combo: return 0.8
        case .keyword: return 1.15
        case .word: return 0.55
        case .director: return 1.6
        case .decade: return 0.3
        case .directorLine: return 0
        }
    }
}

/// Maps feature strings to dense integer ids so comparisons are integer merges
/// instead of string hashing. Ids are stable for the lifetime of one cache.
final class TonightInterner {
    private var ids: [String: Int32] = [:]
    private(set) var channels: [TonightChannel] = []

    var count: Int { channels.count }

    func id(_ text: String, _ channel: TonightChannel) -> Int32 {
        let key = "\(channel.rawValue):\(text)"
        if let existing = ids[key] { return existing }
        let next = Int32(channels.count)
        ids[key] = next
        channels.append(channel)
        return next
    }
}

/// The comparable traits of one film, computed once per run. Every list is a
/// sorted, de-duplicated array of interned ids.
public struct TonightFeatures: Sendable {
    let genres: [Int32]
    let keywords: [Int32]
    let words: [Int32]
    let directors: [Int32]
    /// All directors as one value, for "same director" checks; -1 when unknown.
    let directorLine: Int32
    let decade: Int?
    /// Every vector feature: genres, genre pairs, keywords, words, directors, decade.
    let all: [Int32]

    init(_ film: TonightFilm, interner: TonightInterner) {
        func sortedUnique(_ values: [Int32]) -> [Int32] { Array(Set(values)).sorted() }
        let genreNames = Set(film.genres.map(\.rawValue)).sorted()
        genres = sortedUnique(genreNames.map { interner.id($0, .genre) })
        var pairs: [Int32] = []
        for (index, genre) in genreNames.enumerated() {
            for side in genreNames[(index + 1)...] { pairs.append(interner.id("\(genre)+\(side)", .combo)) }
        }
        keywords = sortedUnique(film.keywords.map(TonightText.normalize).filter { !$0.isEmpty }.map { interner.id($0, .keyword) })
        words = sortedUnique(Self.overviewTokens(film.overview).map { interner.id($0, .word) })
        directors = sortedUnique(film.directors.map(TonightText.normalize).filter { !$0.isEmpty }.map { interner.id($0, .director) })
        let line = TonightText.normalize(film.directorLine ?? "")
        directorLine = line.isEmpty ? -1 : interner.id(line, .directorLine)
        decade = film.year.map { $0 / 10 }
        var all = genres + pairs + keywords + words + directors
        if let decade { all.append(interner.id(String(decade * 10), .decade)) }
        self.all = sortedUnique(all)
    }

    static let stopwords: Set<String> = [
        "einer", "einem", "einen", "eines", "eine", "sein", "seine", "seiner", "seinen", "seinem", "ihre", "ihrer",
        "ihren", "ihrem", "wird", "werden", "wurde", "durch", "uber", "unter", "nach", "noch", "auch", "aber", "oder",
        "sich", "nicht", "mehr", "dann", "dass", "kann", "soll", "muss", "will", "beim", "fur", "wahrend", "zwischen",
        "dieser", "diesem", "diesen", "diese", "jeder", "alle", "alles", "sehr", "schon", "immer", "wieder",
        "the", "and", "with", "from", "that", "this", "when", "after", "before", "into", "their", "they", "them",
        "then", "what", "where", "while", "which", "will", "have", "been", "were", "about", "must", "only", "other",
        "his", "her", "who", "whose", "than", "more", "most", "over", "also", "just", "your",
        "film", "movie", "story", "geschichte", "leben", "life", "welt", "world", "jahr", "jahre", "jahren", "year",
        "years", "zeit", "time", "mann", "frau", "madchen", "junge", "young", "woman",
    ]

    static func overviewTokens(_ overview: String?) -> Set<String> {
        guard let overview, !overview.isEmpty else { return [] }
        var out: Set<String> = []
        for token in TonightText.normalize(overview).split(separator: " ") {
            let word = String(token)
            guard word.count >= 4, !stopwords.contains(word), Int(word) == nil else { continue }
            out.insert(word)
        }
        return out
    }
}

/// Feature, identity and text lookups shared by recommendation runs. Owned by
/// one actor at a time; never shared across concurrent work.
public final class TonightFeatureCache {
    let interner = TonightInterner()
    private var storage: [String: TonightFeatures] = [:]
    private var identityStorage: [String: Set<String>] = [:]
    private var haystackStorage: [String: String] = [:]

    public init() {}

    public func features(_ film: TonightFilm) -> TonightFeatures {
        if let cached = storage[film.key] { return cached }
        let computed = TonightFeatures(film, interner: interner)
        storage[film.key] = computed
        return computed
    }

    /// The film's identity keys, computed once. Titles are normalized to build
    /// them, which is too costly to repeat inside the neighbour pass.
    public func identities(_ film: TonightFilm) -> Set<String> {
        if let cached = identityStorage[film.key] { return cached }
        let computed = Set(film.identityKeys)
        identityStorage[film.key] = computed
        return computed
    }

    public func isSameFilm(_ a: TonightFilm, _ b: TonightFilm) -> Bool {
        a.key == b.key || !identities(a).isDisjoint(with: identities(b))
    }

    /// Normalized title, directors, synopsis and keywords, for free-text moods.
    func haystack(_ film: TonightFilm) -> String {
        if let cached = haystackStorage[film.key] { return cached }
        let computed = TonightText.normalize(
            ([film.title, film.directorLine ?? "", film.overview ?? ""] + film.keywords).joined(separator: " ")
        )
        haystackStorage[film.key] = computed
        return computed
    }
}

public enum TonightSimilarity {
    /// Size of the intersection of two sorted id arrays.
    @inline(__always)
    static func shared(_ a: [Int32], _ b: [Int32]) -> Int {
        var i = 0, j = 0, count = 0
        while i < a.count, j < b.count {
            let x = a[i], y = b[j]
            if x == y { count += 1; i += 1; j += 1 } else if x < y { i += 1 } else { j += 1 }
        }
        return count
    }

    @inline(__always)
    static func cosine(_ a: [Int32], _ b: [Int32]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let common = shared(a, b)
        return common == 0 ? 0 : Double(common) / (Double(a.count) * Double(b.count)).squareRoot()
    }

    /// Content similarity in about [0, 1.35]: genres, themes, synopsis words,
    /// shared directors and the same decade.
    public static func similarity(_ x: TonightFeatures, _ y: TonightFeatures) -> Double {
        cosine(x.genres, y.genres) * 0.45
            + cosine(x.keywords, y.keywords) * 0.3
            + cosine(x.words, y.words) * 0.2
            + cosine(x.directors, y.directors) * 0.35
            + (x.decade != nil && x.decade == y.decade ? 0.05 : 0)
    }

    /// Feedback reaches only close neighbours: same director, a shared theme,
    /// or nearly the same genre set.
    public static func neighbourSignal(_ x: TonightFeatures, _ y: TonightFeatures) -> Double {
        if x.directorLine >= 0, x.directorLine == y.directorLine { return 1 }
        if shared(x.keywords, y.keywords) > 0 { return 0.8 }
        let common = shared(x.genres, y.genres)
        let union = x.genres.count + y.genres.count - common
        return common >= 2 && Double(common) / Double(union) >= 0.75 ? 0.5 : 0
    }
}

/// Dense taste vectors over interned ids.
public enum TonightVectors {
    /// Inverse document frequency per id: rare traits say more about taste
    /// than "action". Ids never seen in the corpus weigh 1.
    static func idf(_ corpus: [TonightFeatures], idCount: Int) -> [Double] {
        var counts = [Int32](repeating: 0, count: idCount)
        for features in corpus {
            for id in features.all where Int(id) < idCount { counts[Int(id)] += 1 }
        }
        let total = Double(max(1, corpus.count))
        return counts.map { $0 == 0 ? 1 : log(1 + total / Double($0)) }
    }

    @inline(__always)
    static func weight(_ id: Int32, idf: [Double], channels: [TonightChannel]) -> Double {
        let index = Int(id)
        return (index < idf.count ? idf[index] : 1) * channels[index].weight
    }
}
