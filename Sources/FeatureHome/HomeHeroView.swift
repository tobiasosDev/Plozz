#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import HeroUI
import MetadataKit

/// The Home **hero** carousel: a cinematic, rotating spotlight at the top of
/// Home, functionally near-identical to the Apple TV app. Each slide shows a
/// full-bleed backdrop plus the title logo, metadata and Play / More Info /
/// Watchlist actions.
///
/// Content is whatever the ``HeroCurator`` produced for the user's per-profile
/// ``HeroSettings`` (Continue Watching, Random, Watchlist and Featured discovery).
/// The carousel auto-advances on a timer and pages on the remote
/// per ``HeroCarouselFocus`` (right at the last button advances; left at the
/// first button steps back / escapes to the sidebar).
///
/// The backdrop transition between slides is handled by ``HomeHeroBackdrop``,
/// which performs the Apple TV **parallax wipe imperatively in UIKit (Core
/// Animation)** rather than with any SwiftUI animation — the fix for the
/// long-standing, intermittent wrong-order wipe. Paging is therefore just a state
/// change here (`index` + `lastPageForward`); the backdrop reacts to the fronted
/// slide's id/URLs and entering direction on its own.
struct HomeHeroView: View {
    @Environment(\.plozzAppTextScale) private var appTextScale
    private var textScale: CGFloat { PlozzTypography.scale(local: settings.textSize.scale, app: appTextScale) }
    let items: [MediaItem]
    let settings: HeroSettings
    let backgroundSettings: HeroBackgroundSettings
    let trailerController: HeroTrailerController
    let trailerResolver: HeroTrailerResolving
    let isFrontmost: Bool
    let spoilerSettings: SpoilerSettings
    let navigationStyle: NavigationStyle
    /// Account-scoped ids of every title currently on the user's watchlist (built
    /// from the loaded Watchlist row). Lets the hero reflect the *series'*
    /// watchlist state on an episode/season slide — whose own `MediaItem` carries
    /// the episode's favourite flag, not the parent show's. Empty = treat all as
    /// not-watchlisted (the safe default).
    var watchlistedKeys: Set<String> = []
    /// Fraction of the screen height the hero occupies. Full-screen, matching the
    /// Apple TV app: the backdrop fills the display top-to-bottom and the Continue
    /// Watching row is pulled up to peek just below the paging dots (see
    /// `HomeView.heroRowOverlap`), rather than the hero being shortened.
    var heroHeightFraction: CGFloat = 1.0
    /// The Home focus scope (owned by `HomeView`, spanning the hero *and* the
    /// rows). The hero's Play button is marked `prefersDefaultFocus` in this
    /// scope so initial focus lands on the hero — not a Continue Watching card —
    /// without the hero having to programmatically grab (and visibly steal) it.
    var focusScope: Namespace.ID
    let onSelect: (MediaItem) -> Void
    let onPlay: (MediaItem) -> Void
    /// Whether Seerr is currently connected. Gates the featured **Request** CTA:
    /// a not-owned featured title only offers Request (or a request/download
    /// status) when this is `true`; otherwise the slide shows with no primary
    /// button (Play/Resume for ordinary library items is unaffected).
    var seerConnected: Bool = false
    var canRequestDiscoveryItem: @MainActor (MediaItem) -> Bool = { _ in true }
    /// One-tap request for a not-owned featured title. Returns the title's new
    /// availability so the pill can flip to Requested/Downloading immediately, or
    /// `nil` if the request failed. `nil` closure disables requesting entirely.
    var onRequest: ((MediaItem) async -> MediaAvailabilityStatus?)? = nil
    /// Loads Seerr season-request availability for a featured **series**, so
    /// activating Request can present a season picker instead of requesting the
    /// whole show. `nil` (or no season content) falls back to a whole-title request.
    var requestAvailability: ((MediaItem) async -> MediaRequestAvailability?)? = nil
    /// Requests the chosen `seasons` of a featured series; returns the title's new
    /// availability (to flip the pill) or `nil` on failure.
    var onRequestSeasons: ((MediaItem, [Int]) async -> MediaAvailabilityStatus?)? = nil
    /// Fired when the hero *gains* focus (the user moved focus back up onto it),
    /// so Home can restore the full-screen hero and replay the enter transition.
    /// Not fired for interior button-to-button moves.
    var onFocusGained: () -> Void = {}
    /// Fired when focus leaves the hero downward, so Home can start the recede
    /// together with the focus engine's scroll.
    var onFocusLeftDown: () -> Void = {}
    /// Reports the slides on screen, so a background curation can fold new media
    /// in without ever displacing what the viewer is looking at (see
    /// ``HeroLiveMerge``). Fires on appearance and on every page.
    var onPinnedItemsChanged: (Set<String>) -> Void = { _ in }
    var onTrailerReturnItemChanged: (String?) -> Void = { _ in }
    var onItemExposed: (MediaItem) -> Void = { _ in }
    var exposureScopeID: ObjectIdentifier?
    /// Leaf-owned recede state. Passing the model reference keeps the high-frequency
    /// animation state out of `HomeView`'s observation surface, so moving between
    /// the hero and Continue Watching no longer invalidates every Home row.
    let recedeModel: HomeHeroRecedeModel
    var showcaseSuspended = false
    private var pausedForRows: Bool { receded || showcaseSuspended }
    /// Whether the hero is *receded*: the user has moved focus down onto the
    /// Continue Watching row. When true the content column (logo / metadata /
    /// action buttons / paging dots) lifts up via a transform and the full-bleed,
    /// screen-pinned backdrop translates up on its own slower track, so the
    /// Continue Watching row settles into a centered reading position — the Apple
    /// TV move. Driven by `HomeView` off the page scroll offset (the tvOS focus
    /// engine scrolls the page the instant focus lands on a lower row); the lifts
    /// here are `.offset` transforms, not layout changes, so the animation never
    /// fights the focus engine and never re-runs layout of the rows below.
    private var receded: Bool { recedeModel.isReceded }

    /// Extra upward lift (points) applied to the hero's CONTENT column (logo,
    /// metadata, action buttons, paging dots) when the hero recedes, so the
    /// buttons/dots rise toward the top of the screen — the Apple TV look where
    /// the artwork recedes and the controls compress up high. Applied as an
    /// `.offset` transform; animates with the recede. Tunable.
    private static let recedeContentLift: CGFloat = 170
    /// Total upward travel (points) applied to the backdrop artwork when the hero
    /// recedes. The backdrop is screen-pinned (see `heroBackdrop`), so this is its
    /// absolute rise — independent of the content lift and of the page scroll. Kept
    /// well below the focus engine's page scroll (~480pt) so the artwork keeps its
    /// parallax lag but does NOT fly up: its melted bottom edge stays below the
    /// paging dots as you navigate down. The slow 1.6s glide (see HomeHeroBackdrop)
    /// makes it lag the scroll. Tunable.
    private static let recedeBackdropRise: CGFloat = 240

