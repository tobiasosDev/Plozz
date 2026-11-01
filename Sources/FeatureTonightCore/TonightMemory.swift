import Foundation

/// Everything the viewer told "Tonight": what was shown, the five decisions
/// with their undo state, quick ratings and recent seeds.
///
/// A value type so it can be persisted per profile, synced, and tested without
/// a disk. Every mutation takes `now` explicitly.
public struct TonightMemory: Codable, Hashable, Sendable {
    public struct FilmInfo: Codable, Hashable, Sendable {
        public var key: String
        public var aliases: [String]
        public var title: String // l10n:content - catalog media title
        public var year: Int?
    }

    public enum Slot: String, Codable, Sendable { case main, alternative }

    public struct Event: Codable, Hashable, Sendable {
        public var info: FilmInfo
        public var at: Date
        public var mode: TonightMode
        public var slot: Slot?
        public var action: TonightAction?
    }

    public struct Saved: Codable, Hashable, Sendable {
        public var at: Date
        public var mode: TonightMode
        public var watchlistAdded: Bool
    }

    public struct Rating: Codable, Hashable, Sendable {
        public var value: Double
        public var at: Date
    }

    public struct State: Codable, Hashable, Sendable {
        public var never = false
        public var seen = false
        public var laterAt: Date?
        public var saved: Saved?
        public var rating: Rating?
        public var quickSkippedAt: Date?

        var isEmpty: Bool { !never && !seen && laterAt == nil && saved == nil && rating == nil && quickSkippedAt == nil }
    }

    public struct Undo: Codable, Hashable, Sendable {
        public var action: TonightAction
        public var before: State
        public var at: Date
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var info: FilmInfo
        public var film: TonightFilm
        public var state: State
        public var undo: Undo?
    }

    public struct Seeds: Codable, Hashable, Sendable {
        public var at: Date
        public var keys: [String]
    }

    public private(set) var events: [Event] = []
    public private(set) var seeds: [Seeds] = []
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    static let day: TimeInterval = 86_400

    // MARK: - Lookup

    private func info(_ film: TonightFilm) -> FilmInfo {
        FilmInfo(key: film.key, aliases: film.identityKeys, title: String(film.title.prefix(200)), year: film.year)
    }

    private func entryKey(_ film: TonightFilm) -> String? {
        if entries[film.key] != nil { return film.key }
        let keys = Set(film.identityKeys)
        return entries.first { _, entry in entry.info.aliases.contains(where: keys.contains) }?.key
    }

    private func entry(_ film: TonightFilm) -> Entry? { entryKey(film).flatMap { entries[$0] } }

    public func isNever(_ film: TonightFilm) -> Bool { entry(film)?.state.never ?? false }
    public func isMarkedSeen(_ film: TonightFilm) -> Bool { entry(film)?.state.seen ?? false }
    public func saved(_ film: TonightFilm) -> Saved? { entry(film)?.state.saved }
    public func localRating(_ film: TonightFilm) -> Double? { entry(film)?.state.rating?.value }
    public func quickSkipped(_ film: TonightFilm) -> Bool { entry(film)?.state.quickSkippedAt != nil }
    public func lastAction(_ film: TonightFilm) -> Undo? { entry(film)?.undo }
    public var localRatedCount: Int { entries.values.filter { $0.state.rating != nil }.count }

    /// Films that push the profile: saved (gently positive) or never (negative).
    public func signalFilms(_ action: TonightAction) -> [TonightFilm] {
        entries.values.filter { entry in
            action == .never ? entry.state.never : entry.state.saved != nil && !entry.state.never
        }.map(\.film).sorted { $0.key < $1.key }
    }

    /// A first watch saved within 60 days is not suggested again, unless its
    /// title is asked for explicitly.
    public func suppressesSaved(_ film: TonightFilm, request: TonightRequest, now: Date) -> Bool {
        guard request.mode == .firstWatch, let saved = saved(film), saved.mode == .firstWatch,
              now.timeIntervalSince(saved.at) < 60 * Self.day else { return false }
        let title = TonightText.normalize(film.title)
        let mood = " \(TonightText.normalize(request.mood ?? "")) "
        let explicitReference = request.like.map { film.identityKeys.contains($0.key) } ?? false
        let explicitTitle = mood.trimmingCharacters(in: .whitespaces) == title
            || (title.count >= 3 && mood.contains(" \(title) "))
        return !(explicitReference || explicitTitle)
    }

    /// The mode a film was last shown in.
    public func shownMode(_ film: TonightFilm) -> TonightMode? {
        let ids = Set(film.identityKeys)
        return events.last { $0.slot != nil && $0.info.aliases.contains(where: ids.contains) }?.mode
    }

