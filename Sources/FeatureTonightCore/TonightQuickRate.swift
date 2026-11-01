import Foundation

/// The quick round that sharpens taste: seen films without a rating, rated as
/// good, okay or bad. The answers stay in Plozz and are never written to Trakt.
public enum TonightQuickRate {
    public struct Stats: Hashable, Sendable {
        public var ratedCount: Int
        public var openCount: Int
    }

    static func open(_ films: [TonightFilm], index: TonightMemoryIndex) -> [TonightFilm] {
        films.filter { film in
            let state = index.entry(for: film)?.state
            return (film.isSeen || state?.seen == true)
                && film.myRating == nil
                && state?.rating == nil
                && state?.quickSkippedAt == nil
                && state?.never != true
        }
    }

    public static func stats(_ films: [TonightFilm], memory: TonightMemory) -> Stats {
        let index = TonightMemoryIndex(memory)
        let seen = films.filter { $0.isSeen || index.entry(for: $0)?.state.seen == true }
        return Stats(
            ratedCount: seen.filter { $0.myRating != nil || index.entry(for: $0)?.state.rating != nil }.count,
            openCount: open(films, index: index).count
        )
    }

    /// The films whose rating teaches the most: often-watched first (was it love
    /// or just company?), spread across genres so a short round covers the whole
    /// profile instead of one corner of it.
    public static func queue(_ films: [TonightFilm], memory: TonightMemory, count: Int = 30) -> [TonightFilm] {
        let ordered = open(films, index: TonightMemoryIndex(memory)).sorted { a, b in
            if a.plays != b.plays { return a.plays > b.plays }
            if a.lastWatched != b.lastWatched { return (a.lastWatched ?? .distantPast) > (b.lastWatched ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        var buckets: [[TonightFilm]] = []
        var bucketIndex: [String: Int] = [:]
        for film in ordered {
            let genre = film.genres.first?.rawValue ?? "none"
            if let position = bucketIndex[genre] {
                buckets[position].append(film)
            } else {
                bucketIndex[genre] = buckets.count
                buckets.append([film])
            }
        }
        var queue: [TonightFilm] = []
        var round = 0
        while queue.count < count {
            var added = false
            for bucket in buckets where queue.count < count && round < bucket.count {
                queue.append(bucket[round])
                added = true
            }
            if !added { break }
            round += 1
        }
        return queue
    }

    /// Records one answer. `nil` means "don't know": the film leaves the queue.
    public static func apply(_ rating: TonightQuickRating?, to film: TonightFilm, memory: inout TonightMemory, now: Date) {
        if let rating {
            memory.setLocalRating(film, rating.value, now: now)
        } else {
            memory.setQuickSkipped(film, now: now)
        }
    }
}
