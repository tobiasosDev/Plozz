import CoreModels
import Foundation
import Observation

/// Adds and removes first watches on the viewer's watchlist for "Save".
public protocol TonightWatchlistWriting: Sendable {
    /// - Returns: whether this call created the entry (an existing entry is left alone).
    func add(_ film: TonightFilm) async throws -> Bool
    func remove(_ film: TonightFilm) async throws
}

/// The "Tonight" screen's state: the request, the picks, decisions and the
/// quick rating round. All ranking runs in ``TonightEngine``; this type only
/// sequences it and keeps the profile's memory saved.
@MainActor
@Observable
public final class TonightModel {
    public enum Phase: Equatable, Sendable {
        /// Nothing loaded yet.
        case idle
        /// Reading the library for the first time; there is nothing to show yet.
        case loadingLibrary
        case choosing
        case ready
        /// No movie library and no Trakt history to reason with.
        case empty
    }

    public struct LibraryStats: Equatable, Sendable {
        public var films: Int
        public var seen: Int
        public var rated: Int
        public var unreachableServers: Int
        public var traktFailed: Bool
    }

    public private(set) var phase: Phase = .idle
    public private(set) var request = TonightRequest()
    public private(set) var result: TonightResult?
    public private(set) var selectedIndex = 0
    public private(set) var libraryStats: LibraryStats?
    public private(set) var isRefreshingLibrary = false
    /// Claude is choosing; the rule picks are already on screen.
    public private(set) var isCurating = false
    /// History films offered as the "like …" reference, best first.
    public private(set) var references: [TonightFilm] = []
    /// The last decision, so the screen can offer Undo.
    public private(set) var lastDecision: (action: TonightAction, film: TonightFilm)?
    public private(set) var quickQueue: [TonightFilm] = []
    public private(set) var quickStats = TonightQuickRate.Stats(ratedCount: 0, openCount: 0)

    @ObservationIgnored private var memory = TonightMemory()
    @ObservationIgnored private var library: [TonightFilm] = []
    @ObservationIgnored private var generation = 0
    /// Bumped by every decision, so a late curated result never overwrites one.
    @ObservationIgnored private var decisionRevision = 0
    @ObservationIgnored private let engine: TonightEngine
    @ObservationIgnored private let store: any TonightStoring
    @ObservationIgnored private let loadLibrary: @Sendable () async -> TonightLibrarySnapshot
    @ObservationIgnored private let watchlist: (any TonightWatchlistWriting)?
    @ObservationIgnored private let resolveItem: @Sendable (TonightLocation) async -> MediaItem?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let maxLibraryAge: TimeInterval
    @ObservationIgnored private let libraryScope: String?

    public init(
        engine: TonightEngine,
        store: any TonightStoring,
        loadLibrary: @escaping @Sendable () async -> TonightLibrarySnapshot,
        watchlist: (any TonightWatchlistWriting)? = nil,
        resolveItem: @escaping @Sendable (TonightLocation) async -> MediaItem?,
        maxLibraryAge: TimeInterval = 6 * 3600,
        libraryScope: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.libraryScope = libraryScope
        self.engine = engine
        self.store = store
        self.loadLibrary = loadLibrary
        self.watchlist = watchlist
        self.resolveItem = resolveItem
        self.maxLibraryAge = maxLibraryAge
        self.now = now
    }

    public var picks: [TonightPick] { result?.picks ?? [] }

    public var selectedPick: TonightPick? {
        picks.indices.contains(selectedIndex) ? picks[selectedIndex] : picks.first
    }

    // MARK: - Lifecycle

    /// Loads the saved state and cached library, shows picks, and refreshes the
    /// library in the background when the cache is stale.
    public func start() async {
        guard phase == .idle else { return }
        let state = await store.load()
        memory = state.memory
        request = state.request
        if let cached = await store.loadLibrary(), cached.scope == libraryScope {
            apply(cached)
            await recommend()
            if now().timeIntervalSince(cached.builtAt) > maxLibraryAge { await refreshLibrary() }
        } else {
            phase = .loadingLibrary
            await refreshLibrary()
        }
    }

    /// Rereads every server and Trakt, then chooses again.
    public func refreshLibrary() async {
        guard !isRefreshingLibrary else { return }
        isRefreshingLibrary = true
        var snapshot = await loadLibrary()
        snapshot.scope = libraryScope
        isRefreshingLibrary = false
        // An empty scan with failures must not replace a good cache.
        if snapshot.films.isEmpty, !library.isEmpty, !snapshot.failedAccountIDs.isEmpty || snapshot.traktFailed { return }
        await store.saveLibrary(snapshot)
        await engine.invalidate()
        apply(snapshot)
        await recommend()
    }

    private func apply(_ snapshot: TonightLibrarySnapshot) {
        library = snapshot.films
        libraryStats = LibraryStats(
            films: snapshot.films.count,
            seen: snapshot.seenCount,
            rated: snapshot.ratedCount,
            unreachableServers: snapshot.failedAccountIDs.count,
            traktFailed: snapshot.traktFailed
        )
        references = snapshot.films
            .filter { $0.isSeen && (($0.effectiveRating ?? 0) >= 7 || $0.plays >= 2 || $0.isFavorite) }
            .sorted { a, b in
                let ra = a.effectiveRating ?? (a.isFavorite ? 9 : 0), rb = b.effectiveRating ?? (b.isFavorite ? 9 : 0)
                return ra != rb ? ra > rb : a.plays != b.plays ? a.plays > b.plays : a.title < b.title
            }
            .prefix(40)
            .map { $0 }
        refreshQuickRound()
    }

