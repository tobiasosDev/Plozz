#if canImport(SwiftUI)
import CoreUI
import CoreModels
import FeatureHomeCore
import FeatureTonightCore
import TraktService

/// The Home tab's session-scoped handles: things owned **above** the tab so
/// that SwiftUI churn inside the tab tree cannot destroy them.
///
/// Both members are here for the same reason. A `TabView` re-hosts its tabs
/// when its content changes, which discards each tab's `@State` — measured on
/// device as happening on the second body pass of every launch, triggered by
/// whatever unrelated observable changed first (music availability one launch,
/// theme-music settings the next). Anything the Home tab must keep across that
/// — its view model, with a four-account load already seconds in — has to be
/// owned by a stabler view and handed down.
///
/// Grouping them also keeps `HomeTab`'s already-wide initializer from growing;
/// past a certain arity the Swift type-checker gives up on the `TabView` body
/// entirely.
struct HomeTabRuntime {
    /// Holds the Home view model across tab re-hosting, rebuilt only when
    /// ``scopeKey`` changes.
    let homeViewModel: LazyViewState<HomeViewModel>
    /// Identity of the account/profile scope the view model belongs to.
    let scopeKey: String
    @MainActor var continueWatchingForDetail: [MediaItem] {
        homeViewModel.existingValue(forKey: scopeKey)?.continueWatchingForDetail ?? []
    }
    /// A Top Shelf deep link awaiting routing. Carried by reference so no view
    /// in the tab tree becomes a subscriber of it.
    let pendingPlay: PendingPlayRequest
    /// The capture rig's screen requests, carried by reference for the same
    /// reason as ``pendingPlay``. Never populated outside DEBUG.
    let screenshotDirector: ScreenshotDirector
    /// "Tonight" state owned above the tab tree, rebuilt per profile scope.
    let tonight: TonightRuntime
}

/// What the "Tonight" destination needs from the app, resolved per profile.
struct TonightRuntime {
    /// Holds the screen model across tab re-hosting, rebuilt only when the
    /// home scope (profile, accounts, watching-as identity) changes.
    let model: LazyViewState<TonightModel>
    /// The active profile's Trakt connection, captured when the model is built.
    let makeTrakt: @MainActor () -> TraktTasteService?
    /// Kids Profiles never see films from outside their servers, matching
    /// External Home Discovery being off for them.
    let isKidsProfile: Bool
    /// Persistent account and Plex-user identity for the library cache.
    let cacheScopeKey: String
    /// The live home scope, to drop writes that resolve after a profile switch.
    let currentScopeKey: @MainActor () -> String
}
#endif
