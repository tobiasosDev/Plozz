#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// What a `MediaItem.sourceAccountID` names: the provider whose brand mark
/// badges the item and the server name it reads as ("Jellyfin · Wohnzimmer").
public struct MediaSourceIdentity: Hashable, Sendable {
    public var provider: ProviderKind
    public var serverName: String  // l10n:content — user-chosen or server-reported name

    public init(provider: ProviderKind, serverName: String) {
        self.provider = provider
        self.serverName = serverName
    }
}

private struct PlozzMediaSourceIdentitiesKey: EnvironmentKey {
    static let defaultValue: [String: MediaSourceIdentity] = [:]
}

public extension EnvironmentValues {
    /// Every connected account's identity, keyed by account ID. Injected once at
    /// the root so a card or hero can name its server without each screen
    /// threading the account list through; it only changes when an account does.
    var plozzMediaSourceIdentities: [String: MediaSourceIdentity] {
        get { self[PlozzMediaSourceIdentitiesKey.self] }
        set { self[PlozzMediaSourceIdentitiesKey.self] = newValue }
    }
}

public extension Dictionary where Key == String, Value == MediaSourceIdentity {
    /// The identity of the server an item plays from, or `nil` for a source the
    /// app has no account for (a share, a merged item without a primary).
    func identity(for item: MediaItem) -> MediaSourceIdentity? {
        item.sourceAccountID.flatMap { self[$0] }
    }
}
#endif
