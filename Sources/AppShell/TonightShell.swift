#if canImport(SwiftUI)
import CoreModels
import FeatureTonightCore
import Foundation
import TraktService

/// Composes "Tonight" from the app's own pieces: the profile's server
/// accounts, its Trakt connection and Plozz's shared watchlist.
enum TonightShell {
    @MainActor
    static func makeModel(
        accounts: [ResolvedAccount],
        profileNamespace: String?,
        trakt: TraktTasteService?,
        isKidsProfile: Bool,
        watchlistHandler: (any MediaItemActionHandling)?
    ) -> TonightModel {
        let accountSources = accounts.map { TonightAccountSource(accountID: $0.account.id, provider: $0.provider) }
        let resolve: @Sendable (TonightLocation) async -> MediaItem? = { location in
            guard let account = accounts.first(where: { $0.account.id == location.accountID }),
                  var item = try? await account.provider.item(id: location.itemID) else { return nil }
            if item.sourceAccountID == nil { item.sourceAccountID = location.accountID }
            return item
        }
        // A Kids Profile sees only what its servers offer: no external
        // candidates, and every pick must be playable here.
        var sources: [any TonightCandidateSource] = []
        if !isKidsProfile, let trakt { sources.append(TraktTonightSource(trakt: trakt)) }
        let isAllowed: @Sendable (TonightFilm) -> Bool
        if isKidsProfile {
            isAllowed = { film in film.isOnServer }
        } else {
            isAllowed = { _ in true }
        }
        // Claude curates when the build carries a configuration. A Kids Profile's
        // history is never sent to it.
        let reranker: (any TonightReranker)? = isKidsProfile ? nil : ClaudeTonightConfig.resolved().map {
            ClaudeTonightReranker(config: $0, language: Locale.preferredLanguages.first ?? Locale.current.identifier)
        }
        let engine = TonightEngine(sources: sources, reranker: reranker, isAllowed: isAllowed)
        return TonightModel(
            engine: engine,
            store: TonightFileStore(profileNamespace: profileNamespace),
            loadLibrary: { await TonightLibraryLoader().load(accounts: accountSources, trakt: trakt) },
            watchlist: watchlistHandler.map { TonightSharedWatchlist(handler: TonightHandlerBox($0), resolve: resolve) },
            resolveItem: resolve
        )
    }
}

/// Carries the main-actor watchlist handler into a `Sendable` writer. Only
/// ever dereferenced on the main actor.
final class TonightHandlerBox: @unchecked Sendable {
    @MainActor private(set) weak var handler: (any MediaItemActionHandling)?

    @MainActor init(_ handler: any MediaItemActionHandling) {
        self.handler = handler
    }
}

/// "Save" goes through Plozz's shared watchlist, which owns syncing to Trakt
/// and the servers. An entry that already exists is never touched.
struct TonightSharedWatchlist: TonightWatchlistWriting {
    let handler: TonightHandlerBox
    let resolve: @Sendable (TonightLocation) async -> MediaItem?

    func add(_ film: TonightFilm) async throws -> Bool {
        guard let location = film.locations.first, let item = await resolve(location) else { return false }
        return await MainActor.run {
            guard let handler = handler.handler, !handler.isWatchlisted(item) else { return false }
            handler.perform(.addToWatchlist, on: item, context: .none)
            return true
        }
    }

    func remove(_ film: TonightFilm) async throws {
        guard let location = film.locations.first, let item = await resolve(location) else { return }
        await MainActor.run {
            guard let handler = handler.handler, handler.isWatchlisted(item) else { return }
            handler.perform(.removeFromWatchlist, on: item, context: .none)
        }
    }
}
#endif