    /// Rotation: recently shown films and "later" decisions fade back in.
    public func penalty(_ film: TonightFilm, now: Date) -> Double {
        TonightMemoryIndex(self).penalty(Set(film.identityKeys), now: now)
    }

    public func recentlyShown(_ film: TonightFilm, days: Double = 14, now: Date) -> Bool {
        TonightMemoryIndex(self).recentlyShown(Set(film.identityKeys), days: days, now: now)
    }

    /// Titles shown in the last two weeks, newest first, for an optional reranker.
    public func recentTitles(now: Date) -> [String] {
        var seen: Set<String> = []
        var titles: [String] = []
        for event in events.reversed() where event.slot != nil && event.at >= now.addingTimeInterval(-14 * Self.day) {
            let title = event.info.year.map { "\(event.info.title) (\($0))" } ?? event.info.title
            if seen.insert(title).inserted { titles.append(title) }
            if titles.count == 120 { break }
        }
        return titles
    }

    public func unusedSeeds(_ films: [TonightFilm]) -> [TonightFilm] {
        let used = Set(seeds.flatMap(\.keys))
        return films.filter { !$0.identityKeys.contains(where: used.contains) }
    }

    // MARK: - Mutations

    public mutating func recordSeeds(_ films: [TonightFilm], now: Date) {
        seeds.append(Seeds(at: now, keys: films.flatMap(\.identityKeys)))
        prune(now: now)
    }

    public mutating func recordPicks(_ picks: [TonightPick], mode: TonightMode, now: Date) {
        for (index, pick) in picks.enumerated() {
            events.append(Event(info: info(pick.film), at: now, mode: mode, slot: index == 0 ? .main : .alternative))
        }
        prune(now: now)
    }

    public mutating func setLocalRating(_ film: TonightFilm, _ value: Double?, now: Date) {
        var row = ensureEntry(film)
        row.state.rating = value.map { Rating(value: $0, at: now) }
        row.state.quickSkippedAt = nil
        store(row)
        prune(now: now)
    }

    public mutating func setQuickSkipped(_ film: TonightFilm, now: Date) {
        var row = ensureEntry(film)
        row.state.quickSkippedAt = now
        store(row)
        prune(now: now)
    }

    /// Applies one decision. Repeating the same decision within five seconds
    /// (or Never/Seen at any time) keeps a single undoable action.
    /// - Returns: whether the memory changed.
    @discardableResult
    public mutating func apply(
        _ action: TonightAction,
        to film: TonightFilm,
        mode: TonightMode,
        watchlistAdded: Bool = false,
        now: Date
    ) -> Bool {
        if action == .undo { return undo(film, mode: mode, now: now) }
        var row = ensureEntry(film)
        if let last = row.undo, last.action == action, action != .play,
           action == .never || action == .seen || now.timeIntervalSince(last.at) < 5,
           action != .save || row.state.saved?.mode == mode {
            return false
        }
        row.undo = Undo(action: action, before: row.state, at: now)
        row.film = film
        row.info.aliases = Array(Set(row.info.aliases).union(film.identityKeys)).sorted()
        switch action {
        case .never: row.state.never = true
        case .seen: row.state.seen = true
        case .later: row.state.laterAt = now
        case .save:
            row.state.saved = Saved(
                at: now, mode: mode,
                watchlistAdded: watchlistAdded || (row.state.saved?.watchlistAdded ?? false)
            )
        case .play, .undo: break
        }
        store(row)
        events.append(Event(info: info(film), at: now, mode: mode, slot: nil, action: action))
        prune(now: now)
        return true
    }

    /// Whether undoing the last action must also remove a watchlist entry that
    /// this very Save created. Pre-existing entries are never touched.
    public func undoRemovesWatchlistEntry(_ film: TonightFilm) -> Bool {
        guard let row = entry(film), let undo = row.undo, undo.action == .save else { return false }
        return (row.state.saved?.watchlistAdded ?? false) && !(undo.before.saved?.watchlistAdded ?? false)
    }

    private mutating func undo(_ film: TonightFilm, mode: TonightMode, now: Date) -> Bool {
        guard var row = entry(film), let previous = row.undo else { return false }
        row.state = previous.before
        row.undo = nil
        store(row)
        events.append(Event(info: info(film), at: now, mode: mode, slot: nil, action: .undo))
        prune(now: now)
        return true
    }

    private func ensureEntry(_ film: TonightFilm) -> Entry {
        if var existing = entry(film) {
            existing.film = film
            existing.info.aliases = Array(Set(existing.info.aliases).union(film.identityKeys)).sorted()
            return existing
        }
        return Entry(info: info(film), film: film, state: State(), undo: nil)
    }

