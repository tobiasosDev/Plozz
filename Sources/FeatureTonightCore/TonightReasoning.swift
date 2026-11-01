import Foundation

/// Builds structured reasons from facts only: real ratings, real viewings, and
/// metadata that actually matches the request. Nothing is inferred about taste
/// that the history does not show.
enum TonightReasoning {
    static func hasWords(_ text: String, _ words: String) -> Bool {
        let needle = TonightText.normalize(words)
        guard !needle.isEmpty else { return false }
        return " \(text) ".contains(" \(needle) ")
    }

    static let overviewStopwords: Set<String> = [
        "einen", "einem", "einer", "eines", "eine", "euch", "deine", "deinem", "deinen", "film", "filme", "abend",
        "heute", "etwas", "bitte", "nach", "nicht", "auch", "aber", "oder", "sich", "seine", "seiner", "seinen",
        "seinem", "ihre", "ihrer", "ihren", "ihrem", "wird", "werden", "durch", "uber", "unter", "eher", "mehr",
        "dann", "dass", "kann", "soll", "gerne", "wieder", "gesehen",
        "tonight", "something", "movie", "movies", "please", "rather", "again", "watch", "about", "maybe",
    ]

    /// How the request matches this film's own metadata, if it does.
    static func requestFit(_ film: TonightFilm, request: TonightRequest, reference: TonightFilm?) -> TonightRequestFit? {
        let text = TonightText.normalize(request.mood ?? "")
        let overview = TonightText.normalize(film.overview ?? "")
        let metadata = TonightText.normalize(([film.overview ?? ""] + film.keywords).joined(separator: " "))
        if !text.isEmpty {
            if TonightMood.christmas(text), TonightMood.christmasStory(metadata) { return .christmas }
            if TonightMood.winter(text), TonightMood.winter(metadata) { return .winter }
            if let start = TonightMood.decadeStart(text), let year = film.year, year >= start, year < start + 10 {
                return .decade(year: year)
            }
            if let director = film.directors.first(where: { name in
                let parts = TonightText.normalize(name).split(separator: " ")
                return hasWords(text, name) || (parts.last.map { $0.count >= 4 && hasWords(text, String($0)) } ?? false)
            }) {
                _ = director
                return .director(film.directorLine ?? director)
            }
            if let genre = film.genres.first(where: { genre in
                ([genre.rawValue] + genre.aliases).contains { hasWords(text, $0) }
            }) {
                return .genreKeyword(genre)
            }
            if let keyword = film.keywords.first(where: { TonightText.normalize($0).count >= 4 && hasWords(text, $0) }) {
                return .keyword(String(keyword.prefix(60)))
            }
            if let word = text.split(separator: " ").map(String.init).first(where: {
                $0.count >= 5 && !overviewStopwords.contains($0) && hasWords(overview, $0)
            }) {
                return .overviewWord(word)
            }
        }
        if request.like != nil, let reference {
            let common = (request.genre.flatMap { film.genres.contains($0) && reference.genres.contains($0) ? $0 : nil })
                ?? reference.genres.first(where: film.genres.contains)
            if let line = reference.directorLine, film.directorLine == line {
                return .referenceDirector(reference: reference.title, director: line)
            }
            if let common { return .referenceGenre(reference: reference.title, genre: common) }
            if let a = reference.year, let b = film.year, a / 10 == b / 10 {
                return .referenceDecade(reference: reference.title, decade: b / 10 * 10)
            }
        }
        if let genre = request.genre { return .requestedGenre(genre) }
        return nil
    }

    /// A rating, or 9 for an unrated favourite; 0 when the viewer said nothing.
    static func verdictScore(_ film: TonightFilm) -> Double {
        film.effectiveRating ?? (film.isFavorite ? 9 : 0)
    }

    static func yearsSince(_ date: Date?, now: Date) -> Double? {
        guard let date else { return nil }
        let years = now.timeIntervalSince(date) / (365.25 * 86_400)
        return years.isFinite ? years : nil
    }

    static func rewatch(
        _ film: TonightFilm,
        request: TonightRequest,
        history: [TonightFilm],
        reference: TonightFilm?,
        cache: TonightFeatureCache,
        now: Date
    ) -> TonightReason {
        var lead: TonightRewatchLead? = requestFit(film, request: request, reference: reference).map { .fit($0) }
        if lead == nil, let line = film.directorLine {
            let normalized = TonightText.normalize(line)
            let rated = history
                .filter { !cache.isSameFilm(film, $0) && $0.directorLine.map(TonightText.normalize) == normalized && verdictScore($0) >= 8 }
                .max { verdictScore($0) < verdictScore($1) }
            if let rated { lead = .sameDirector(director: line, verdict: TonightVerdict(rated)) }
        }
        if lead == nil {
            let features = cache.features(film)
            let related = history
                .filter { !cache.isSameFilm(film, $0) && verdictScore($0) >= 8 }
                .map { (film: $0, similarity: TonightSimilarity.similarity(features, cache.features($0))) }
                .max { $0.similarity < $1.similarity }
            if let related, related.similarity >= 0.4, let common = film.genres.first(where: related.film.genres.contains) {
                lead = .relatedGenre(verdict: TonightVerdict(related.film), genre: common)
            }
        }
        if lead == nil {
            if film.isFavorite, film.effectiveRating == nil {
                lead = .favorite
            } else if film.plays >= 2 {
                lead = .watchedTimes(film.plays)
            } else if let rating = film.myRating {
                lead = .ownRating(Int(rating.rounded()))
            } else if let local = film.localRating {
                lead = .quickRating(TonightQuickRating(value: local))
            } else {
                lead = .fromHistory
            }
        }
        let years = yearsSince(film.lastWatched, now: now)
        let gap = years.flatMap { $0 >= 2 ? Int($0) : nil }
        return .rewatch(lead ?? .fromHistory, yearsSinceLastWatch: gap)
    }

    static func firstWatch(
        _ film: TonightFilm,
        evidence: [TonightFilm],
        request: TonightRequest,
        reference: TonightFilm?
    ) -> TonightReason {
        let rated = Array(evidence.filter { $0.effectiveRating != nil || $0.isFavorite }.prefix(2))
        if !rated.isEmpty {
            let sameDirector = film.directorLine.flatMap { line in rated.contains { $0.directorLine == line } ? line : nil }
            return .rated(rated.map(TonightVerdict.init), sameDirector: sameDirector)
        }
        let repeated = Array(evidence.filter { $0.plays >= 2 }.prefix(2))
        if !repeated.isEmpty { return .watchedRepeatedly(repeated.map(\.title)) }
        let watched = Array(evidence.prefix(2))
        if !watched.isEmpty { return .watched(watched.map(\.title)) }
        if let fit = requestFit(film, request: request, reference: reference) { return .requestFit(fit) }
        return film.onWatchlist ? .onWatchlist : .matchesFilters
    }
}
