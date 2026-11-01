import Foundation

/// A film that pushes the profile without being viewing history (Save / Never).
public struct TonightSignedFilm: Sendable {
    public var film: TonightFilm
    public var value: Double
    public var weight: Double
}

/// One taste centroid over the whole history. Every seen film pulls the vector
/// toward (liked) or away from (disliked) its traits, scaled by how much that
/// viewing can say.
public struct TonightProfile: Sendable {
    /// Dense weights indexed by interned feature id.
    let vector: [Double]
    let norm: Double
    let idf: [Double]
    let channels: [TonightChannel]
    /// Films that actually shaped the profile.
    public let signals: Int

    public init(
        history: [TonightFilm],
        extras: [TonightSignedFilm] = [],
        corpus: [TonightFilm],
        cache: TonightFeatureCache
    ) {
        let source = corpus.isEmpty ? history : corpus
        let corpusFeatures = source.map(cache.features)
        // Make sure every history and extra film is interned before sizing.
        let historyFeatures = history.map(cache.features)
        let extraFeatures = extras.map { cache.features($0.film) }
        let idCount = cache.interner.count
        let channels = cache.interner.channels
        let idf = TonightVectors.idf(corpusFeatures, idCount: idCount)
        var vector = [Double](repeating: 0, count: idCount)
        var signals = 0
        func add(_ features: TonightFeatures, value: Double, weight: Double) {
            guard weight != 0, value != 0 else { return }
            signals += 1
            let scale = value * weight
            for id in features.all {
                vector[Int(id)] += scale * TonightVectors.weight(id, idf: idf, channels: channels)
            }
        }
        for (film, features) in zip(history, historyFeatures) {
            add(features, value: TonightSignal.affinity(film), weight: TonightSignal.weight(film))
        }
        for (extra, features) in zip(extras, extraFeatures) { add(features, value: extra.value, weight: extra.weight) }
        self.vector = vector
        self.norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        self.idf = idf
        self.channels = channels
        self.signals = signals
    }

    /// Cosine between a candidate and the centroid, shrunk by how much is known
    /// about the candidate: an obscure film with a two-line synopsis must not
    /// outrank a well-described one on a lucky word overlap.
    public func score(_ features: TonightFeatures) -> Double {
        guard norm > 0, !features.all.isEmpty else { return 0 }
        var dot = 0.0, candidateNorm = 0.0
        var known = 0
        for id in features.all {
            let index = Int(id)
            let channel = index < channels.count ? channels[index] : .word
            let weight = (index < idf.count ? idf[index] : 1) * channel.weight
            candidateNorm += weight * weight
            if index < vector.count { dot += weight * vector[index] }
            if channel != .combo { known += 1 }
        }
        guard candidateNorm > 0 else { return 0 }
        let confidence = min(1, (Double(known) / 36).squareRoot())
        return dot / (candidateNorm.squareRoot() * norm) * confidence
    }
}