    /// The app-installed action handler — the SAME one the detail hero and the
    /// long-press context menu use — so the hero's Watchlist button is offered
    /// only when the item's provider supports it and its mutation fans out
    /// exactly like everywhere else.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    @Environment(\.plozzShowsContentRatings) private var showsContentRatings
    /// How far the navigation chrome has inset this page's content, so the hero's
    /// full-bleed artwork can cancel it. `0` under the native tab styles.
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset
    @Environment(\.mediaItemActionContext) private var actionContext
    @Environment(\.plozzPinnedSidebarInteraction) private var pinnedSidebarInteraction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.seasonRequestContextID) private var seasonRequestContextID
    @Environment(\.plozzArtworkPolicy) var artworkPolicy

    /// The index of the slide currently fronted.
    /// Internal (not private) so the artwork extension in a sibling file can center
    /// its preload window on the current slide; still owned only by this view.
    @State var index: Int = 0
    /// Direction of the most recent page, handed to the backdrop so its parallax
    /// wipe enters from the correct edge (`true` = forward/right, `false` =
    /// backward/left). Set in `page(to:forward:)` alongside `index` so the backdrop
    /// receives the new slide id and its entering direction in the same update.
    @State private var lastPageForward: Bool = true
    /// Neighbour slide models from the last body pass; see ``foregroundNeighbours(for:)``.
    @State private var neighbourModels = HeroNeighbourModelCache()
    /// Optimistic per-item availability overrides applied the instant the user
    /// taps Request, so the pill flips to Requested/Downloading without waiting
    /// for the next trending refresh. Keyed by `MediaItem.id`; reconciled with the
    /// server's returned status when the request completes.
    @State private var requestOverrides: [String: MediaAvailabilityStatus] = [:]
    /// The featured series whose season picker (a native confirmation dialog) is
    /// presented, plus its loaded availability (nil = hidden).
    @State private var seasonPickerItem: MediaItem?
    @State private var seasonPickerAvailability: MediaRequestAvailability?
    @State private var seasonRequestStates: [String: SeasonRequestState] = [:]
    @State private var seasonRequestContext: String?
    @State private var seasonRequestingItems: Set<String> = []
    @State private var seasonLookupFailures: Set<String> = []
    @State private var seasonLookupIDs: [String: UUID] = [:]
    @State private var seasonRefreshToken = 0
    @State private var showingSeasonLookupFailure = false
    /// Whether one of the hero's pills holds focus. Written only when focus
    /// enters or leaves the hero (``HeroForegroundEvents/focusChanged``); moving
    /// between pills is UIKit's business and never invalidates this view.
    @State private var heroFocused = false
    @FocusState private var foregroundFocused: Bool
    /// Bumped on every manual page so the auto-advance `.task` restarts its dwell
    /// from the fresh slide instead of firing early.
    @State private var advanceToken = 0
    /// Timestamp marking when the current auto-advance dwell began. Reset every
    /// time the dwell (re)starts (slide change or manual page) so the active
    /// paging dot can render a live progress fill counting down to the next page.
    /// On resume from a pause it is shifted forward by the paused duration, so the
    /// countdown continues from where it froze rather than restarting.
    @State private var dwellStart = Date()
    /// Non-`nil` while the auto-advance is paused because the user is interacting
    /// with the remote. Holds the instant the pause began so the progress gauge
    /// freezes there and the resume can compute how long it was held.
    @State private var pausedAt: Date?
    /// Bumped whenever the auto-advance pauses or resumes so the fire `.task`
    /// re-keys: a pause restarts it into its no-op (paused) branch, a resume
    /// restarts it to sleep for the remaining dwell. Slide changes / manual pages
    /// go through `advanceToken`; this is purely the pause/resume lifecycle.
    @State private var runEpoch = 0
    /// Resolved fast trailer for the fronted item. `nil` keeps today's static
    /// image/timer behavior.
    @State private var activeTrailerSource: HeroTrailerSource?
    @State private var activeTrailerDuration: TimeInterval = 0
    /// Trailer reached its end while interaction/recede blocked automatic paging.
    /// The video and gauge are allowed to finish; paging occurs once interaction
    /// protection is released.
    @State private var pendingTrailerAdvance = false
    /// Separate from interaction `pausedAt`: only transport-level pauses (recede
    /// or full-screen playback) freeze trailer/static progress.
    @State private var trailerPausedAt: Date?
    /// Per-carousel memo so wrapping back to a slide never re-runs provider
    /// trailer/playback resolution. Bounded by the curated item set (max 20).
    @State private var trailerSourceCache: [String: HeroTrailerSource] = [:]
    @State private var noFastTrailerIDs: Set<String> = []
    /// Drives the first-appearance fade-in, matching the detail hero's polish.
    /// Air-schedule badges for the hero's series slides. Populated cache-first, so
    /// a returning viewer sees them on the first frame and only the slide actually
    /// on screen ever costs a request.
    @State private var schedules = HeroScheduleLines()
    @State private var heroVisible = false
    /// Optimistic watchlist state the user just toggled from the hero, keyed by
    /// ``watchlistKey(accountID:itemID:)``. Flips the button instantly on press
    /// (the loaded Watchlist row can lag, especially when adding a *series* from
    /// an episode slide) and self-heals when the real data reloads.
    @State private var watchlistOverrides: [String: Bool] = [:]
    /// Bumped on every page and every re-seated slide, so per-slide work (the
    /// artwork warm window) restarts for the slide now in front.
    @State private var slideToken = 0
    /// Changes only when the curated hero identity set changes. Drives the
    /// low-resolution all-slide preview warm without restarting it on every page.
    @State private var artworkSetToken = 0

    /// Pending "resume auto-advance" work, scheduled after each remote input and
    /// cancelled/rescheduled by the next one, so the carousel only starts counting
    /// down again once the user has been idle for ``resumeAfterIdle`` seconds.
    @State private var resumeWork: DispatchWorkItem?
    /// How long the user must be idle after their last remote input before the
    /// auto-advance resumes counting down toward the next page.
    private static let resumeAfterIdle: Double = 2.5

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.heroArtworkDisplayState) private var displayedArtwork
    /// Read so the imperative UIKit foreground's plain-`String` title can be
    /// resolved with the in-app language override rather than the device's
    /// system locale. `HomeHeroView`'s body re-evaluates whenever this
    /// environment value changes (see `AppLanguageScope`), so re-resolving here
    /// on every call — never cached — tracks a live language switch exactly the
    /// way `Text` does; it is not the eager, resolve-once-and-freeze pattern the
    /// l10n guard forbids elsewhere.
    @Environment(\.locale) private var locale
    @Environment(\.plozzMediaSourceIdentities) private var mediaSourceIdentities

    private var current: MediaItem? {
        guard items.indices.contains(index) else { return items.first }
        return items[index]
    }

    /// Legibility scrim tone — dark in dark mode, light in light mode (matching
    /// the detail hero).
    private var scrimTone: Color { colorScheme == .dark ? .black : .white }

    /// The action buttons the current slide offers, in visual (left-to-right)
    /// order. The leading button is the CTA that fits the slide's state — Play,
    /// Request, or a request/download **status** pill — or nothing for a
    /// not-owned featured title while Seerr is disconnected (the slide still
    /// shows, just without a primary button). `.moreInfo` is always present;
    /// `.watchlist` whenever a watchlist toggle applies to the slide's target.
    private func buttons(for item: MediaItem) -> [HeroButton] {
        var result: [HeroButton] = []
        let primary = primaryButton(for: item)
        if primary == .play {
            result.append(.play)
            if watchlistAction(for: item) != nil {
                result.append(.watchlist)
            }
            result.append(.moreInfo)
        } else if let primary {
            // A requestable / in-flight title: the Request (or download-status) pill
            // is the leading, bright primary CTA; More Info steps down to a plain
            // info icon after it — matching the detail hero and the iOS hero.
            result.append(primary)
            if watchlistAction(for: item) != nil {
                result.append(.watchlist)
            }
            result.append(.moreInfo)
        } else {
            // Nothing actionable (unavailable / Seerr disconnected): More Info is the
            // only thing to do, so it stays the labelled, white primary action.
            result.append(.moreInfo)
            if watchlistAction(for: item) != nil {
                result.append(.watchlist)
            }
        }
        // DEBUG (env-gated by PLZHFOCUS_ALTBUTTONS): force the button COUNT to
        // vary between slides so the count-changing page transitions that trigger
        // the focus drop can be reproduced on demand even when every slide would
        // otherwise be 4 buttons. Deterministic per item id (a stable byte-sum
        // parity), so a given slide always has the same count and the focused
        // pill's clamping stays consistent as you page back and forth. Only removes the
        // Watchlist button (never fabricates one), so `activateSelected()` can
        // never dispatch a bogus action. No effect unless the flag is set.
        if HeroFocusDiagnostics.forceAlternatingButtonCounts {
            let dropWatchlist = item.id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0
            if dropWatchlist, let wl = result.firstIndex(of: .watchlist) {
                result.remove(at: wl)
            }
        }
        return result
    }

    /// The effective hero CTA for `item`, applying any optimistic post-tap
    /// availability override so the pill reflects a just-sent request instantly.
    private func heroCTA(for item: MediaItem) -> HeroCTA {
        MediaItem.heroCTA(
            availability: requestOverrides[item.id] ?? item.availability,
            downloadProgress: item.downloadProgress,
            hasValidatedPlayableSource: item.hasPlayableLibraryTarget(),
            seerConnected: seerConnected && canRequestDiscoveryItem(item),
            releaseDate: item.releaseDate,
            hasDownloadActivity: item.hasRequestDownloadActivity == true
        )
    }

    /// The leading primary button for `item`, or `nil` when the slide offers no
    /// primary action (a not-owned featured title with Seerr disconnected).
    private func primaryButton(for item: MediaItem) -> HeroButton? {
        if item.kind == .series, seerConnected, canRequestDiscoveryItem(item), onRequestSeasons != nil,
           !item.hasPlayableLibraryTarget() {
            return .request
        }
        switch heroCTA(for: item) {
        case .play: return .play
        case .request: return .request
        case .downloading, .requested, .awaitingRelease: return .downloadStatus
        case .unavailable: return nil
        }
    }

    /// Whether `button` is the slide's bright (always-lit, even unfocused) primary.
    /// Exactly one pill is prominent: the leading actionable CTA — Request or a
    /// download/request **status** pill — or **More Info** only when nothing else is
    /// actionable (`primaryButton == nil`). Play stays glass-until-focused as before.
    /// Shared by both hero render paths (UIKit model + SwiftUI pills) so they agree.
    private func isProminentPrimary(_ button: HeroButton, for item: MediaItem) -> Bool {
        switch button {
        case .request, .downloadStatus:
            return true
        case .moreInfo:
            return primaryButton(for: item) == nil
        case .play, .watchlist:
            return false
        }
    }

    /// The item the hero's Watchlist button acts on.
    ///
    /// Watchlisting applies to whole movies and series, and a hero very often
    /// fronts an episode — Continue Watching almost always does. Leaving the
    /// button pointed at the episode meant it simply disappeared there, so an
    /// episode is promoted to its show.
    private func watchlistTarget(for item: MediaItem) -> MediaItem {
        // An episode fronted in the hero (Continue Watching, most often) is
        // watchlisted as its SHOW — see `MediaItem.watchlistSubject`.
        item.watchlistSubject
    }

    private func isWatchlistedForHero(_ item: MediaItem) -> Bool {
        let target = watchlistTarget(for: item)
        let key = Self.watchlistKey(accountID: target.sourceAccountID, itemID: target.id)
        return watchlistOverrides[key]
            ?? actionHandler?.isWatchlisted(target)
            ?? false
    }

    /// Stable, account-scoped key for a title's watchlist membership. Account
    /// scoping avoids a Plex ratingKey on one server colliding with an unrelated
    /// title's id on another. Shared by Home when it builds ``watchlistedKeys``.
    static func watchlistKey(accountID: String?, itemID: String) -> String {
        "\(accountID ?? "-"):\(itemID)"
    }

    /// The watchlist toggle action for the slide's watchlist target, if its
    /// provider supports it.
    private func watchlistAction(for item: MediaItem) -> MediaItemAction? {
        actionHandler?.watchlistAction(for: watchlistTarget(for: item), context: actionContext)
    }

    private static var screenHeight: CGFloat { HomeHeroLayout.screenHeight }

    private static var screenWidth: CGFloat { HomeHeroLayout.screenWidth }

    /// Distance the content column is lifted off the bottom edge of the
    /// full-screen hero, so the paging dots land in the lower third. Paired with
    /// `HomeView.heroRowOverlap`: the Continue Watching row is pulled up by
    /// slightly less than this, so its title peeks ~40px below the dots. Shared via
    /// ``HomeHeroLayout`` so the loading skeleton lines up 1:1.
    private static let contentBottomInset: CGFloat = HomeHeroLayout.contentBottomInset
    // Pushes the paging dots back down relative to the lifted content column, so
    // the dots sit a little below the action buttons rather than tight against them.
    private static let pagingDotsDrop: CGFloat = 40

    var body: some View {
        let height = Self.screenHeight * heroHeightFraction
        // The hero keeps its FULL layout height whether or not it is receded. An
        // earlier design collapsed this frame to lift Continue Watching into a
        // centered position — but the recede now triggers *from* the focus engine's
        // page scroll (see `HomeView`), and collapsing the frame after that scroll
        // changed the content height, shifting Continue Watching up further (jamming
        // it at the very top) and feeding back into the scroll. So we no longer
        // collapse: the page scroll alone positions Continue Watching, and the
        // recede is expressed as the content column lifting (a transform) and the
        // backdrop artwork gliding UP and out of the way behind it.
        let frameHeight = height
        // The backdrop is a full-bleed *background* of the hero content, not a
        // sibling layer in a ZStack. As a background it still bleeds edge-to-edge
        // (it ignores the horizontal safe area) but it no longer contributes to the
        // shared scroll column's width — so it can't drag the hero's own logo/
        // buttons or the rows below off the safe-area gutter (the "content sits too
        // close to the left edge once the hero mounts" bug). Its image transition is
        // still driven imperatively in UIKit (see `HomeHeroBackdrop` / `WipeImageView`)
        // rather than any SwiftUI animation, so it can never decompose into the
        // wrong-order wipe; and because we don't rely on SwiftUI insertion/removal
        // `.transition` for it, hosting it in a background is safe on tvOS. The
        // background is `.top`-aligned (horizontally centered): the content column
        // spans the symmetric safe area, so centering the full-screen-width backdrop
        // on it lands it edge-to-edge across the whole screen. Top-anchoring is what
        // makes the recede clean — see the offset notes below.
        Group {
            if let item = current {
                content(for: item)
            } else {
                Color.clear
            }
        }
        .modifier(HeroShowcaseForeground(surface: .featured))
        .frame(maxWidth: .infinity, minHeight: frameHeight, alignment: .bottomLeading)
        .background(alignment: .top) {
            // Laid out at the FULL hero height and anchored to the frame's TOP, so
            // it stays put as a full-bleed background regardless of the content
            // column's recede lift.
            //
            // The backdrop's OWN vertical motion — the slower `receded` rise that
            // gives the Apple TV parallax feel — is applied INSIDE HomeHeroBackdrop,
            // BEFORE its `.ignoresSafeArea`. That is the only place an offset
            // actually translates the backdrop on screen: an offset applied out here
            // (after the backdrop's safe-area breakout) is silently cancelled by the
            // breakout re-anchoring to the screen edge every layout pass — which is
            // why every earlier attempt left the artwork stuck full-screen.
            heroBackdrop(height: height)
        }
        .overlay(alignment: .bottomTrailing) {
            if let item = current {
                let attributionSources = settings.discoveryAttributionSources(for: item)
                if !attributionSources.isEmpty {
                    // Share one credit across both foreground renderers, in the
                    // trailing paging band without changing the action-row layout.
                    HeroDiscoveryAttribution(sources: attributionSources)
                        .frame(maxWidth: Self.screenWidth * 0.3, alignment: .trailing)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                        .padding(.bottom, Self.contentBottomInset - Self.pagingDotsDrop)
                        .allowsHitTesting(false)
                        .opacity(isFrontmost && !receded ? 1 : 0)
                        .accessibilityHidden(!isFrontmost || receded || !heroVisible)
                        .transaction {
                            if !isFrontmost || receded {
                                $0.animation = nil
                            }
                        }
                }
            }
        }
        .environment(\.plozzArtworkArea, artworkPolicy.heroPolicy.area)
        .opacity(heroVisible || showsTrailer ? 1 : 0)
        .trackHeroExposure(
            item: current,
            isVisible: isFrontmost && !pausedForRows && heroVisible
                && seasonPickerItem == nil && !showingSeasonLookupFailure,
            scopeID: exposureScopeID,
            onExposure: onItemExposed
        )
        .confirmationDialog(
            seasonPickerItem?.title ?? "Request Seasons",
            isPresented: Binding(
                get: { seasonPickerItem != nil },
                set: { if !$0 { seasonPickerItem = nil } }
            ),
            titleVisibility: .visible,
            presenting: seasonPickerAvailability
        ) { availability in
            seasonRequestButtons(for: availability)
        }
        .alert("Season Status Unavailable", isPresented: $showingSeasonLookupFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn’t load the season list. Try again before choosing which seasons to request.")
        }
        .onAppear {
            // Start the first dwell from appearance so the initial slide's gauge
            // and auto-advance are anchored to now, not to view construction.
            restartDwell()
            guard !heroVisible else { return }
            withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
        }
        .onDisappear {
            guard !trailerController.isFullScreen else { return }
            if let item = current, trailerController.isClaimed(by: .detail, itemID: item.id) {
                onTrailerReturnItemChanged(item.id)
            } else {
                onTrailerReturnItemChanged(nil)
            }
            // Detail may already own the same player; only release Home's work.
            resetTrailer(stopPlayer: true)
        }
        .onChange(of: trailerReturnItemID, initial: true) { _, itemID in
            onTrailerReturnItemChanged(itemID)
        }
        // Re-seat the fronted slide when the curated *set* changes under us — not
        // just when it shrinks. `HomeView` seeds the hero synchronously (Continue
        // Watching + Watchlist) and then swaps in the async curated set (which
        // also includes Featured/Random); the counts often match, so keying on
        // `count` alone would leave `index` pointing at a *different* show —
        // fronted with no slide and stale art (the "wrong image / instant appear"
        // bug). Key on identity: preserve the fronted item if it survived the
        // swap, else clamp, then restart artwork warming.
        .onChange(of: items.map(\.id)) { oldIDs, newIDs in
            guard oldIDs != newIDs else { return }
            artworkSetToken &+= 1
            let oldIdx = index
            let frontedID = oldIDs.indices.contains(index) ? oldIDs[index] : nil
            let frontedSurvived: Bool
            if let frontedID, let newIdx = newIDs.firstIndex(of: frontedID) {
                index = newIdx
                frontedSurvived = true
            } else {
                index = min(index, max(0, newIDs.count - 1))
                frontedSurvived = false
            }
            HeroFocusDiagnostics.emit("items SET-SWAP count \(oldIDs.count)->\(newIDs.count) index \(oldIdx)->\(index) frontedSurvived=\(frontedSurvived)")
            let present = Set(newIDs)
            trailerSourceCache = trailerSourceCache.filter { present.contains($0.key) }
            noFastTrailerIDs.formIntersection(present)
            // The foreground clamps its own focused pill when the slide offers
            // fewer actions. The backdrop tracks `current`'s id, so if the fronted
            // item survived the swap its art is unchanged (no wipe); if it was
            // clamped to a different item the backdrop wipes to it (with whatever
            // direction was last recorded).
            //
            // Only when the fronted slide actually CHANGED, though. Curation folds
            // new media into the live set while the viewer sits on Home (see
            // `HeroLiveMerge`), so this now fires for updates that leave the fronted
            // slide exactly where it was. Restarting the dwell for those would reset
            // the auto-advance gauge every time — and a refresh arriving more often
            // than the dwell is long would stop the carousel advancing at all.
            guard !frontedSurvived else { return }
            slideToken &+= 1
            // The set swap re-seats the fronted slide, so start a fresh dwell for
            // it (gauge from empty, no lingering pause).
            restartDwell()
            // ...but if the hero is currently RECEDED (focus is down on Continue
            // Watching), re-assert the pause that `restartDwell()` just cleared.
            // Otherwise a background hero recompute (e.g. a Random re-roll or a
            // Continue Watching change) landing while the user browses below would
            // silently resume the carousel and page behind them — defeating the
            // recede pause. Kept coupled to `pausedAt` (not a bare `!receded` task
            // guard) so `resumeFromRecede()` still resumes cleanly on focus return.
            if pausedForRows { pauseWhileReceded() }
        }
        // Keep Home told which slide is on screen, so a curation landing in the
        // background folds new media into a free slot rather than over this one.
        .onChange(of: current?.id, initial: true) { _, id in
            onPinnedItemsChanged(Set([id].compactMap { $0 }))
        }
        // Drop optimistic watchlist overrides once the AUTHORITY THE PILL FALLS
        // BACK TO agrees — not merely once Home's loaded watchlist row does.
        //
        // Those are two different sources. `isWatchlistedForHero` falls back to
        // `actionHandler.isWatchlisted`, which reads the ledger; `watchlistedKeys`
        // is built from `content.watchlist`, the aggregator's fetched row. Dropping
        // on the row's say-so handed the pill straight back to a source that had
        // not necessarily caught up, and the button flipped back to not-added on
        // the very add it had just confirmed. The row moving is a fine TRIGGER —
        // it means the world changed — but the condition has to be the value the
        // override is standing in for.
        .onChange(of: watchlistedKeys) { _, _ in
            reconcileWatchlistOverrides()
        }
        // The same reconcile when the slides themselves change, so an override set
        // on a title that is still on screen can retire without waiting for the
        // watchlist row to move.
        .onChange(of: items.map(\.id)) { _, _ in
            reconcileWatchlistOverrides()
        }
        // Drop optimistic request overrides once Home's in-place featured refresh
        // reports an authoritative status that reflects the landed request (the
        // server now tracks it: pending/processing/partially/available). Otherwise
        // a just-tapped "Requested" override would mask the real "Downloading n%"
        // /Play the refresh brings in. Keyed on the items' (id, availability) so it
        // only fires when a real status actually changes.
        .onChange(of: items.map { RequestStatusSignature(id: $0.id, availability: $0.availability) }) { _, _ in
            guard !requestOverrides.isEmpty else { return }
            for item in items {
                if let real = item.availability, real != .unknown, real != .deleted {
                    requestOverrides[item.id] = nil
                }
            }
        }
        // Keep only the fronted slide's current warm pass alive. Rapid paging
        // cancels the old five-slide window before it can keep downloading and
        // decoding artwork the user has already skipped.
        .task(id: ArtworkResolutionKey(
            slideToken: slideToken, index: index, policyIdentity: artworkPolicy.heroPolicy.identity
        )) {
            await resolveArtwork(around: index)
        }
        // A cheap 768px preview for every configured hero slide makes even a
        // 20-item fly-through immediate. This task survives page changes; all work
        // stays behind the shared background limiter and full hero art still has
        // foreground priority.
        .task(id: ArtworkPrewarmKey(setToken: artworkSetToken, policyIdentity: artworkPolicy.heroPolicy.identity)) {
            await warmHeroPreviews()
        }
        // Every schedule already on disk, published before a single request — a
        // returning viewer's badges are there on the first frame.
        .task(id: artworkSetToken) {
            await schedules.loadCached(items)
        }
        // Only the slide on screen is fetched. The carousel advances on its own, so
        // the rest fill in as they front rather than firing a burst of requests at
        // first paint, when Home has better things to be doing.
        .task(id: schedules.fetchKey(for: current)) {
            guard let item = current else { return }
            await schedules.refreshFronted(item)
        }
        .task(id: seasonRefreshKey) {
            await refreshVisibleSeasonRequests()
        }
        // Provider logos are much smaller than backdrops, but still require a
        // network fetch plus decode/analysis. Warm them in likely paging order so
        // each slide arrives with its final identity instead of replacing a settled
        // text title. The shared limiter keeps this behind foreground artwork.
        .task(id: ArtworkPrewarmKey(setToken: artworkSetToken, policyIdentity: artworkPolicy.heroPolicy.identity)) {
            await warmHeroLogos()
        }
        // Fast/local trailers only: resolution and the three-second still-image
        // lead-in overlap. The same single player persists into detail navigation.
        .task(id: trailerTaskKey) {
            guard !trailerController.isFullScreen else { return }
            guard isFrontmost, !showcaseSuspended, !trailerController.isFeaturedReserved, backgroundSettings.homeTrailerPlaybackEnabled,
                  let item = current else {
                // When detail is pushed over Home, relinquish control without
                // stopping the shared player — the detail hero owns it now.
                trailerController.clearEndHandler(ownerID: "home-hero")
                if isFrontmost { resetTrailer(stopPlayer: true) }
                return
            }
            if trailerController.isShowing(item.id), trailerController.isPlaying {
                trailerController.claimSurface(.home, itemID: item.id)
                trailerController.setPaused(pausedForRows, surfaceRole: .home)
                activeTrailerDuration = trailerController.duration
                restartDwell()
                let position = trailerController.player.currentTime().seconds
                if position.isFinite, trailerController.isPlaying {
                    dwellStart = Date().addingTimeInterval(-(HeroTrailerTimeline.leadIn + position))
                }
                runEpoch &+= 1
                trailerController.setEndHandler(ownerID: "home-hero") { [itemID = item.id] in
                    guard current?.id == itemID, items.count > 1 else { return }
                    page(to: (index + 1) % items.count, forward: true)
                }
                return
            }
            resetTrailer(stopPlayer: !trailerController.isShowing(item.id))
            let pageStarted = ContinuousClock.now
            let source: HeroTrailerSource?
            if let cached = trailerSourceCache[item.id] {
                source = cached
            } else if noFastTrailerIDs.contains(item.id) {
                source = nil
            } else {
                source = await trailerResolver(item)
                guard !Task.isCancelled, current?.id == item.id else { return }
                if let source {
                    trailerSourceCache[item.id] = source
                } else {
                    noFastTrailerIDs.insert(item.id)
                }
            }
            guard let source,
                  !Task.isCancelled,
                  current?.id == item.id else { return }
            // Let the page wipe land before touching AVPlayer. A cached source used
            // to create the item, start its network load and activate audio inside
            // the wipe, and paging quickly through the hero did that (and tore it
            // down again) on every press. The still image covers the wait; the lead-in
            // only starts once the player is ready, so the timeline stays exact.
            let settle = Self.trailerPrepareSettle - (ContinuousClock.now - pageStarted)
            if settle > .zero {
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, current?.id == item.id else { return }
            }
            activeTrailerSource = source
            trailerController.prepare(
                itemID: item.id,
                resolvedURL: source.url,
                muted: backgroundSettings.homeTrailerMuted
            )
            trailerController.claimSurface(.home, itemID: item.id)
            // Loading and failed trailers keep the normal artwork dwell. Only a
            // playable item earns the longer trailer timeline.
            do {
                guard try await trailerController.waitUntilReady(itemID: item.id) else {
                    guard !Task.isCancelled, current?.id == item.id else { return }
                    trailerSourceCache[item.id] = nil
                    noFastTrailerIDs.insert(item.id)
                    resetTrailer(stopPlayer: false)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.app.error("Hero trailer: readiness wait failed: \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled, current?.id == item.id else { return }
            activeTrailerDuration = trailerController.duration > 0 ? trailerController.duration : source.duration
            restartDwell()
            runEpoch &+= 1
            try? await Task.sleep(for: .seconds(HeroTrailerTimeline.leadIn))
            guard !Task.isCancelled, current?.id == item.id else { return }
            trailerController.setEndHandler(ownerID: "home-hero") { [itemID = item.id] in
                guard current?.id == itemID, items.count > 1 else { return }
                if pausedAt != nil {
                    pendingTrailerAdvance = true
                } else {
                    page(to: (index + 1) % items.count, forward: true)
                }
            }
            trailerController.startPrepared()
        }
        .onChange(of: trailerController.currentItemID) { _, itemID in
            guard itemID == nil, isFrontmost, activeTrailerSource != nil else { return }
            resetTrailer(stopPlayer: false)
        }
        .onChange(of: trailerController.isPaused) { _, paused in
            if paused {
                // Already recorded when the hero receded.
                guard trailerPausedAt == nil else { return }
                trailerPausedAt = trailerController.pauseStartedAt ?? .now
                runEpoch &+= 1
            } else if let trailerPausedAt {
                // Shift the one wall-clock timeline by the real transport pause
                // so both the gauge and auto-fire resume from the same point.
                dwellStart = dwellStart.addingTimeInterval(
                    Date().timeIntervalSince(trailerPausedAt)
                )
                self.trailerPausedAt = nil
                runEpoch &+= 1
            }
        }
        // Auto-advance: the fire is rescheduled whenever `autoAdvanceKey` changes
        // (slide change, manual page, pause/resume, or the item count settling).
        // It runs REGARDLESS of focus — focus lands on the hero's pills by
        // default, so gating on focus froze the carousel the entire time
        // the user was looking at it. Instead, real remote input pauses it (see
        // `noteInteraction`), so it never pages out from under an interacting user.
        .task(id: autoAdvanceKey) {
            guard isFrontmost, !trailerController.isFullScreen, settings.autoAdvance, items.count > 1 else { return }
            if pausedForRows {
                pauseWhileReceded()
                return
            }
            // Paused (user is interacting): schedule no fire at all. The gauge is
            // frozen at `pausedAt`; resuming bumps `runEpoch` to reschedule here.
            guard pausedAt == nil, !trailerController.isPaused else { return }
            // Fire after the *remaining* dwell so that resuming after a pause
            // finishes the countdown from where it froze instead of restarting it.
            let duration = currentDwellDuration
            let position = trailerController.player.currentTime().seconds
            let elapsed = showsTrailer && position.isFinite
                ? HeroTrailerTimeline.leadIn + position
                : Date().timeIntervalSince(dwellStart)
            let remaining = max(0, duration - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            HeroFocusDiagnostics.emit("auto-advance FIRE (from idx=\(index))")
            page(to: (index + 1) % items.count, forward: true)
        }
    }

    /// The Home hero backdrop. Renders the fronted slide's art in a UIKit
    /// two-layer view that performs the Apple TV **parallax wipe imperatively** via
    /// Core Animation (see `HomeHeroBackdrop` / `WipeImageView`) — never a SwiftUI
    /// animation, so it cannot decompose into the intermittent wrong-order wipe.
    /// Changing `current`'s id (which happens when `index` changes on a page) is
    /// what triggers a transition; `lastPageForward` gives it the entering edge.
    /// The scrim, bottom dissolve, overscan breakout and scroll parallax are static
    /// SwiftUI treatment layered over the image and never animate.
    @ViewBuilder
    private func heroBackdrop(height: CGFloat) -> some View {
        let w = Self.screenWidth
        if let item = current {
            HomeHeroBackdrop(
                references: primaryBackdropReferences(for: item),
                asyncFallbackURL: backdropFallback(for: item),
                slideID: item.id,
                forward: lastPageForward,
                width: w,
                height: height,
                scrimTone: scrimTone,
                // The recede rise. The backdrop is screen-pinned by its own
                // `.ignoresSafeArea(.top)` breakout (it does NOT scroll with the
                // page), so it needs no scroll counter. Drive it purely off
                // `receded`: 0 at rest, a clean rise when receded, animated inside
                // HomeHeroBackdrop so it lags the content lift (the Apple TV feel).
                // The bottom-melt shaping (theme-aware height, left weighting) lives
                // entirely inside HomeHeroBackdrop's dissolve now.
                recedeLift: receded ? Self.recedeBackdropRise : 0,
                // On recede, melt the right side into the page like the left so the
                // whole backdrop blends together while browsing the rows below.
                receded: receded,
                trailerController: trailerController,
                showsTrailer: showsTrailer,
                // Gate on STYLE, not the live inset. The rail hides (and publishes
                // inset 0) during a detail push while Home remains alive underneath;
                // using the inset would recenter artwork mid-transition.
                alignsArtworkToLeadingEdge: navigationStyle == .rail,
                scrimOpacity: isFrontmost ? 1 : 0
            )
            .environment(\.heroScrimHeightScale, PlozzTypography.heroScrimScale(
                textScale: textScale, logoSize: settings.logoSize,
                lines: settings.textSize.descriptionLineLimit(base: 3)
            ))
            .heroArtworkSource(
                id: item.id,
                isActive: isFrontmost && !showcaseSuspended
            )
        } else {
            Color.clear.frame(width: w, height: height)
        }
    }

    /// The dwell key: any change restarts the auto-advance fire `.task`. Slide
    /// index and a manual page bump (`advanceToken`) start a fresh dwell; the
    /// pause/resume lifecycle (`runEpoch`) restarts it into its paused no-op or to
    /// sleep the remaining time; `slideToken` covers set-swaps / the seed→curated
    /// grow (it is bumped whenever the fronted slide is re-seated) so the fire and
    /// the gauge stay in sync. Focus is deliberately NOT part of this — the
    /// carousel cycles whether or not the hero holds focus; only real remote input
    /// pauses it.
    ///
    /// `items.count` is in here for one specific reason: the fire returns
    /// immediately while there is only one slide, and a curation folding a second
    /// title in (see `HeroLiveMerge`) does not re-seat the fronted slide, so
    /// nothing else in this key would move and the carousel would stay stationary
    /// forever. Because the restart re-derives its sleep from `dwellStart`, an
    /// ordinary set update resumes the countdown rather than restarting it.
    private var autoAdvanceKey: String {
        "\(index)-\(advanceToken)-\(runEpoch)-\(slideToken)-\(activeTrailerDuration)-\(items.count)-\(isFrontmost)-\(trailerController.isFullScreen)"
    }

    /// One continuous wall-clock timeline from initial still through trailer end.
    /// The gauge never switches progress sources at the crossfade, so it cannot
    /// jump or jitter when video becomes visible.
    private var currentDwellDuration: TimeInterval {
        HeroTrailerTimeline.duration(
            autoAdvanceSeconds: settings.autoAdvanceSeconds,
            mode: backgroundSettings.homeTrailerPlaybackEnabled ? .trailer : .off,
            trailerDuration: activeTrailerDuration
        )
    }

    private var trailerReturnItemID: String? {
        backgroundSettings.homeTrailerPlaybackEnabled && !pausedForRows && heroVisible ? current?.id : nil
    }

    private var showsTrailer: Bool {
        backgroundSettings.homeTrailerPlaybackEnabled && trailerController.isPlaying
            && current.map { trailerController.isShowing($0.id) } == true
    }

    private var trailerTaskKey: String {
        "\(current?.id ?? "-")|\(backgroundSettings.homeTrailerPlaybackEnabled)|\(isFrontmost)|\(trailerController.isFeaturedReserved)|\(showcaseSuspended)|\(trailerController.isFullScreen)"
    }

    // MARK: - Content column

    /// Scroll anchor just above the action row. Pressing **down** off the hero
    /// scrolls this near the top of the viewport, so the show's logo/title lift
    /// off the top and the overview/buttons/dots settle into the upper region
    /// with the Continue Watching row centered below — the Apple TV "recede".
    static let recedeAnchorID = "home-hero-recede"

    /// Constant identity for the hero's foreground. Never keyed on the slide, so
    /// the UIKit view, and the pill that holds focus, survive a page.
    static let actionRowFocusID = "home-hero-action-row"

    /// Lowers the whole hero content column (metadata / buttons / pagination) by
    /// this much: reduced bottom padding on the column. Net 40pt: lowered 80,
    /// then shifted back up 40 to add air between the pagination and the
    /// Continue Watching row below.
    private static let uikitContentDrop: CGFloat = 40

    /// The hero's foreground: one persistent UIKit view that draws the logo,
    /// metadata, overview, pills and paging dots and owns the pills' focus. SwiftUI
    /// positions it and hands it the slide; it reports activation, edge paging and
    /// focus entering or leaving back through ``HeroForegroundEvents``.
    private func content(for item: MediaItem) -> some View {
        HeroForegroundRepresentable(
            model: foregroundModel(for: item),
            neighbours: foregroundNeighbours(for: item),
            logoFallbacks: foregroundLogoFallbacks(for: item),
            logoReferences: foregroundLogoReferences(for: item),
            backgroundSample: displayedArtwork?.sample(for: item.id),
            events: foregroundEvents,
            escapesLeftAtFirstPill: escapesLeftAtFirstPill,
            logoSize: settings.logoSize,
            textSize: settings.textSize,
            width: HomeHeroLayout.screenWidth,
            height: HomeHeroLayout.screenHeight - Self.contentBottomInset
        )
        .frame(height: HomeHeroLayout.screenHeight - Self.contentBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding + navigationContentInset)
        // Lower the whole column (visuals + pills) by `uikitContentDrop`.
        .padding(.bottom, Self.contentBottomInset - Self.uikitContentDrop)
        // Lets SwiftUI treat the UIKit pills as this view's focus, so the default
        // focus below can land on them.
        .focused($foregroundFocused)
        // Initial Home focus lands on the hero, not a Continue Watching card.
        .prefersDefaultFocus(true, in: focusScope)
        .navigationEntryFocus(.content)
        .id(Self.actionRowFocusID)
        // Up opens the playing trailer full screen with the Pinned Sidebar. Only
        // that layout gets the move handler: on the UIKit pills it would also
        // keep Up from reaching the top bar. The pills still own Select and
        // Left/Right.
        .modifier(HomeTrailerFullScreenGesture(
            isActive: navigationStyle == .rail,
            controller: trailerController, itemID: item.id, title: item.title,
            enabled: isFrontmost && !pausedForRows && showsTrailer,
            onMove: noteInteraction
        ))
        .preloadDetailBackdropOnFocus(for: current, isFocused: heroFocused && isFrontmost)
        .onChange(of: pausedForRows) { _, isReceded in
            if isReceded { pauseWhileReceded() } else { resumeFromRecede() }
        }
        .onDisappear {
            pinnedSidebarInteraction?.setHeroFocused(false)
        }
        .modifier(HomeVerticalMotion(y: receded ? -Self.recedeContentLift : 0))
    }

    /// Builds the current slide's ``HeroForegroundModel`` from the view's already
    /// resolved CTA/spoiler state (pure mapping lives in
    /// ``HeroForegroundModelBuilder``).
    private func foregroundModel(for item: MediaItem) -> HeroForegroundModel {
        // paging pill can render the "time until next page" gauge; neighbours are
        // built neutral and re-applied with the real dwell when they front.
        foregroundModel(
            for: item,
            dotsAutoAdvance: settings.autoAdvance && items.count > 1,
            dotsDwellStart: dwellStart,
            dotsDwellDuration: currentDwellDuration,
            // Interaction blocks paging but never freezes a playing trailer or
            // its progress. Static-image slides retain today's frozen gauge.
            dotsPausedAt: activeTrailerDuration > 0
                ? trailerPausedAt
                : (pausedAt ?? trailerPausedAt)
        )
    }

    private func foregroundModel(
        for item: MediaItem,
        dotsAutoAdvance: Bool = false,
        dotsDwellStart: Date? = nil,
        dotsDwellDuration: Double = 0,
        dotsPausedAt: Date? = nil
    ) -> HeroForegroundModel {
        let hideText = spoilerSettings.shouldHideText(for: item)
        // `HeroForegroundModel.title` is a plain `String` fed to a `UILabel`
        // (see its declaration) — the imperative UIKit foreground can't hold a
        // `Text`/`LocalizedStringResource`. Resolving with the SwiftUI `locale`
        // environment (not the device's `Locale.current`) here is safe, not the
        // eager-resolution anti-pattern: `foregroundModel(for:)` is only ever
        // called from this view's own `body`/`content(for:)`, which re-evaluates
        // whenever that environment value changes (see `AppLanguageScope`), so
        // this resolves fresh on every relevant render rather than being cached
        // once and frozen.
        let masked: String?
        if hideText {
            var resource = spoilerSettings.maskedTitle(for: item)
            resource.locale = locale
            masked = String(localized: resource)   // l10n:content — resolves into the UILabel-only `HeroForegroundModel.title` String sink using the live SwiftUI locale env, re-run every render (see comment above), not a frozen eager resolution
        } else {
            masked = nil
        }
        let resolvedScheduleLine: String?
        if var resource = schedules.line(for: item) {
            resource.locale = locale
            resolvedScheduleLine = String(localized: resource)   // l10n:content — UILabel boundary; resolved with the live app locale on every render
        } else {
            resolvedScheduleLine = nil
        }
        let slideIndex = items.firstIndex(where: { $0.id == item.id }) ?? index
        let kindLabel = HeroForegroundModelBuilder.kindLabel(for: item).map { resource in
            var resource = resource
            resource.locale = locale
            return String(localized: resource)   // l10n:content — UILabel boundary; resolved with the live app locale on every render
        }
        return HeroForegroundModelBuilder.model(
            item: item,
            overviewVisible: true,
            ratingsVisible: settings.shouldShowRatings(for: item, spoilerSettings: spoilerSettings),
            showsContentRatings: showsContentRatings,
            ratingPreferences: settings.ratingPreferences,
            maskedTitle: masked,
            pillInputs: foregroundPillInputs(for: item),
            slideCount: items.count,
            slideIndex: slideIndex,
            scheduleLine: resolvedScheduleLine,
            kindLabel: kindLabel,
            sourceProvider: mediaSourceIdentities.identity(for: item)?.provider,
            dotsAutoAdvance: dotsAutoAdvance,
            dotsDwellStart: dotsDwellStart,
            dotsDwellDuration: dotsDwellDuration,
            dotsPausedAt: dotsPausedAt
        )
    }

    /// Maps the slide's `buttons(for:)` (identical order to the SwiftUI pills) into
    /// the pure pill inputs, resolving the same dynamic state the SwiftUI pills use
    /// (resume progress, download %, watchlist fill).
    private func foregroundPillInputs(for item: MediaItem) -> [HeroForegroundModelBuilder.PillInput] {
        buttons(for: item).map { button in
            switch button {
            case .play:
                let resume = item.resumeProgressFraction
                return .init(
                    kind: .play,
                    resumeProgress: resume,
                    isResume: resume != nil,
                    isStarting: item.startsWatching,
                    resumeRemainingText: item.resumeRemainingText,
                    seasonEpisodeText: HeroForegroundModelBuilder.seasonEpisodeButtonText(for: item)
                )
            case .request:
                return .init(
                    kind: .request,
                    prominent: isProminentPrimary(.request, for: item),
                    requestTitle: requestTitle(for: item),
                    requestSystemImage: requestSystemImage(for: item)
                )
            case .downloadStatus:
                if case let .downloading(progress) = heroCTA(for: item) {
                    return .init(
                        kind: .downloadStatus,
                        downloadProgress: progress,
                        prominent: isProminentPrimary(.downloadStatus, for: item)
                    )
                }
                return .init(
                    kind: .downloadStatus,
                    prominent: isProminentPrimary(.downloadStatus, for: item),
                    requestTitle: heroCTA(for: item).requestStatusTitle,
                    requestSystemImage: heroCTA(for: item).requestStatusSystemImage
                )
            case .moreInfo:
                return .init(
                    kind: .moreInfo,
                    prominent: isProminentPrimary(.moreInfo, for: item)
                )
            case .watchlist:
                return .init(
                    kind: .watchlist,
                    isFavorite: isWatchlistedForHero(item)
                )
            }
        }
    }

    /// Bounded neighbour models (previous / next slide) handed to the coordinator to
    /// prepare off-transition so a page finds the model + logo already warm.
    ///
    /// Reused while the window's titles and locale are unchanged. The hero body
    /// re-runs on every focus move, recede and dwell change, and rebuilding two
    /// neighbour models each time (artwork references, overview, ratings) was the
    /// largest app-side cost of moving between the hero and Continue Watching on
    /// an A10X. These models only pre-warm the coordinator; the slide that fronts
    /// is always built fresh by ``foregroundModel(for:)``.
    private func foregroundNeighbours(for item: MediaItem) -> [HeroForegroundModel] {
        guard items.count > 1 else { return [] }
        let current = items.firstIndex(where: { $0.id == item.id }) ?? index
        let previous = (current - 1 + items.count) % items.count
        let next = (current + 1) % items.count
        let window = [previous, next].filter { $0 != current && items.indices.contains($0) }
        let key = HeroNeighbourModelCache.Key(
            itemIDs: window.map { items[$0].id }.uniqued(), locale: locale.identifier
        )
        if let cached = neighbourModels.models(for: key) { return cached }
        var seen: Set<Int> = [current]
        var result: [HeroForegroundModel] = []
        for neighbour in window where !seen.contains(neighbour) {
            seen.insert(neighbour)
            result.append(foregroundModel(for: items[neighbour]))
        }
        neighbourModels.store(result, for: key)
        return result
    }

    /// Async `.logo` URL resolvers for the current slide plus its prepared
    /// neighbours, keyed by itemID. Mirrors the SwiftUI hero's `logoFallback(for:)`
    /// (`ArtworkRouter.logo`), which resolves the show-level logo — including the
    /// series logo for an episode (the router builds its query from `parentTitle`).
    /// Bounded to the same window the coordinator prepares so it never grows.
    private func foregroundLogoFallbacks(for item: MediaItem) -> [String: @Sendable () async -> URL?] {
        var targets: [MediaItem] = [item]
        if items.count > 1 {
            let current = items.firstIndex(where: { $0.id == item.id }) ?? index
            let previous = (current - 1 + items.count) % items.count
            let next = (current + 1) % items.count
            for i in [previous, next] where items.indices.contains(i) { targets.append(items[i]) }
        }
        var result: [String: @Sendable () async -> URL?] = [:]
        let language = artworkPolicy.logoLanguage
        for target in targets where result[target.id] == nil {
            let source = target
            result[source.id] = { await ArtworkRouter.shared.artworkURL(.logo, for: source, language: language) }
        }
        return result
    }

    private func foregroundLogoReferences(for item: MediaItem) -> [String: [ArtworkReference]] {
        var targets: [MediaItem] = [item]
        if items.count > 1 {
            let current = items.firstIndex(where: { $0.id == item.id }) ?? index
            let previous = (current - 1 + items.count) % items.count
            let next = (current + 1) % items.count
            for i in [previous, next] where items.indices.contains(i) { targets.append(items[i]) }
        }
        var result: [String: [ArtworkReference]] = [:]
        for target in targets where result[target.id] == nil {
            result[target.id] = target.artworkReferences(for: .logo)
        }
        return result
    }

    // MARK: - Focus and actions

    /// The foreground's callbacks. Built per body pass; the closures read `@State`
    /// through its storage, so a press between two renders still sees the slide
    /// that is actually in front.
    private var foregroundEvents: HeroForegroundEvents {
        HeroForegroundEvents(
            activate: { activate($0) },
            playPause: {
                noteInteraction()
                if let item = current, primaryButton(for: item) == .play {
                    trailerController.stopHero()
                    onPlay(item)
                }
            },
            edge: { handleEdge($0) },
            interaction: { noteInteraction() },
            focusChanged: { focused, heading in heroFocusChanged(focused, heading: heading) },
            claimFocus: {
                guard isFrontmost else { return false }
                foregroundFocused = true
                return true
            }
        )
    }

    /// Left at the first pill hands focus to the native sidebar on the first
    /// slide; everywhere else it pages back (or opens the pinned sidebar).
    private var escapesLeftAtFirstPill: Bool {
        HeroCarouselFocus.resolve(
            direction: .left,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: 0,
            buttonCount: max(1, current.map { buttons(for: $0).count } ?? 1),
            navigationStyle: navigationStyle
        ) == .escape
    }

    /// A move past the first or last pill. Right pages forward from the last pill,
    /// Left pages back from the first; the focused pill stays where it is.
    private func handleEdge(_ direction: HeroFocusDirection) -> Bool {
        guard let item = current else { return false }
        let buttonCount = buttons(for: item).count
        let outcome = HeroCarouselFocus.resolve(
            direction: direction,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: direction == .left ? 0 : max(0, buttonCount - 1),
            buttonCount: buttonCount,
            navigationStyle: navigationStyle
        )
        HeroFocusDiagnostics.emit("edge \(direction) outcome=\(outcome) idx=\(index)/\(items.count)")
        switch outcome {
        case let .advance(toItem, _):
            page(to: toItem, forward: direction == .right)
            return true
        case .openPinnedSidebar:
            pinnedSidebarInteraction?.requestOpen()
            return true
        case .moveButton, .escape, .blocked:
            return false
        }
    }

    private func heroFocusChanged(_ focused: Bool, heading: UIFocusHeading) {
        heroFocused = focused
        pinnedSidebarInteraction?.setHeroFocused(focused)
        if focused {
            // Focus arriving from outside (a row below, the tab bar, the sidebar):
            // Home snaps back to the full-screen hero and scrolls to the top.
            onFocusGained()
        } else if heading.contains(.down) {
            // Leaving downward starts the recede in the same frame the focus
            // engine starts scrolling, instead of when the scroll later crosses
            // Home's threshold.
            onFocusLeftDown()
        }
    }

    /// Remote Select on a pill.
    private func activate(_ kind: HeroForegroundModel.Pill.Kind) {
        noteInteraction()
        guard let item = current else { return }
        switch kind {
        case .play:
            trailerController.stopHero()
            onPlay(item)
        case .request: performRequest(for: item)
        case .downloadStatus: break // informational status pill — no action
        // "More info" about episode 4 of a series is the series: that is where the
        // seasons, the cast and the rest of it live.
        case .moreInfo: onSelect(item.watchlistSubject)
        case .watchlist: performWatchlist(for: item)
        }
    }

    /// Toggles the watchlist state for `item`, flipping the pill instantly.
    private func performWatchlist(for item: MediaItem) {
        guard let action = watchlistAction(for: item) else { return }
        let target = watchlistTarget(for: item)
        actionHandler?.perform(action, on: target, context: actionContext)
        // Flip the button instantly; the loaded row can lag (an added series from
        // an episode slide isn't an existing card).
        let key = Self.watchlistKey(accountID: target.sourceAccountID, itemID: target.id)
        let adding = action == .addToWatchlist
        watchlistOverrides[key] = adding
        // Bounded, because agreement is not guaranteed to arrive. A write that
        // FAILS announces nothing and moves no row, so an override that only ever
        // retires on agreement would stand until the view was recreated — the pill
        // lying in the other direction, which is the same defect wearing the
        // opposite sign. Mirrors `PlozziOSHomeView.heroRequestOverrideGrace`.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.watchlistOverrideGrace))
            // Only this press's override. A later tap replaces the value and
            // brings its own timer.
            if watchlistOverrides[key] == adding {
                watchlistOverrides[key] = nil
            }
        }
    }

    /// How long an optimistic watchlist override may stand in for the
    /// authoritative membership read before that read wins regardless.
    private static let watchlistOverrideGrace: TimeInterval = 10

    /// Retire every override the authoritative read now agrees with.
    ///
    /// Deliberately asks `actionHandler.isWatchlisted` — the exact value
    /// `isWatchlistedForHero` falls back to — for the slide's own watchlist
    /// target, so an override can never be handed back to a source that still
    /// disagrees with it.
    private func reconcileWatchlistOverrides() {
        guard !watchlistOverrides.isEmpty, let actionHandler else { return }
        for item in items {
            let target = watchlistTarget(for: item)
            let key = Self.watchlistKey(
                accountID: target.sourceAccountID,
                itemID: target.id
            )
            guard let override = watchlistOverrides[key] else { continue }
            if actionHandler.isWatchlisted(target) == override {
                watchlistOverrides[key] = nil
            }
        }
    }

    private func performRequest(for item: MediaItem) {
        if item.kind == .series {
            guard onRequestSeasons != nil else { return }
            let key = SeasonRequestState.itemKey(for: item)
            noteInteraction()
            if let availability = seasonRequestStates[key]?.availability, !availability.seasons.isEmpty {
                seasonPickerAvailability = availability
                seasonPickerItem = item
                return
            }
            let context = seasonRequestContext
            Task {
                await refreshSeasonAvailability(for: item)
                guard seasonRequestContext == context,
                      current.map({ SeasonRequestState.itemKey(for: $0) }) == key,
                      isFrontmost else { return }
                if let availability = seasonRequestStates[key]?.availability, !availability.seasons.isEmpty {
                    seasonPickerAvailability = availability
                    seasonPickerItem = item
                } else {
                    showingSeasonLookupFailure = true
                }
            }
            return
        }
        requestWholeTitle(item)
    }

    private func requestWholeTitle(_ item: MediaItem) {
        guard let onRequest else { return }
        noteInteraction()
        requestOverrides[item.id] = .pending
        let context = seasonRequestContext
        Task {
            let status = await onRequest(item)
            guard seasonRequestContext == context else { return }
            if let status {
                requestOverrides[item.id] = status
            } else {
                requestOverrides[item.id] = nil
            }
        }
    }

    @ViewBuilder
    private func seasonRequestButtons(for availability: MediaRequestAvailability) -> some View {
        SeasonRequestMenuContent(
            availability: availability,
            isSubmitting: seasonPickerItem.map {
                seasonRequestingItems.contains(SeasonRequestState.itemKey(for: $0))
            } ?? false,
            refreshFailed: seasonPickerItem.map {
                seasonLookupFailures.contains(SeasonRequestState.itemKey(for: $0))
            } ?? false,
            onRefresh: { seasonRefreshToken += 1 },
            onRequest: requestSeasons
        )
        Button("Cancel", role: .cancel) { seasonPickerItem = nil }
    }

    private func requestSeasons(_ seasonNumbers: [Int]) {
        guard let item = seasonPickerItem, let onRequestSeasons else { return }
        let key = SeasonRequestState.itemKey(for: item)
        guard !seasonRequestingItems.contains(key) else { return }
        let eligible = Set(seasonRequestStates[key]?.availability?.requestableSeasonNumbers ?? [])
        let selected = Set(seasonNumbers).intersection(eligible).sorted()
        seasonPickerItem = nil
        guard !selected.isEmpty else {
            seasonRefreshToken += 1
            return
        }
        let context = seasonRequestContext
        seasonRequestingItems.insert(key)
        Task {
            let status = await onRequestSeasons(item, selected)
            guard seasonRequestContext == context else { return }
            if status != nil {
                seasonRequestStates[key, default: SeasonRequestState()].accept(selected)
            }
            seasonRequestingItems.remove(key)
            seasonRefreshToken += 1
        }
    }

    private var seasonRefreshKey: String {
        "\(seasonRequestContextID)|\(current.map { SeasonRequestState.itemKey(for: $0) } ?? "")|\(seerConnected)|\(isFrontmost)|\(scenePhase == .active)|\(seasonRefreshToken)"
    }

    private func refreshVisibleSeasonRequests() async {
        let context = "\(seasonRequestContextID)|\(seerConnected)"
        if seasonRequestContext != context {
            seasonRequestContext = context
            requestOverrides = [:]
            seasonRequestStates = [:]
            seasonRequestingItems = []
            seasonLookupFailures = []
            seasonLookupIDs = [:]
            seasonPickerItem = nil
        }
        guard isFrontmost, scenePhase == .active, seerConnected,
              let item = current, item.kind == .series,
              !item.hasPlayableLibraryTarget(), requestAvailability != nil else { return }
        let key = SeasonRequestState.itemKey(for: item)
        repeat {
            await refreshSeasonAvailability(for: item)
            guard !seasonLookupFailures.contains(key),
                  seasonRequestStates[key]?.availability?.seasons.contains(where: \.isInFlight) == true,
                  !Task.isCancelled else { return }
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
        } while !Task.isCancelled
    }

    private func refreshSeasonAvailability(for item: MediaItem) async {
        guard let requestAvailability else { return }
        let key = SeasonRequestState.itemKey(for: item)
        let context = seasonRequestContext
        let lookupID = UUID()
        seasonLookupIDs[key] = lookupID
        let availability = await requestAvailability(item)
        guard !Task.isCancelled, seasonRequestContext == context,
              seasonLookupIDs[key] == lookupID else { return }
        if let availability {
            seasonRequestStates[key, default: SeasonRequestState()].apply(availability)
            seasonLookupFailures.remove(key)
            if seasonPickerItem.map({ SeasonRequestState.itemKey(for: $0) }) == key {
                seasonPickerAvailability = seasonRequestStates[key]?.availability
            }
        } else {
            seasonLookupFailures.insert(key)
        }
    }

    private func requestTitle(for item: MediaItem) -> LocalizedStringResource {
        guard item.kind == .series else { return "Request" }
        let key = SeasonRequestState.itemKey(for: item)
        if let availability = seasonRequestStates[key]?.availability {
            return SeasonRequestPresentation(
                availability: availability,
                isSubmitting: seasonRequestingItems.contains(key)
            ).title
        }
        return seasonLookupFailures.contains(key) ? "Retry Seasons" : "Loading Seasons…"
    }

    private func requestSystemImage(for item: MediaItem) -> String {
        guard item.kind == .series else { return "plus.circle" }
        let key = SeasonRequestState.itemKey(for: item)
        if let availability = seasonRequestStates[key]?.availability {
            return SeasonRequestPresentation(
                availability: availability,
                isSubmitting: seasonRequestingItems.contains(key)
            ).systemImage
        }
        return seasonLookupFailures.contains(key) ? "arrow.clockwise" : "clock"
    }

    /// Fronts `toItem` and restarts the auto-advance dwell. Callers only ever page
    /// by ±1 (Right/Left/chevron/auto-advance). This is now purely a *state* change:
    /// updating `index` swaps the fronted slide's id / candidate URLs, and the
    /// backdrop's UIKit parallax wipe (`HomeHeroBackdrop`) picks that up and pushes
    /// to the new art on its own. There is no SwiftUI backdrop animation here at all
    /// — that is the whole point of the redesign. `isForward` is recorded into
    /// `lastPageForward` so the wipe enters from the correct edge.
    private func page(to toItem: Int, forward isForward: Bool) {
        guard items.indices.contains(toItem), toItem != index else {
            HeroFocusDiagnostics.emit("page IGNORED to=\(toItem) forward=\(isForward) idx=\(index)")
            return
        }
        HeroFocusDiagnostics.emit("page from=\(index) to=\(toItem) forward=\(isForward)")
        // Perf marker (PLZPERF stream only): lets a capture attribute frame hitches
        // to specific slide transitions vs idle. Zero-cost unless PLZPERF_STDOUT=1.
        HomePerfDiagnostics.emitLine("TRANSITION from=\(index) to=\(toItem) forward=\(isForward)")
        // One state change. The backdrop starts its wipe from the new slide id and
        // direction; the foreground fades its own description on the slide change.
        // Focus stays on the same UIKit pill throughout, so nothing re-pins it.
        lastPageForward = isForward
        slideToken &+= 1
        resetTrailer(stopPlayer: true)
        pendingTrailerAdvance = false
        index = toItem
        advanceToken &+= 1
        // A page is a fresh dwell: reset the progress gauge (so the newly-active
        // dot opens from empty instead of flashing the outgoing dot's progress)
        // and clear any pause so the new slide counts down normally.
        restartDwell()
    }

    /// Begins a fresh auto-advance dwell from now: the progress gauge fills from
    /// empty and any interaction pause is cleared. Called on a page, on first
    /// appearance, and when the curated set re-seats the fronted slide.
    private func restartDwell() {
        dwellStart = .now
        pausedAt = nil
        trailerPausedAt = nil
        pendingTrailerAdvance = false
        resumeWork?.cancel()
        resumeWork = nil
    }

    /// How long after a page the trailer waits before preparing its player.
    static let trailerPrepareSettle: Duration = .milliseconds(900)

    private func resetTrailer(stopPlayer: Bool) {
        activeTrailerDuration = 0
        activeTrailerSource = nil
        pendingTrailerAdvance = false
        trailerPausedAt = nil
        trailerController.clearEndHandler(ownerID: "home-hero")
        if stopPlayer {
            trailerController.stopHero()
        }
    }

    /// Records a remote interaction: freezes the auto-advance so it can't page out
    /// from under the user mid-navigation, and (re)arms the idle timer that will
    /// resume the countdown once they stop. Purely a side effect — it never
    /// consumes the input, so edge Left/Right presses still page as normal.
    private func noteInteraction() {
        guard settings.autoAdvance, items.count > 1 else { return }
        if pausedAt == nil {
            // Freeze the gauge at this instant and cancel the pending auto-page.
            pausedAt = Date()
            runEpoch &+= 1
        }
        scheduleResume()
    }

    /// Pauses the auto-advance because the hero has RECEDED — focus moved DOWN to
    /// Continue Watching (see the `receded` onChange). Unlike ``noteInteraction()``
    /// it does NOT arm the idle-resume timer — it cancels any pending one — so the
    /// carousel stays paused for as long as the hero is receded and resumes only
    /// when focus returns to the hero (see ``resumeFromRecede()``). Bumping
    /// `runEpoch` re-keys the fire `.task` into its paused (no-op) branch.
    private func pauseWhileReceded() {
        guard settings.autoAdvance, items.count > 1 else { return }
        resumeWork?.cancel()
        resumeWork = nil
        if pausedAt == nil {
            pausedAt = Date()
            runEpoch &+= 1
        }
        trailerController.setPaused(true, surfaceRole: .home)
        // Record the transport pause here, in the same update as the recede,
        // rather than in the `isPaused` onChange one pass later. Each extra pass
        // re-ran this whole hero body inside the Continue Watching transition,
        // which is where the A10X stalled. The onChange then finds it recorded.
        if trailerController.isPaused, trailerPausedAt == nil {
            trailerPausedAt = trailerController.pauseStartedAt ?? .now
            runEpoch &+= 1
        }
    }

    /// Resumes the auto-advance when the hero un-recedes (focus returns to the hero
    /// from Continue Watching), the mirror of ``pauseWhileReceded()``. Gives the
    /// slide the user lands back on a fresh full dwell and re-keys the fire `.task`.
    /// No-op if the carousel wasn't paused.
    private func resumeFromRecede() {
        guard !trailerController.isFullScreen else { return }
        guard settings.autoAdvance, items.count > 1, pausedAt != nil else { return }
        if pendingTrailerAdvance {
            pendingTrailerAdvance = false
            pausedAt = nil
            advanceForward()
            return
        }
        if activeTrailerDuration > 0 {
            pausedAt = nil
            trailerController.setPaused(false, surfaceRole: .home)
            // Same timeline shift the `isPaused` onChange applies, done in this
            // update for the reason given in ``pauseWhileReceded()``.
            if !trailerController.isPaused, let trailerPausedAt {
                dwellStart = dwellStart.addingTimeInterval(Date().timeIntervalSince(trailerPausedAt))
                self.trailerPausedAt = nil
            }
        } else {
            restartDwell()
            trailerController.setPaused(false, surfaceRole: .home)
        }
        runEpoch &+= 1
    }

    /// (Re)schedules the resume so it fires only after ``resumeAfterIdle`` seconds
    /// with no further input. Each interaction cancels the previous one.
    private func scheduleResume() {
        resumeWork?.cancel()
        let work = DispatchWorkItem { resumeAutoAdvance() }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeAfterIdle, execute: work)
    }

    /// Resumes a paused auto-advance: shifts `dwellStart` forward by however long
    /// the pause was held so the gauge continues from where it froze, then re-keys
    /// the fire `.task` to sleep the remaining time.
    private func resumeAutoAdvance() {
        guard !trailerController.isFullScreen else { return }
        guard let pausedAt else { return }
        // Never let the idle timer (from an earlier in-hero interaction) restart
        // paging while the hero is receded — focus is down on Continue Watching and
        // must not have the carousel page behind it. The `receded` onChange resumes
        // once focus returns to the hero.
        guard !pausedForRows else { return }
        if pendingTrailerAdvance {
            pendingTrailerAdvance = false
            self.pausedAt = nil
            resumeWork = nil
            advanceForward()
            return
        }
        if activeTrailerDuration <= 0 {
            dwellStart = dwellStart.addingTimeInterval(Date().timeIntervalSince(pausedAt))
        }
        self.pausedAt = nil
        resumeWork = nil
        runEpoch &+= 1
    }

    /// Pages one slide forward (wrapping). Used when a finished trailer's page
    /// was held back by interaction or the recede.
    private func advanceForward() {
        guard items.count > 1 else { return }
        page(to: (index + 1) % items.count, forward: true)
    }

    private enum HeroButton: Hashable {
        case play, request, downloadStatus, moreInfo, watchlist
    }

    /// A cheap `Equatable` fingerprint of a featured item's request state, so the
    /// override-reconciliation `onChange` fires only when a real status changes
    /// (not on unrelated re-renders or download-progress ticks).
    private struct RequestStatusSignature: Equatable {
        let id: String
        let availability: MediaAvailabilityStatus?
    }

    private struct ArtworkResolutionKey: Equatable {
        let slideToken: Int
        let index: Int
        let policyIdentity: String
    }

    private struct ArtworkPrewarmKey: Equatable {
        let setToken: Int
        let policyIdentity: String
    }
}

/// A barely visible, mode-aware edge that separates solid hero text from artwork.
struct HeroTextLegibilityShadow: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content.shadow(
            color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.4),
            radius: 4,
            y: 1
        )
    }
}