    private mutating func store(_ row: Entry) {
        if let existing = entries.first(where: { $0.value.info.key == row.info.key })?.key, existing != row.info.key {
            entries[existing] = nil
        }
        entries[row.info.key] = row
    }

    /// Bounded history: 10,000 events within 180 days, the last five seed sets
    /// within 60 days. Permanent marks and saved films outlive the bounds.
    private mutating func prune(now: Date) {
        events = Array(events.filter { $0.at >= now.addingTimeInterval(-180 * Self.day) }.suffix(10_000))
        seeds = Array(seeds.filter { $0.at >= now.addingTimeInterval(-60 * Self.day) }.suffix(5))
        let horizon = now.addingTimeInterval(-180 * Self.day)
        entries = entries.filter { _, entry in
            let state = entry.state
            if state.never || state.seen || state.saved != nil || state.rating != nil || state.quickSkippedAt != nil { return true }
            return (state.laterAt ?? .distantPast) >= horizon || (entry.undo?.at ?? .distantPast) >= horizon
        }
    }
}

/// Read-only lookups over a memory snapshot, keyed by identity alias.
///
/// The engine asks about every film in the library; scanning the entries and
/// events for each of tens of thousands of films would be quadratic, so a run
/// builds this once and queries by the film's precomputed identity keys.
public struct TonightMemoryIndex: Sendable {
    private let entryByAlias: [String: TonightMemory.Entry]
    private let shownByAlias: [String: (main: Date?, alternative: Date?)]
    private let usedSeedKeys: Set<String>

    public init(_ memory: TonightMemory) {
        var entries: [String: TonightMemory.Entry] = [:]
        for entry in memory.entries.values {
            for alias in entry.info.aliases { entries[alias] = entry }
            entries[entry.info.key] = entry
        }
        var shown: [String: (main: Date?, alternative: Date?)] = [:]
        for event in memory.events {
            guard let slot = event.slot else { continue }
            for alias in event.info.aliases {
                var stats = shown[alias] ?? (nil, nil)
                if slot == .main { stats.main = max(stats.main ?? event.at, event.at) }
                if slot == .alternative { stats.alternative = max(stats.alternative ?? event.at, event.at) }
                shown[alias] = stats
            }
        }
        entryByAlias = entries
        shownByAlias = shown
        usedSeedKeys = Set(memory.seeds.flatMap(\.keys))
    }

    public func entry(_ keys: Set<String>) -> TonightMemory.Entry? {
        for key in keys { if let entry = entryByAlias[key] { return entry } }
        return nil
    }

    public func isNever(_ keys: Set<String>) -> Bool { entry(keys)?.state.never ?? false }
    public func isMarkedSeen(_ keys: Set<String>) -> Bool { entry(keys)?.state.seen ?? false }
    public func saved(_ keys: Set<String>) -> TonightMemory.Saved? { entry(keys)?.state.saved }
    public func localRating(_ keys: Set<String>) -> Double? { entry(keys)?.state.rating?.value }
    public func quickSkipped(_ keys: Set<String>) -> Bool { entry(keys)?.state.quickSkippedAt != nil }
    public func seedUsed(_ keys: Set<String>) -> Bool { !keys.isDisjoint(with: usedSeedKeys) }

    private func shown(_ keys: Set<String>) -> (main: Date?, alternative: Date?) {
        var main: Date?, alternative: Date?
        for key in keys {
            guard let stats = shownByAlias[key] else { continue }
            if let date = stats.main { main = max(main ?? date, date) }
            if let date = stats.alternative { alternative = max(alternative ?? date, date) }
        }
        return (main, alternative)
    }

    public func penalty(_ keys: Set<String>, now: Date) -> Double {
        func age(_ date: Date?) -> Double {
            guard let date else { return .infinity }
            return max(0, now.timeIntervalSince(date) / TonightMemory.day)
        }
        let stats = shown(keys)
        let main = age(stats.main), alternative = age(stats.alternative)
        var penalty = max(main < 14 ? 12 : max(0, 12 * (60 - main) / 46), max(0, 3 * (1 - alternative / 7)))
        if let laterAt = entry(keys)?.state.laterAt {
            penalty = max(penalty, 18 * max(0, 1 - max(0, now.timeIntervalSince(laterAt)) / (60 * TonightMemory.day)))
        }
        return penalty
    }

    public func recentlyShown(_ keys: Set<String>, days: Double = 14, now: Date) -> Bool {
        let stats = shown(keys)
        guard let latest = [stats.main, stats.alternative].compactMap({ $0 }).max() else { return false }
        return latest >= now.addingTimeInterval(-days * TonightMemory.day)
    }
}