public enum TonightBuckets {
    /// Affinity plus sheer familiarity per bucket, in about [-0.6, 0.7].
    /// Unfamiliar buckets score below zero.
    static func scores<K: Hashable>(_ history: [TonightFilm], keys: (TonightFilm) -> [K]) -> [K: Double] {
        var buckets: [K: (weighted: Double, weight: Double, count: Int)] = [:]
        for film in history {
            let weight = TonightSignal.weight(film)
            let affinity = TonightSignal.affinity(film)
            for key in keys(film) {
                var bucket = buckets[key] ?? (0, 0, 0)
                bucket.weighted += affinity * weight
                bucket.weight += weight
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        let total = Double(max(1, history.count))
        return buckets.mapValues { bucket in
            let mean = bucket.weighted / (bucket.weight + 3)
            let familiarity = (Double(bucket.count) / total).squareRoot()
            return max(-1, min(1, mean * 0.6 + (familiarity - 0.35)))
        }
    }

    public static func decades(_ history: [TonightFilm]) -> [Int: Double] {
        scores(history) { film in film.year.map { [$0 / 10 * 10] } ?? [] }
    }

    public static func era(_ scores: [Int: Double], _ film: TonightFilm) -> Double {
        guard let year = film.year else { return 0 }
        return scores[year / 10 * 10] ?? -0.35
    }

    public static func genres(_ history: [TonightFilm]) -> [TonightGenre: Double] {
        scores(history) { $0.genres }
    }

    public static func genre(_ scores: [TonightGenre: Double], _ film: TonightFilm) -> Double {
        guard !film.genres.isEmpty else { return 0 }
        return film.genres.reduce(0) { $0 + (scores[$1] ?? -0.35) } / Double(film.genres.count)
    }
}

/// Conditional side-genre lift: how typical "crime + comedy" is for this
/// viewer compared with how common it is in the catalogue.
public struct TonightGenreCombinations: Sendable {
    struct Signature: Sendable {
        var mass: Double = 0
        var count: Int = 0
        var sides: [TonightGenre: Double] = [:]
    }

    let history: [TonightGenre: Signature]
    let catalogue: [TonightGenre: Signature]
    let primary: [TonightGenre: Double]
    let cataloguePrimary: [TonightGenre: Double]
    let total: Double
    let catalogueTotal: Double

    public init(history: [TonightFilm], corpus: [TonightFilm]) {
        func collect(_ films: [TonightFilm], weighted: Bool) -> ([TonightGenre: Signature], [TonightGenre: Double], Double) {
            var rows: [TonightGenre: Signature] = [:]
            var primary: [TonightGenre: Double] = [:]
            var total = 0.0
            for film in films {
                let value = weighted ? TonightSignal.weight(film) * TonightSignal.affinity(film) : 1
                guard value != 0 else { continue }
                let positive = max(0, value)
                total += positive
                if let first = film.genres.first { primary[first, default: 0] += positive }
                let set = Set(film.genres)
                for main in set {
                    var row = rows[main] ?? Signature()
                    row.mass += positive
                    if positive > 0 { row.count += 1 }
                    for side in set where side != main { row.sides[side, default: 0] += value }
                    rows[main] = row
                }
            }
            return (rows, primary, total)
        }
        let taste = collect(history, weighted: true)
        let base = collect(corpus, weighted: false)
        self.history = taste.0
        self.primary = taste.1
        self.total = taste.2
        self.catalogue = base.0
        self.cataloguePrimary = base.1
        self.catalogueTotal = base.2
    }

    public func score(_ film: TonightFilm, requested: TonightGenre?) -> Double {
        guard let main = requested ?? film.genres.first, film.genres.contains(main),
              let row = history[main], row.mass > 0,
              let base = catalogue[main], base.mass > 0 else { return 0 }
        let confidence = Double(row.count) / Double(row.count + 8)
        func clamp(_ value: Double) -> Double { max(-1.5, min(1.5, value)) }
        var positive: [Double] = []
        var negative: [Double] = []
        var typical = false
        for side in film.genres where side != main {
            let prior = ((base.sides[side] ?? 0) + 1) / (base.mass + 2)
            let rate = (max(0, row.sides[side] ?? 0) + prior * 0.6) / (row.mass + 0.6)
            if rate >= 0.2 { typical = true }
            let lift = clamp(log(rate / prior))
            if lift > 0 { positive.append(lift * rate.squareRoot()) } else { negative.append(lift * prior.squareRoot()) }
        }
        positive.sort(by: >)
        // One familiar pair is enough; accumulating side tags must not dominate quality.
        let pairFit = (positive.first ?? 0) * 0.7
            + (positive.count > 1 ? positive[1] : 0) * 0.15
            + (negative.min() ?? 0)
            + (typical ? 0 : -0.35)
        // A rare primary genre must not inherit the popularity of its side tag.
        let prior = ((cataloguePrimary[main] ?? 0) + 1) / (catalogueTotal + 2)
        let primaryRate = ((primary[main] ?? 0) + prior * 0.6) / (total + 0.6)
        return confidence * (pairFit + (requested != nil ? 0 : 0.5 * clamp(log(primaryRate / prior))))
    }

    /// Preserve the reference's main genre and its defining pair, rather than
    /// a single side tag.
    public static func referenceScore(_ film: TonightFilm, reference: TonightFilm) -> Double {
        guard let main = reference.genres.first else { return 0 }
        guard film.genres.contains(main) else { return -1 }
        guard reference.genres.count > 1 else { return 0.5 }
        let side = reference.genres[1]
        guard film.genres.contains(side) else { return -0.5 }
        let shared = reference.genres.filter { film.genres.contains($0) }.count
        return 0.5 + 0.5 * Double(shared) / Double(max(reference.genres.count, film.genres.count))
    }
}

public enum TonightCommunity {
    /// Unknown vote counts cannot substantiate a positive audience-quality signal.
    public static func score(_ film: TonightFilm) -> Double {
        guard let community = film.community, community.isFinite else { return 0 }
        let raw = max(-1, min(1, (community - 6) / 4))
        let votes = Double(max(0, film.votes ?? 0))
        let shrunk = raw * votes / (votes + 1200)
        // A matching genre pair must not rescue catalogue filler.
        return raw < 0 ? min(raw * 0.7, shrunk) * 2.5 : shrunk
    }
}

public struct TonightNeighbour: Sendable {
    public var film: TonightFilm
    public var similarity: Double
    public var score: Double
}

/// The history, prepared once per run for the neighbour pass: features,
/// affinity and weight as parallel arrays, so the inner loop touches no
/// strings, dictionaries or film copies.
struct TonightHistoryIndex {
    let films: [TonightFilm]
    let features: [TonightFeatures]
    let affinity: [Double]
    let weight: [Double]
    private let positionsByKey: [String: [Int]]

    struct Row {
        let index: Int
        let similarity: Double
        let score: Double
    }

    init(_ films: [TonightFilm], cache: TonightFeatureCache) {
        self.films = films
        features = films.map(cache.features)
        affinity = films.map(TonightSignal.affinity)
        weight = films.map(TonightSignal.weight)
        var positions: [String: [Int]] = [:]
        for (position, film) in films.enumerated() {
            for key in cache.identities(film) { positions[key, default: []].append(position) }
        }
        positionsByKey = positions
    }

    /// History entries that are the candidate itself under another identity.
    func positions(of keys: Set<String>) -> Set<Int> {
        Set(keys.flatMap { positionsByKey[$0] ?? [] })
    }

    /// Every history film with any similarity to the candidate, closest first.
    func rows(_ candidate: TonightFeatures, excluding excluded: Set<Int>) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(min(films.count, 512))
        for index in features.indices where !excluded.contains(index) {
            let similarity = TonightSimilarity.similarity(candidate, features[index])
            if similarity > 0.03 {
                rows.append(Row(index: index, similarity: similarity, score: similarity * affinity[index] * (0.35 + weight[index] / 3)))
            }
        }
        rows.sort { $0.similarity > $1.similarity }
        return rows
    }

    /// Similarity-weighted affinity of the closest neighbours, in [-1, 1],
    /// damped by how close those neighbours actually are.
    func neighbourAffinity(_ rows: [Row], limit: Int = 15) -> Double {
        var weighted = 0.0, weights = 0.0, similarityWeighted = 0.0
        for row in rows.prefix(limit) {
            let w = row.similarity * (0.35 + weight[row.index] / 3)
            weighted += w * affinity[row.index]
            similarityWeighted += w * row.similarity
            weights += w
        }
        guard weights > 0 else { return 0 }
        let closeness = min(1, (similarityWeighted / weights) / 0.3)
        return (weighted / weights) * closeness
    }
}

public enum TonightNeighbours {
    /// Every history film with any similarity to the candidate, closest first.
    public static func rows(
        _ film: TonightFilm,
        history: [TonightFilm],
        cache: TonightFeatureCache
    ) -> [TonightNeighbour] {
        let index = TonightHistoryIndex(history, cache: cache)
        return index.rows(cache.features(film), excluding: index.positions(of: cache.identities(film))).map {
            TonightNeighbour(film: history[$0.index], similarity: $0.similarity, score: $0.score)
        }
    }
}