/// The hero's content-rating chip and genre line, shared by the carousel and the
/// hero that follows focus.
struct HeroMetadataLine: View {
    let item: MediaItem
    @Environment(\.metadataTextScale) private var textScale
    @Environment(\.plozzShowsContentRatings) private var showsContentRatings

    var body: some View {
        let metadata = GenreDisplayFormatter.displayNames(for: item.genres)
        let badge = showsContentRatings ? item.ratingBadge : nil
        if badge != nil || !metadata.isEmpty {
            HStack(alignment: .center, spacing: 16 * textScale) {
                if let badge {
                    MediaBadgeChip(badge: badge)
                }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: "  ·  "))
                        .font(.system(size: PlozzTypography.heroMetadata.scaled(by: textScale).pointSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
    }
}

/// The air-schedule badge above a hero's logo ("New episode every Wednesday").
struct HeroScheduleBadge: View {
    let text: LocalizedStringResource
    @Environment(\.metadataTextScale) private var textScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14 * textScale, style: .continuous)
        Text(text)
            .font(.system(size: PlozzTypography.heroSchedule.scaled(by: textScale).pointSize, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 18 * textScale)
            .padding(.vertical, 10 * textScale)
            // The hero's flat pill fill rather than a Material: the badge sits on
            // the backdrop and its trailer, where a live blur re-samples every
            // presented frame.
            .background { shape.fill(Color(uiColor: HeroForegroundGlass.flatFill())) }
            .overlay { shape.stroke(Color.primary.opacity(0.16), lineWidth: textScale) }
            .contentTransition(.opacity)
            .accessibilityLabel(text)
    }
}

/// Holds the last neighbour models built by ``HomeHeroView``. A reference so
/// filling it from `body` is not a state change.
@MainActor
final class HeroNeighbourModelCache {
    struct Key: Equatable {
        let itemIDs: [String]
        let locale: String
    }

    private var key: Key?
    private var models: [HeroForegroundModel] = []

    func models(for key: Key) -> [HeroForegroundModel]? {
        self.key == key ? models : nil
    }

    func store(_ models: [HeroForegroundModel], for key: Key) {
        self.key = key
        self.models = models
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

/// Upstream's Up-to-full-screen trailer, attached only where it can act.
private struct HomeTrailerFullScreenGesture: ViewModifier {
    let isActive: Bool
    let controller: HeroTrailerController
    let itemID: String
    let title: String // l10n:content - provider-supplied media title
    let enabled: Bool
    let onMove: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.trailerFullScreenOnMove(
                controller: controller, itemID: itemID, role: .home, title: title,
                navigationStyle: .rail, enabled: enabled, onMove: onMove
            )
        } else {
            content
        }
    }
}
#endif
