import Foundation

/// Candidates from outside the local library: Trakt's related films and
/// personal recommendations, TMDb recommendations.
public protocol TonightCandidateSource: Sendable {
    /// Films related to one seed from the viewer's history.
    func related(to seed: TonightFilm) async throws -> [TonightFilm]
    /// Personal recommendations, independent of any seed.
    func recommendations() async throws -> [TonightFilm]
}

/// An optional curator that may reorder the shortlist and write reasons.
/// The rules remain the fallback for every failure.
public protocol TonightReranker: Sendable {
    func rerank(
        request: TonightRequest,
        candidates: [TonightFilm],
        history: [TonightFilm],
        context: TonightRerankContext
    ) async -> TonightRerankResult
}

/// What a curator may know beyond the history: recent suggestions, the
/// viewer's Save and Never marks, and the chosen reference film.
public struct TonightRerankContext: Sendable {
    public var recentTitles: [String]
    public var savedTitles: [String]
    public var rejectedTitles: [String]
    public var reference: TonightFilm?

    public init(recentTitles: [String] = [], savedTitles: [String] = [], rejectedTitles: [String] = [], reference: TonightFilm? = nil) {
        self.recentTitles = recentTitles
        self.savedTitles = savedTitles
        self.rejectedTitles = rejectedTitles
        self.reference = reference
    }
}

public struct TonightRerankResult: Sendable {
    public struct Pick: Sendable {
        public var key: String
        public var reason: String
        public init(key: String, reason: String) {
            self.key = key
            self.reason = reason
        }
    }

    public var picks: [Pick]
    public init(picks: [Pick]) { self.picks = picks }
}