    // MARK: - Request

    public func setMode(_ mode: TonightMode) async { await update { $0.mode = mode } }
    public func setGenre(_ genre: TonightGenre?) async { await update { $0.genre = genre } }
    public func setReference(_ film: TonightFilm?) async { await update { $0.like = film.map(TonightFilmRef.init) } }
    public func setMood(_ mood: String?) async {
        let trimmed = mood?.trimmingCharacters(in: .whitespacesAndNewlines)
        await update { $0.mood = trimmed?.isEmpty == false ? String(trimmed!.prefix(200)) : nil }
    }
    public func setMaxRuntime(_ minutes: Int?) async { await update { $0.maxRuntime = minutes } }
    public func setOnlyOnServers(_ only: Bool) async { await update { $0.onlyOnServers = only } }

    private func update(_ change: (inout TonightRequest) -> Void) async {
        var next = request
        change(&next)
        next.exclude = []
        guard next != request else { return }
        request = next
        await persist()
        await recommend()
    }

    /// Chooses again for the current request.
    public func recommend() async {
        guard !library.isEmpty else {
            phase = isRefreshingLibrary ? .loadingLibrary : .empty
            return
        }
        generation += 1
        let mine = generation
        isCurating = false
        if result == nil { phase = .choosing }
        var before = memory
        var revision = decisionRevision
        // Rules first, instantly; the curator's pass replaces them when it lands.
        var output = await engine.recommend(request, library: library, memory: before, now: now(), curate: false)
        guard mine == generation else { return }
        // A decision or quick rating landed while the pass ran: choose again from
        // the current memory rather than overwrite it.
        for _ in 0..<3 where revision != decisionRevision {
            before = memory
            revision = decisionRevision
            output = await engine.recommend(request, library: library, memory: before, now: now(), curate: false)
            guard mine == generation else { return }
        }
        guard revision == decisionRevision else { return }
        memory = output.memory
        result = output.result
        selectedIndex = 0
        phase = .ready
        await persist()
        guard engine.canCurate, !output.result.picks.isEmpty else { return }
        isCurating = true
        let curated = await engine.recommend(request, library: library, memory: before, now: now(), curate: true)
        guard mine == generation else { return }
        isCurating = false
        guard revision == decisionRevision, curated.result.chosenByReranker else { return }
        let selectedKey = selectedPick?.film.key
        memory = curated.memory
        result = curated.result
        selectedIndex = selectedKey.flatMap { key in curated.result.picks.firstIndex { $0.film.key == key } } ?? 0
        await persist()
    }

    /// Shows the next page, excluding everything already shown.
    public func showMore() async {
        var next = request
        next.exclude = Array(Set(request.exclude + picks.flatMap(\.film.identityKeys))).sorted()
        request = next
        await recommend()
    }

    public func select(_ index: Int) {
        guard picks.indices.contains(index) else { return }
        selectedIndex = index
    }

    // MARK: - Decisions

    /// Applies Save, Later, Never or Seen. Later, Never and Seen take the film
    /// off the screen; Save keeps it.
    public func decide(_ action: TonightAction, on pick: TonightPick) async {
        guard action != .undo, action != .play else { return }
        var watchlistAdded = false
        if action == .save, request.mode == .firstWatch, let watchlist, !pick.film.onWatchlist,
           memory.saved(pick.film)?.watchlistAdded != true {
            watchlistAdded = (try? await watchlist.add(pick.film)) ?? false
        }
        guard memory.apply(action, to: pick.film, mode: request.mode, watchlistAdded: watchlistAdded, now: now()) else { return }
        decisionRevision += 1
        lastDecision = (action, pick.film)
        if action != .save, var current = result {
            current.picks.removeAll { $0.film.key == pick.film.key }
            result = current
            selectedIndex = min(selectedIndex, max(0, current.picks.count - 1))
        }
        refreshQuickRound()
        await persist()
    }

    /// Takes back the last decision and brings the film back.
    public func undoLastDecision() async {
        guard let decision = lastDecision else { return }
        let (action, film) = (decision.action, decision.film)
        if memory.undoRemovesWatchlistEntry(film), let watchlist {
            try? await watchlist.remove(film)
        }
        memory.apply(.undo, to: film, mode: request.mode, now: now())
        decisionRevision += 1
        lastDecision = nil
        if action != .save, var current = result, !current.picks.contains(where: { $0.film.key == film.key }) {
            current.picks.insert(TonightPick(film: film, reason: .matchesFilters, evidence: []), at: min(selectedIndex, current.picks.count))
            result = current
        }
        refreshQuickRound()
        await persist()
    }

    /// The playable server item for a pick, preferring the first location.
    public func playableItem(for pick: TonightPick) async -> MediaItem? {
        for location in pick.film.locations {
            if let item = await resolveItem(location) { return item }
        }
        return nil
    }

    // MARK: - Quick round

    public func rate(_ film: TonightFilm, _ rating: TonightQuickRating?) async {
        TonightQuickRate.apply(rating, to: film, memory: &memory, now: now())
        decisionRevision += 1
        refreshQuickRound()
        await persist()
    }

    private func refreshQuickRound() {
        quickQueue = TonightQuickRate.queue(library, memory: memory)
        quickStats = TonightQuickRate.stats(library, memory: memory)
    }

    /// Forgets every decision and quick rating of this profile.
    public func resetDecisions() async {
        memory = TonightMemory()
        decisionRevision += 1
        lastDecision = nil
        refreshQuickRound()
        await persist()
        await recommend()
    }

    private func persist() async {
        await store.save(TonightPersistedState(memory: memory, request: request))
    }
}