/// Chooses tonight's films. An actor so the feature cache over a large
/// library is built once and reused across requests.
public actor TonightEngine {
    private let sources: [any TonightCandidateSource]
    private let reranker: (any TonightReranker)?
    /// Whether a curator is configured, so the screen can offer a second pass.
    public nonisolated let canCurate: Bool
    private let isAllowed: @Sendable (TonightFilm) -> Bool
    private var cache = TonightFeatureCache()

    /// - Parameter isAllowed: the profile's parental gate. Every candidate is
    ///   checked, including just before the result is returned.
    public init(
        sources: [any TonightCandidateSource] = [],
        reranker: (any TonightReranker)? = nil,
        isAllowed: @escaping @Sendable (TonightFilm) -> Bool = { _ in true }
    ) {
        self.sources = sources
        self.reranker = reranker
        self.canCurate = reranker != nil
        self.isAllowed = isAllowed
    }

    /// Drops cached features, e.g. after a library sync changed metadata.
    public func invalidate() { cache = TonightFeatureCache() }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public func recommend(
        _ request: TonightRequest,
        library: [TonightFilm],
        memory initialMemory: TonightMemory,
        now: Date = Date(),
        seed: UInt32? = nil,
        curate: Bool = true
    ) async -> (result: TonightResult, memory: TonightMemory) {
        var memory = initialMemory
        let cache = self.cache
        var seeded = seed.map(TonightSeededRandom.init(seed:))
        var system = TonightSystemRandom()
        func sample(_ films: [TonightFilm], _ count: Int, _ reference: TonightFilm?) -> [TonightFilm] {
            if seeded != nil {
                return TonightRelevance.sample(films, count: count, request: request, reference: reference, cache: cache, random: &seeded!)
            }
            return TonightRelevance.sample(films, count: count, request: request, reference: reference, cache: cache, random: &system)
        }
        let count = request.pickCount
        var index = TonightMemoryIndex(memory)

        // Fold local decisions into the library view: "seen" marks and quick ratings.
        let all: [TonightFilm] = library.map { film in
            let keys = cache.identities(film)
            let marked = index.isMarkedSeen(keys)
            let local = film.localRating ?? index.localRating(keys)
            guard marked || local != film.localRating else { return film }
            var copy = film
            if marked { copy.plays = max(1, film.plays) }
            copy.localRating = local
            return copy
        }
        func seen(_ film: TonightFilm) -> Bool { film.plays > 0 || index.isMarkedSeen(cache.identities(film)) }
        let history = all.filter(seen)
        let referenceHistory = history.filter { TonightSignal.affinity($0) > 0 && !index.isNever(cache.identities($0)) }

        var like: TonightFilm?
        if let ref = request.like {
            like = all.first { cache.identities($0).contains(ref.key) }
                ?? TonightFilm(key: ref.key, tmdb: ref.tmdb, title: ref.title, year: ref.year)
        }
        let catalogue = all.filter { !seen($0) }
        let combinations = TonightGenreCombinations(history: history, corpus: catalogue.isEmpty ? all : catalogue)
        let anchor = request.genre ?? like?.genres.first
        func genreFit(_ film: TonightFilm) -> Double {
            combinations.score(film, requested: anchor) * (anchor != nil ? 2.5 : 1.8)
                + (like.map { TonightGenreCombinations.referenceScore(film, reference: $0) * 4 } ?? 0)
        }

        // Seeds: a few loved films from the right corner, rotated across requests.
        let area = referenceHistory.filter { film in
            (like.map { ref in film.genres.contains(where: ref.genres.contains) } ?? true)
                && (request.genre.map { film.genres.contains($0) } ?? true)
        }
        let unused = (area.isEmpty ? referenceHistory : area).filter { film in
            !index.seedUsed(cache.identities(film)) && !(like.map { cache.isSameFilm(film, $0) } ?? false)
        }
        let seeds = (like.map { [$0] } ?? []) + sample(unused, like != nil ? 6 : 7, like)
        memory.recordSeeds(seeds, now: now)

        // External candidates and which seeds endorse them.
        var endorsements: [String: [TonightFilm]] = [:]
        var pool = all
        var sourceFailed = false
        if request.mode == .firstWatch, !sources.isEmpty {
            let gathered = await gather(seeds: seeds)
            sourceFailed = gathered.failed
            for (film, seed) in gathered.endorsed {
                for key in cache.identities(film) {
                    var list = endorsements[key] ?? []
                    if !list.contains(where: { cache.isSameFilm($0, seed) }) { list.append(seed) }
                    endorsements[key] = list
                }
            }
            pool = TonightMerge.merge([gathered.films, all])
        }
        func endorsingSeeds(_ film: TonightFilm) -> [TonightFilm] {
            var out: [TonightFilm] = []
            for key in cache.identities(film) {
                for seed in endorsements[key] ?? [] where !out.contains(where: { cache.isSameFilm($0, seed) }) { out.append(seed) }
            }
            return out
        }

        let excluded = Set(request.exclude)
        let seenIDs = Set(history.flatMap { cache.identities($0) })
        func matchesFilters(_ film: TonightFilm) -> Bool {
            let keys = cache.identities(film)
            if index.isNever(keys) { return false }
            if suppressesSaved(film, keys: keys, index: index, request: request, now: now) { return false }
            if !keys.isDisjoint(with: excluded) { return false }
            if let like, cache.isSameFilm(film, like) { return false }
            if let genre = request.genre, !film.genres.contains(genre) { return false }
            if let maxRuntime = request.maxRuntime, let runtime = film.runtimeMinutes, runtime > maxRuntime { return false }
            if request.onlyOnServers, !film.isOnServer { return false }
            if !isAllowed(film) { return false }
            let watched = film.plays > 0 || index.isMarkedSeen(keys) || !keys.isDisjoint(with: seenIDs)
            let rating = film.effectiveRating
            switch request.mode {
            case .firstWatch: return !watched
            case .rewatch: return watched && (rating == nil || rating! >= 7 || (rating! > 4 && film.plays >= 2))
            }
        }
        let eligible = pool.filter(matchesFilters)

        // The whole history shapes the profile; saved and rejected films pull it too.
        let savedFilms = memory.signalFilms(.save)
        let neverFilms = memory.signalFilms(.never)
        let profile = TonightProfile(
            history: history,
            extras: savedFilms.map { TonightSignedFilm(film: $0, value: 0.6, weight: 1) }
                + neverFilms.map { TonightSignedFilm(film: $0, value: -0.8, weight: 1.5) },
            corpus: pool,
            cache: cache
        )
        let eras = TonightBuckets.decades(history)
        let genreAffinity = TonightBuckets.genres(history)
        let historyIndex = TonightHistoryIndex(history, cache: cache)
        let disliked = history.filter { TonightSignal.affinity($0) < -0.05 }
        let dislikedFeatures = disliked.map(cache.features)
        let dislikedAffinity = disliked.map(TonightSignal.affinity)
        let savedSample = sample(savedFilms, 24, like)
        let neverSample = sample(neverFilms, 24, like)
        let savedSignals = savedSample.map(cache.features)
        let neverSignals = neverSample.map(cache.features)
        let likeFeatures = like.map(cache.features)
        let currentMonth = Calendar(identifier: .gregorian).component(.month, from: now)
        let moodText = TonightText.normalize(request.mood ?? "")
        let hasMood = !moodText.isEmpty

        struct Scored { var film: TonightFilm; var score: Double; var evidence: [TonightFilm] }
        var scored: [Scored] = eligible.map { film in
            let features = cache.features(film)
            let keys = cache.identities(film)
            var score = TonightSignal.affinity(film) * (request.mode == .rewatch ? 4 : 0)
            score += profile.score(features) * 6 + genreFit(film)
            if request.mode == .firstWatch {
                score += TonightBuckets.era(eras, film) * 2 + TonightBuckets.genre(genreAffinity, film) * 2.5
            }
            if let likeFeatures { score += TonightSimilarity.similarity(features, likeFeatures) * 6 }
            for seed in endorsingSeeds(film) {
                score += like.map({ cache.isSameFilm(seed, $0) }) == true ? 2.5 : max(0.2, TonightSignal.affinity(seed))
            }
            if film.onWatchlist { score += 0.65 }
            if film.isOnServer { score += 0.35 }
            score += TonightCommunity.score(film)
            if request.mode == .rewatch, let last = film.lastWatched {
                let days = max(0, now.timeIntervalSince(last) / 86_400)
                score += days < 183 ? -4 * (1 - days / 183) : min(2.5, days / 730)
                if film.plays >= 2, Calendar(identifier: .gregorian).component(.month, from: last) == currentMonth { score += 0.4 }
            }
            if request.mode == .rewatch, index.saved(keys)?.mode == .rewatch { score += 1.2 }
            if hasMood { score += Self.moodScore(film, mood: moodText, haystack: cache.haystack(film)) }
            score -= index.penalty(keys, now: now)
            return Scored(film: film, score: score, evidence: request.mode == .rewatch ? [film] : [])
        }
        func order(_ a: Scored, _ b: Scored) -> Bool {
            a.score != b.score ? a.score > b.score : a.film.title.localizedStandardCompare(b.film.title) == .orderedAscending
        }
        scored.sort(by: order)

        // Pairwise comparisons with disliked, saved and rejected films cost a
        // similarity per pair. A library of tens of thousands of films only needs
        // them where a pick can come from: the front of the cheap ranking.
        let pairwiseCount = min(scored.count, 2000)
        for position in 0..<pairwiseCount {
            let features = cache.features(scored[position].film)
            var dislike = 0.0
            for index in dislikedFeatures.indices {
                dislike = max(dislike, TonightSimilarity.similarity(features, dislikedFeatures[index]) * -dislikedAffinity[index])
            }
            var adjustment = -dislike * 2.5
            adjustment += (savedSignals.map { TonightSimilarity.neighbourSignal(features, $0) }.max() ?? 0) * 0.4
            adjustment -= (neverSignals.map { TonightSimilarity.neighbourSignal(features, $0) }.max() ?? 0) * 0.5
            scored[position].score += adjustment
        }
        if pairwiseCount > 0 {
            let adjusted = scored[0..<pairwiseCount].sorted(by: order)
            scored.replaceSubrange(0..<pairwiseCount, with: adjusted)
        }

        // Neighbour pass on the front of the list: refines order and names the evidence.
        let refineCount = min(scored.count, 300)
        for position in 0..<refineCount {
            let candidate = scored[position].film
            let rows = historyIndex.rows(
                cache.features(candidate), excluding: historyIndex.positions(of: cache.identities(candidate))
            )
            scored[position].score += historyIndex.neighbourAffinity(rows) * 2.5
            if request.mode == .firstWatch {
                let endorsedBy = Set(endorsingSeeds(candidate).flatMap { cache.identities($0) })
                scored[position].evidence = rows
                    .map { row in
                        (row.index, row.score + (cache.identities(historyIndex.films[row.index]).isDisjoint(with: endorsedBy) ? 0 : 0.3))
                    }
                    .filter { $0.1 > 0 }
                    .sorted { $0.1 > $1.1 }
                    .prefix(3)
                    .map { historyIndex.films[$0.0] }
            }
        }
        if refineCount > 0 {
            let refined = scored[0..<refineCount].sorted(by: order)
            scored.replaceSubrange(0..<refineCount, with: refined)
        }

        guard !scored.isEmpty else {
            let note: TonightNote = request.onlyOnServers ? .nothingMatchesRelaxServers
                : request.maxRuntime != nil ? .nothingMatchesRelaxRuntime : .nothingMatchesRelaxGenre
            return (TonightResult(picks: [], considered: 0, note: note), memory)
        }

        // Optional curator over a spread shortlist; the rules fill every gap.
        var chosenByReranker = false
        var written: [String: String] = [:]
        var selected = Self.diversify(scored.map { ($0.film, $0) }, limit: count).map(\.1)
        if curate, let reranker {
            let shortlist = Self.spread(Array(scored.prefix(200)), limit: request.shortlistSize, requestedGenre: request.genre != nil) { $0.film }
            let result = await reranker.rerank(
                request: request,
                candidates: shortlist.map(\.film),
                history: history,
                context: TonightRerankContext(
                    recentTitles: memory.recentTitles(now: now),
                    savedTitles: savedSample.map(\.title),
                    rejectedTitles: neverSample.map(\.title),
                    reference: like
                )
            )
            index = TonightMemoryIndex(memory)
            let allowed = Dictionary(shortlist.map { ($0.film.key, $0) }, uniquingKeysWith: { first, _ in first })
            let verified = result.picks.compactMap { pick in allowed[pick.key].map { (pick, $0) } }.filter { matchesFilters($0.1.film) }
            if !verified.isEmpty {
                chosenByReranker = true
                var ordered: [Scored] = []
                for (_, row) in verified where !ordered.contains(where: { $0.film.key == row.film.key }) { ordered.append(row) }
                ordered += scored
                selected = Self.diversify(ordered.filter { matchesFilters($0.film) }.map { ($0.film, $0) }, limit: count).map(\.1)
                for (pick, row) in verified { written[row.film.key] = pick.reason }
            }
        }

        func present(_ row: Scored) -> TonightPick {
            let reason: TonightReason
            if let text = written[row.film.key] {
                reason = .written(text)
            } else if request.mode == .rewatch {
                reason = TonightReasoning.rewatch(row.film, request: request, history: history, reference: like, cache: cache, now: now)
            } else {
                reason = TonightReasoning.firstWatch(row.film, evidence: row.evidence, request: request, reference: like)
            }
            return TonightPick(film: row.film, reason: reason, evidence: row.evidence.map(TonightEvidence.init))
        }
        var picks = selected.filter { matchesFilters($0.film) }.map(present)

        // Top up with rule order if filters removed anything, honouring the director cap.
        var returned = Set(picks.flatMap { cache.identities($0.film) })
        var directors: [String: Int] = [:]
        for pick in picks { if let line = pick.film.directorLine { directors[line, default: 0] += 1 } }
        let cap = max(2, Int((Double(count) / 4).rounded(.up)))
        for relaxed in [false, true] {
            for row in scored where picks.count < count {
                let keys = cache.identities(row.film)
                guard matchesFilters(row.film), keys.isDisjoint(with: returned) else { continue }
                if !relaxed, let line = row.film.directorLine, directors[line, default: 0] >= cap { continue }
                picks.append(present(row))
                returned.formUnion(keys)
                if let line = row.film.directorLine { directors[line, default: 0] += 1 }
            }
        }

        let onlyRecent = scored.allSatisfy { index.recentlyShown(cache.identities($0.film), now: now) }
        memory.recordPicks(picks, mode: request.mode, now: now)
        let note: TonightNote?
        if picks.isEmpty {
            note = .picksChangedMeanwhile
        } else if onlyRecent {
            note = .onlyRecentRepeats
        } else if sourceFailed {
            note = .someSourcesUnavailable
        } else if !(request.mood ?? "").trimmingCharacters(in: .whitespaces).isEmpty, !curate || reranker == nil {
            note = .moodMatchedByKeywords
        } else {
            note = nil
        }
        return (TonightResult(picks: picks, considered: scored.count, chosenByReranker: chosenByReranker, note: note), memory)
    }

    // MARK: - Helpers

    private func suppressesSaved(
        _ film: TonightFilm,
        keys: Set<String>,
        index: TonightMemoryIndex,
        request: TonightRequest,
        now: Date
    ) -> Bool {
        guard request.mode == .firstWatch, let saved = index.saved(keys), saved.mode == .firstWatch,
              now.timeIntervalSince(saved.at) < 60 * 86_400 else { return false }
        let title = TonightText.normalize(film.title)
        let mood = " \(TonightText.normalize(request.mood ?? "")) "
        let explicitReference = request.like.map { keys.contains($0.key) } ?? false
        let explicitTitle = mood.trimmingCharacters(in: .whitespaces) == title || (title.count >= 3 && mood.contains(" \(title) "))
        return !(explicitReference || explicitTitle)
    }

    private struct Gathered {
        var films: [TonightFilm] = []
        var endorsed: [(TonightFilm, TonightFilm)] = []
        var failed = false
    }

    /// Asks every source for related films per seed (three at a time) and for
    /// personal recommendations. A failing source marks the note, never the result.
    private func gather(seeds: [TonightFilm]) async -> Gathered {
        var gathered = Gathered()
        for source in sources {
            do {
                gathered.films += try await source.recommendations()
            } catch {
                gathered.failed = true
            }
            var queue = seeds[...]
            while !queue.isEmpty {
                let batch = queue.prefix(3)
                queue = queue.dropFirst(batch.count)
                let results = await withTaskGroup(of: (TonightFilm, [TonightFilm]?).self) { group in
                    for seed in batch {
                        group.addTask { (seed, try? await source.related(to: seed)) }
                    }
                    var rows: [(TonightFilm, [TonightFilm]?)] = []
                    for await row in group { rows.append(row) }
                    return rows
                }
                for (seed, related) in results {
                    guard let related else { gathered.failed = true; continue }
                    gathered.films += related
                    gathered.endorsed += related.map { ($0, seed) }
                }
            }
        }
        return gathered
    }

    /// - Parameters:
    ///   - mood: the normalized free text.
    ///   - haystack: the film's normalized title, directors, synopsis and keywords.
    static func moodScore(_ film: TonightFilm, mood text: String, haystack: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var score = 0.0
        if TonightMood.christmas(text) { score += TonightMood.christmasStory(haystack) ? 9 : -3 }
        if TonightMood.scary(text) { score += film.genres.contains(.horror) ? 6 : -2 }
        if TonightMood.winter(text), TonightMood.winterStory(haystack) { score += 5 }
        if TonightMood.light(text) {
            score += film.genres.contains(.comedy) ? 4 : film.genres.contains(.action) ? 2 : -1
        }
        if TonightMood.cosy(text), film.genres.contains(where: [.animation, .family, .drama].contains) { score += 2 }
        if TonightMood.short(text), let runtime = film.runtimeMinutes, runtime <= 105 { score += 3 }
        if let start = TonightMood.decadeStart(text), let year = film.year {
            score += year >= start && year < start + 10 ? 6 : -2
        }
        let ignored: Set<String> = [
            "einen", "eine", "abend", "etwas", "film", "heute", "sonntag", "tonight", "something", "movie", "sunday",
        ]
        for token in text.split(separator: " ") where token.count >= 4 && !ignored.contains(String(token)) {
            if haystack.contains(token) { score += 1.2 }
        }
        return score
    }

    /// At most a quarter of the list from one director; relaxed only when a
    /// small pool cannot otherwise fill it.
    static func diversify<T>(_ rows: [(TonightFilm, T)], limit: Int) -> [(TonightFilm, T)] {
        var counts: [String: Int] = [:]
        var used: Set<String> = []
        var out: [(TonightFilm, T)] = []
        let cap = max(2, Int((Double(limit) / 4).rounded(.up)))
        for relaxed in [false, true] {
            for row in rows where out.count < limit && !used.contains(row.0.key) {
                if !relaxed, let line = row.0.directorLine, counts[line, default: 0] >= cap { continue }
                if let line = row.0.directorLine { counts[line, default: 0] += 1 }
                out.append(row)
                used.insert(row.0.key)
            }
        }
        return out
    }

    /// A shortlist spread over directors, genres and decades for the curator.
    static func spread<T>(_ rows: [T], limit: Int, requestedGenre: Bool, film: (T) -> TonightFilm) -> [T] {
        var directors: [String: Int] = [:], genres: [TonightGenre: Int] = [:], decades: [Int: Int] = [:]
        var selected: [T] = []
        var used: Set<String> = []
        let directorCap = max(4, Int((Double(limit) / 10).rounded(.up)))
        let shareCap = Int((Double(limit) * 0.7).rounded(.up))
        for relaxation in 0...2 {
            for row in rows where selected.count < limit {
                let f = film(row)
                guard !used.contains(f.key) else { continue }
                let director = f.directorLine ?? f.key
                let genre = f.genres.min { (genres[$0] ?? 0) < (genres[$1] ?? 0) }
                let decade = (f.year ?? 0) / 10
                if relaxation < 2, directors[director, default: 0] >= directorCap { continue }
                if relaxation == 0 {
                    let genreFull = !requestedGenre && genre.map { genres[$0, default: 0] >= shareCap } == true
                    if genreFull || decades[decade, default: 0] >= shareCap { continue }
                }
                selected.append(row)
                used.insert(f.key)
                directors[director, default: 0] += 1
                if let genre { genres[genre, default: 0] += 1 }
                decades[decade, default: 0] += 1
            }
        }
        return selected
    }
}
