#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The full-screen Now Playing surface, laid out like the Apple TV app's music
/// player: the album art large at the leading edge over a once-blurred copy of
/// itself, the title and "Artist — Album" beneath it with an outlined quality
/// chip, a compact transport cluster under the text, a full-width progress bar
/// along the bottom, the lyrics column on the right and the source server in
/// the top corner. No Up Next list. Observes the shared
/// `AudioPlaybackController`.
public struct NowPlayingView: View {
    @Environment(\.transientStatusPresenter) private var statusPresenter
    @Bindable var controller: AudioPlaybackController
    /// The app's currently selected theme, passed in from the host so the
    /// player's "Match Theme" appearance can distinguish Pure Black from plain Dark
    /// (the system color scheme alone can't tell them apart).
    var appTheme: AppTheme = .system
    /// Per-profile player preferences (appearance + "show extra info"), injected
    /// from the host so each profile keeps its own choice.
    let musicPlayer: MusicPlayerSettingsModel

    /// Public so the app shell (`MainTabView`) can host the full-screen player as
    /// a `fullScreenCover` on the root `TabView` — the stable presentation host —
    /// rather than deep inside the Music tab's navigation stack, which presents
    /// unreliably under the sidebar tab style.
    public init(
        controller: AudioPlaybackController,
        appTheme: AppTheme = .system,
        musicPlayer: MusicPlayerSettingsModel
    ) {
        self.controller = controller
        self.appTheme = appTheme
        self.musicPlayer = musicPlayer
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @State private var scrubModel = MusicScrubModel()
    #if canImport(UIKit)
    @State private var wakeLease = DisplayWakeLease()
    #endif

    /// The current track's artwork, blurred once into the backdrop bitmap.
    /// Rebuilt whenever the track changes.
    @State private var backdrop: NowPlayingBackdrop.Artwork?
    /// The account each source ID names, for the "Jellyfin · Wohnzimmer" label.
    @Environment(\.plozzMediaSourceIdentities) private var sourceIdentities

    /// Whether the bottom control bar is currently shown. It auto-hides after a
    /// spell of no interaction so only the artwork, title/album and lyrics
    /// remain, and slides back on any remote activity.
    @State private var controlsVisible = true
    /// Pending auto-hide; cancelled/rescheduled on every interaction.
    @State private var hideTask: Task<Void, Never>?
    /// Pending focus re-assert that lands the pause button after a reveal (see
    /// `showControls`); cancelled when the bar hides or the view goes away.
    @State private var focusTask: Task<Void, Never>?

    /// Whether the scrub bar is allowed to take focus. It stays `false` while the
    /// controls are hidden AND across the reveal itself, only flipping `true` a
    /// beat after focus has settled on play/pause. This keeps the scrub surface
    /// out of the focus relocation that fires when the reveal catcher is removed
    /// on reveal — that relocation was what landed a down-press on the scrubber
    /// instead of the pause button. Once settled it's focusable again so the user
    /// can navigate down into the bar to scrub.
    @State private var scrubFocusable = false

    /// Whether the transport *buttons* may take focus, held separately from
    /// `controlsVisible` (which only drives the visual slide). On a reveal the bar
    /// is shown immediately but this stays `false` for a couple of frames so the
    /// transport is NOT yet a focus candidate. A directional Siri-Remote *press*
    /// is delivered to the focus engine as a move it resolves in the same pass as
    /// the reveal; if the buttons became focusable in that pass the move landed on
    /// one of them (the leftmost "shuffle") instead of where we asked. Keeping
    /// them non-focusable until a later, separate pass means the only focusable
    /// view during the press is the reveal catcher, which harmlessly absorbs the
    /// move — after which we place focus deliberately. A *swipe* queues no move,
    /// which is why swipes alone ever worked before this split.
    @State private var transportFocusable = true

    /// Whether the transparent reveal catcher is mounted. It stays up while the
    /// controls are hidden AND across the brief reveal hand-off window — so it,
    /// the sole focusable view at that moment, is the target of the relocation a
    /// directional press triggers. It's unmounted only once focus has been placed
    /// on the intended control, turning the hand-off into a neutral relocation
    /// (identical to a swipe's) that honours `defaultFocus`/`resetFocus`.
    @State private var revealCatcherMounted = false

    /// True while the control bar is mid slide-in/out. During the slide the
    /// scrub bar suppresses its progress spring so the fill + knob ride the slide
    /// in lockstep with the glass track (rather than picking up a separate easing
    /// from playback ticks).
    @State private var controlsSliding = false

    /// Measured height of the progress row, so it can slide fully off the
    /// bottom edge (as one persistent layer) instead of being inserted/removed —
    /// keeping the glass scrub track, played fill and knob moving in lockstep.
    @State private var progressRowHeight: CGFloat = 0

    /// Focus targets on the player. Play/pause is the anchor the bar always
    /// comes back focused on; the reveal catcher holds focus while the bar is
    /// hidden so tvOS focus never lands on an invisible control. Every visible
    /// control has its own case so *any* focus movement between them resets the
    /// auto-hide timer (the bar only fades after a true idle spell).
    private enum Focus: Hashable {
        case playPause, shuffle, previous, next, repeatMode, lyrics, revealCatcher
    }
    @FocusState private var focus: Focus?

    /// Focus scope wrapping the transport controls. When the reveal catcher (a
    /// focused view) is removed on reveal, tvOS runs a "first available" focus
    /// relocation that ignores both `.defaultFocus` and a `focus =` assignment —
    /// so a directional *press* landed on whatever view came first, not the play
    /// button. `resetFocus(in:)` on this scope is the one API that overrides that
    /// relocation and forces `defaultFocus` (the play button) to win. A *swipe*
    /// never triggers the relocation, which is why swipes always worked.
    @Namespace private var controlsFocusScope
    @Environment(\.resetFocus) private var resetFocus

    /// Seconds of inactivity before the control bar fades away.
    private static let controlsAutoHideDelay: TimeInterval = 5

    /// Whether the user wants the lyrics panel shown. Persisted (default on) so
    /// the choice is remembered across sessions. The toggle is disabled — and so
    /// can't be changed — when the current track has no lyrics.
    @AppStorage(MusicLyricsPreference.storageKey) private var lyricsEnabled = MusicLyricsPreference.defaultEnabled

    /// Whether the player shows extra track detail — album name, audio
    /// quality/format, and the lyrics source. Off by default to keep the screen
    /// clean (it's a niche audiophile detail); toggled from Settings ▸ Appearance
    /// and remembered per profile.
    private var showTrackDetails: Bool { musicPlayer.showTrackDetails }

    /// The player's chosen background look (Settings ▸ Appearance ▸ Music
    /// Player). Defaults to following the app theme.
    private var playerAppearance: MusicPlayerAppearance { musicPlayer.appearance }
    /// The app's current light/dark resolution, read from the environment the
    /// player is presented in — used only when `playerAppearance` is `.matchTheme`.
    @Environment(\.colorScheme) private var systemColorScheme

    /// The latched decision of whether to reserve the lyrics panel. It is held
    /// steady across the brief `.loading` window after a track change so the
    /// artwork doesn't fly to center and then jump back when the next song also
    /// has lyrics.
    ///
    /// `nil` means "not decided for any track yet" — on first open we fall back to
    /// the live state, so the player opens **centered** unless we already *know*
    /// the track has lyrics (already resolved `.loaded`), in which case the panel
    /// shows immediately with no slide. Once a track resolves we latch a concrete
    /// value and only ever change it on the next *definitive* result
    /// (`.loaded`/`.unavailable`) or when the user toggles lyrics — never during
    /// `.loading`. So a song→song hand-off where both have lyrics never moves the
    /// artwork, while moving to a song without lyrics waits for the lookup to
    /// finish, then centers.
    @State private var latchedShowsLyricsPanel: Bool?

    /// Pending "collapse the panel because lyrics are unavailable" timer. Held in
    /// state so a follow-on `.loaded` result (e.g. the user skipping to the next
    /// track) can cancel the collapse before the message even has time to fade.
    @State private var pendingCollapse: Task<Void, Never>?

    /// How long the "No lyrics found" message stays visible before the panel
    /// collapses, so anyone reading the panel actually gets time to see it
    /// rather than catching a flash mid-animation.
    private static let noLyricsDwell: Duration = .milliseconds(1500)

    /// Whether to reserve the lyrics panel next to the player. Falls back to the
    /// live state only until the first track resolves (see `latchedShowsLyricsPanel`).
    private var showsLyricsPanel: Bool {
        latchedShowsLyricsPanel ?? (lyricsEnabled && controller.lyricsState.hasLyrics)
    }

    /// Recomputes the latched panel decision from a *definitive* lyrics result.
    /// `.loading` is deliberately ignored so the layout holds steady during the
    /// lookup — that hold is the "wait" before any artwork animation. Disabling
    /// lyrics always collapses the panel immediately.
    private func updateLyricsPanelLatch() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard lyricsEnabled else {
            latchedShowsLyricsPanel = false
            return
        }
        switch controller.lyricsState {
        case .loaded:
            latchedShowsLyricsPanel = true
        case .unavailable:
            // If the panel is currently open we hold it open for a beat so the
            // "No lyrics found" message has time to be read before the panel
            // slides shut. From a closed/undecided state we just collapse
            // immediately — there's nothing for the user to read in that case.
            if latchedShowsLyricsPanel == true {
                pendingCollapse = Task { @MainActor in
                    try? await Task.sleep(for: Self.noLyricsDwell)
                    guard !Task.isCancelled else { return }
                    if case .unavailable = controller.lyricsState, lyricsEnabled {
                        latchedShowsLyricsPanel = false
                    }
                    pendingCollapse = nil
                }
            } else {
                latchedShowsLyricsPanel = false
            }
        case .idle, .silent:
            // `.silent` means we already know this track has no lyrics (cache
            // hit) and a background re-check is quietly under way. Behave
            // exactly like `.idle` — no panel, no message, no dwell — so the
            // user never sees a "Searching for lyrics…" / "No lyrics found"
            // flash for a song they've played before.
            latchedShowsLyricsPanel = false
        case .loading:
            break
        }
    }

    public var body: some View {
        ZStack {
            background

            // Drives the scrub model from the 4x/sec playback clock in isolation,
            // so playback ticks no longer re-evaluate the whole player body. (See
            // PlaybackClock.) Always mounted so progress stays current even while
            // the controls are hidden.
            PlaybackClock(controller: controller, model: scrubModel)

            // One persistent layout. The transport cluster and the progress bar
            // stay mounted while hidden: each slides/fades via offset/opacity
            // (rather than an insert/remove transition), so the glass scrub
            // track, played fill and knob (which live inside a GeometryReader
            // that wouldn't inherit a .move transition) travel together, and the
            // artwork and lyrics never move.
            playerLayout
                // Gate the transport's focusability on `transportFocusable`, NOT
                // `controlsVisible`. The controls slide in the instant
                // `controlsVisible` flips, but the buttons must not become focus
                // candidates in that same pass — otherwise the focus-move a
                // directional *press* queues lands on one of them.
                // `transportFocusable` is held false for a couple of frames across
                // a reveal (see `showControls`) so the reveal catcher stays the only
                // focusable view while the press resolves, then we enable the
                // buttons and place focus ourselves. Nothing else in the layout
                // takes focus, so gating all of it gates exactly the controls.
                .disabled(!transportFocusable)
                // Bias the focus engine toward the pause button so it's the
                // default landing spot when the controls appear, rather than the
                // scrub surface below it.
                .defaultFocus($focus, .playPause)
                // Group the controls into a focus scope so showControls() can
                // call resetFocus(in:) and force the engine to honour the
                // defaultFocus above on a vertical/select reveal.
                .focusScope(controlsFocusScope)

            sourceLabel

            // While the bar is hidden — and across the brief reveal hand-off — a
            // transparent, focusable UIKit surface takes focus so the Siri Remote's
            // presses/swipes are delivered to it (rather than moving focus onto an
            // invisible or freshly-revealed control). It reports the reveal axis: a
            // horizontal gesture reveals onto the scrub bar (scrubbing is
            // horizontal), a vertical/select gesture onto the play/pause button.
            // It stays mounted until `showControls` has placed focus, so it — the
            // sole focus candidate during the press — absorbs the move the press
            // queues; see NowPlayingRevealSurface for the full rationale.
            if revealCatcherMounted {
                NowPlayingRevealSurface { reveal in
                    switch reveal {
                    case .horizontal: showControls(preferScrubber: true)
                    case .vertical: showControls(preferScrubber: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .focused($focus, equals: .revealCatcher)
            }

            // Transient toggle confirmation ("Repeat All", "Shuffle On", …),
            // floating just above the progress bar. Non-interactive and
            // non-focusable so it never disturbs the transport focus flow.
            if let statusPresenter {
                TransientStatusView(
                    presenter: statusPresenter,
                    placement: .musicTransport,
                    palette: isLightPlayer ? .light : .dark
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, progressRowHeight)
            }
        }
        .onChange(of: controlsVisible) { _, _ in
            // Mark the slide window so the scrub bar holds its progress spring
            // until the bar has settled (see controlsSliding).
            controlsSliding = true
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                controlsSliding = false
            }
        }
        .onPreferenceChange(ProgressRowHeightKey.self) { height in
            progressRowHeight = height
        }
        .onAppear {
            syncScrubModel()
            setIdleTimerDisabled(true)
            showControls()
            // Seed the latch from the track we opened on, so a track we already
            // know has lyrics shows the panel immediately (no open-time slide),
            // while an unresolved/none track opens centered.
            updateLyricsPanelLatch()
        }
        .onDisappear {
            setIdleTimerDisabled(false)
            hideTask?.cancel()
            focusTask?.cancel()
        }
        .onChange(of: scrubModel.isScrubbing) { _, _ in scheduleHide() }
        // Any focus movement among the controls (or onto the scrub bar, which
        // clears `focus`) is a live interaction, so restart the idle countdown —
        // the bar only fades 5s after the *last* thing the user did.
        .onChange(of: focus) { _, _ in
            if controlsVisible { scheduleHide() }
        }
        .task(id: "\(controller.currentTrack?.id ?? "")|\(artworkPolicy.forArea(.music).identity)") {
            await loadBackdrop()
        }
        // Re-evaluate the lyrics-panel layout only on a *definitive* result (or a
        // toggle change), holding it steady through `.loading` so the artwork
        // doesn't fly to center and snap back between two songs that both have
        // lyrics. See `latchedShowsLyricsPanel`.
        .onChange(of: controller.lyricsState) { _, _ in updateLyricsPanelLatch() }
        .onChange(of: lyricsEnabled) { wasEnabled, isEnabled in
            updateLyricsPanelLatch()
            // Turning lyrics back on must re-resolve the current track: the
            // resolve that ran while they were off skipped LRCLIB, so its negative
            // is stale and the panel would otherwise stay empty until the next skip.
            if isEnabled && !wasEnabled {
                controller.reloadCurrentTrackLyrics()
            }
        }
        // Back/Menu first dismisses the controls if they're showing; pressing it
        // again (with the controls already hidden) closes the player.
        .onExitCommand {
            if controlsVisible {
                hideControls()
            } else {
                dismiss()
            }
        }
        // In the foreground the Siri Remote's play/pause press is delivered
        // through the focus/responder chain, not MPRemoteCommandCenter — so the
        // command center alone resumes inconsistently. Handle it here so the
        // hardware button reliably toggles playback while the player is open,
        // and reveal the controls so the user sees the state change.
        .onPlayPauseCommand {
            controller.togglePlayPause()
            showControls()
        }
        // The player paints its own background, so it never blindly inherits the
        // app theme. It resolves its own look (see `playerStyle`) and forces the
        // subtree's color scheme to match so text and glass read correctly —
        // light-on-dark for Vibrant Dark / Pure Black, dark-on-light for Frosted Light.
        .environment(\.colorScheme, isLightPlayer ? .light : .dark)
    }

    /// The resolved background treatment, collapsing `.matchTheme` against the
    /// app's selected theme (so Pure Black → true black, Light → frosted, etc.).
    private var playerStyle: LiquidArtworkBackground.Style {
        switch playerAppearance {
        case .matchTheme: return matchedThemeStyle
        case .dark: return .dark
        case .light: return .light
        case .pureBlack: return .pureBlack
        }
    }

    /// Maps the app's `AppTheme` onto a player look for the "Match Theme" option.
    /// `.system` has no explicit light/dark, so it follows the resolved system
    /// color scheme.
    private var matchedThemeStyle: LiquidArtworkBackground.Style {
        switch appTheme {
        case .light: return .light
        case .dark: return .dark
        case .pureBlack: return .pureBlack
        case .system: return systemColorScheme == .light ? .light : .dark
        }
    }

    /// Whether the resolved player look is the light one (drives text color).
    private var isLightPlayer: Bool { playerStyle == .light }

    /// A button style that renders only its label with no platform focus
    /// decoration. Used for the full-screen reveal catcher so taking focus while
    /// the controls are hidden never paints a white highlight plate.
    private struct InvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    /// Side margin of the whole layout, and the top of the artwork: the
    /// concept's 140pt frame around the player.
    private static let horizontalMargin: CGFloat = 140
    private static let artworkTop: CGFloat = 150
    /// The album art's edge, and so the left column's width.
    private static let artworkSize: CGFloat = 560
    /// Space between the left column and the lyrics.
    private static let columnGap: CGFloat = 140

    /// The controls' shared reveal: each group slides on this spring.
    private static let reveal = Animation.spring(response: 0.5, dampingFraction: 0.86)

    /// The whole player: the art column on the left — art, text and transport
    /// cluster — with the lyrics to its right when there are any (the column
    /// centres itself when there aren't), and the progress bar along the bottom
    /// under both. Laid out against the screen edges, not the safe area, so the
    /// margins are the concept's.
    private var playerLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Self.columnGap) {
                leftColumn
                if showsLyricsPanel {
                    LyricsPanel(controller: controller, showTrackDetails: showTrackDetails)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsLyricsPanel ? .topLeading : .top)
            .animation(.easeInOut(duration: 0.25), value: showsLyricsPanel)
            scrubRow
                .padding(.top, 38)
                // Slides fully clear of the bottom edge as one persistent layer.
                .offset(y: controlsVisible ? 0 : progressRowHeight + 60)
                .opacity(controlsVisible ? 1 : 0)
                .animation(Self.reveal, value: controlsVisible)
                .allowsHitTesting(controlsVisible)
        }
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.top, Self.artworkTop)
        .padding(.bottom, 36)
        .ignoresSafeArea()
    }

    /// Artwork, then the text beneath it, then the transport cluster pinned to
    /// the column's foot. The text block's height varies (a missing album, the
    /// quality chip), so the cluster is held at the bottom by a spacer rather
    /// than stacked under the text, and never moves between tracks; the art
    /// is pinned to the top for the same reason.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            trackTextBlock
                .padding(.top, 30)
            Spacer(minLength: 16)
            transportRow
                // Fades in place, a touch of travel for the settle. Trails the
                // progress bar by a hair so the two groups land in layers.
                .offset(y: controlsVisible ? 0 : 24)
                .opacity(controlsVisible ? 1 : 0)
                .animation(Self.reveal.delay(controlsVisible ? 0.07 : 0), value: controlsVisible)
                .allowsHitTesting(controlsVisible)
        }
        .frame(width: Self.artworkSize, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var artwork: some View {
        MusicArtworkImage(
            url: controller.currentTrack?.artworkURL,
            systemPlaceholder: "music.note",
            cornerRadius: 22,
            showsMediaEdge: false,
            asyncFallbackURL: trackFallback(controller.currentTrack),
            pinIdentity: controller.currentTrack?.id
        )
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            // The lift is a plain filled shape behind the art casting the
            // shadow, not a shadow of the image itself: a shape's shadow is
            // drawn from its path, an image's from its rendered pixels.
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(isLightPlayer ? 0.2 : 0.55), radius: 45, y: 30)
            }
    }

    /// Which server the track plays from — "Jellyfin · Wohnzimmer" — in the top
    /// trailing corner. Absent for a source the app has no account for.
    @ViewBuilder
    private var sourceLabel: some View {
        if let accountID = controller.currentTrack?.sourceAccountID,
           let identity = sourceIdentities[accountID] {
            HStack(spacing: 10) {
                ProviderBrandMark(provider: identity.provider, size: 22, showsBackground: false)
                Text(verbatim: "\(identity.provider.displayName) · \(identity.serverName)")
                    .font(.system(size: 21, weight: .medium))
                    .lineLimit(1)
            }
            .plozzForeground(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 66)
            .padding(.trailing, Self.horizontalMargin)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Reveals the control bar and (re)arms the auto-hide timer, landing focus on
    /// play/pause (vertical/select) or the scrub bar (horizontal).
    ///
    /// The reveal happens in two passes so a directional Siri-Remote *press*
    /// lands where we ask rather than on whatever control the focus engine would
    /// otherwise relocate to. A press is delivered to the engine as a focus-move
    /// resolved in the *same* pass as any state change; the trick is to make sure
    /// that during that pass the reveal catcher is the only focusable view, so the
    /// move is absorbed by it, then place focus deliberately on a later pass (a
    /// neutral relocation, exactly like a swipe — which is why swipes always
    /// worked).
    private func showControls(preferScrubber: Bool = false) {
        // Phase 1 — this transaction: show the bar visually, but keep the whole
        // transport non-focusable and the reveal catcher mounted + focused as the
        // sole focus candidate. The press's queued focus-move resolves onto the
        // catcher (a no-op) instead of jumping onto a button/the scrub surface.
        controlsVisible = true
        transportFocusable = false
        scrubFocusable = false
        revealCatcherMounted = true
        focus = .revealCatcher
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            // Phase 2 — a couple of frames later, a fresh transaction: the move
            // has already drained onto the catcher, so it's now safe to hand off.
            // Unmounting the catcher triggers a *neutral* relocation onto the
            // control we make focusable + target below.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, controlsVisible else { return }
            if preferScrubber {
                // Land on the scrub bar: mount its focusable surface and unmount
                // the catcher while the buttons stay non-focusable, so the surface
                // is the sole target of the relocation. Enable the buttons a beat
                // later once focus is settled on the bar.
                scrubFocusable = true
                revealCatcherMounted = false
                focus = nil
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled, controlsVisible else { return }
                transportFocusable = true
            } else {
                // Land on play/pause: enable the buttons and unmount the catcher
                // with the scrub surface still out, so play/pause (defaultFocus)
                // is the only place focus can go. Re-assert once the row has slid
                // on-screen, then finally allow the scrub bar so Down-navigation
                // can reach it.
                transportFocusable = true
                revealCatcherMounted = false
                focus = .playPause
                resetFocus(in: controlsFocusScope)
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled, controlsVisible else { return }
                focus = .playPause
                resetFocus(in: controlsFocusScope)
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, controlsVisible else { return }
                scrubFocusable = true
            }
        }
        scheduleHide()
    }

    /// Immediately hides the control bar (cancelling the pending auto-hide) and
    /// moves focus to the reveal catcher, exactly as the auto-hide timer would.
    private func hideControls() {
        hideTask?.cancel()
        collapseControls()
    }

    /// Collapses the controls and parks focus on the reveal catcher. Shared by
    /// the explicit hide and the auto-hide timer so *both* paths make the whole
    /// transport non-focusable and re-mount the catcher — otherwise a hidden
    /// control stays a focus candidate and a directional press moves onto it
    /// instead of revealing the bar.
    private func collapseControls() {
        focusTask?.cancel()
        transportFocusable = false
        scrubFocusable = false
        revealCatcherMounted = true
        controlsVisible = false
        focus = .revealCatcher
    }

    /// Schedules the control bar to fade away after `controlsAutoHideDelay`,
    /// cancelling any previously scheduled hide. Stays up while the user is
    /// actively scrubbing, and while playback is paused: with the controls
    /// hidden, a paused player would look exactly like a playing one, and the
    /// shown pause/play button is the one cue that tells them apart.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.controlsAutoHideDelay))
            guard !Task.isCancelled else { return }
            if scrubModel.isScrubbing || !controller.isPlaying {
                scheduleHide()
                return
            }
            collapseControls()
        }
    }

    /// Keeps the Apple TV awake while the full-screen player is open so synced
    /// lyrics keep scrolling and artwork stays up during long, hands-off listens.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        wakeLease.keepAwake(disabled)
        #endif
    }

    /// The title, "Artist — Album" and the quality chip, left-aligned under the
    /// art. By default it shows only the title and artist (the clean, Apple
    /// Music-style minimum); album and the quality chip appear only when "Show
    /// track details" is enabled in Settings. Stays on screen after the
    /// controls auto-hide.
    private var trackTextBlock: some View {
        let title = controller.currentTrack?.title ?? "Not Playing"
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let byline {
                Text(verbatim: byline)
                    .font(.system(size: 26, weight: .medium))
                    .plozzForeground(.secondary)
                    .lineLimit(1)
            }
            if showTrackDetails {
                qualityChip
                    .padding(.top, 8)
            }
        }
    }

    /// "Artist — Album"; just the artist unless track details are shown.
    private var byline: String? {  // l10n:content — artist/album names from the server
        let artist = controller.currentTrack?.artistName ?? ""
        let album = showTrackDetails ? controller.currentTrack?.albumTitle ?? "" : ""
        let parts = [artist, album].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func syncScrubModel() {
        scrubModel.duration = controller.duration
        if !scrubModel.isScrubbing { scrubModel.currentSeconds = controller.currentTime }
        scrubModel.onCommit = { target in
            Task { await controller.seek(to: target) }
        }
    }

    private var background: some View {
        NowPlayingBackdrop(artwork: backdrop, style: playerStyle)
    }

    /// Loads the current track's artwork (reusing the shared decoded-image cache)
    /// and blurs it once, off the main thread, into the bitmap the backdrop
    /// stretches across the screen. Clears to the plain field when there's no
    /// artwork.
    private func loadBackdrop() async {
        #if canImport(UIKit)
        guard let track = controller.currentTrack else {
            backdrop = nil
            return
        }
        guard let selected = await MusicArtworkFallback.resolveTrack(
            track, policy: artworkPolicy.forArea(.music)
        ), !Task.isCancelled, let source = selected.image.cgImage else {
            if !Task.isCancelled { backdrop = nil }
            return
        }
        let blurred = await NowPlayingBackdropRenderer.shared.blurred(.init(cgImage: source))
        guard !Task.isCancelled, controller.currentTrack?.id == track.id,
              controller.currentTrack?.sourceAccountID == track.sourceAccountID else { return }
        backdrop = blurred.map {
            NowPlayingBackdrop.Artwork(image: $0.cgImage, identity: "\(track.sourceAccountID ?? "")|\(track.id)")
        }
        #endif
    }

    /// The stream's fidelity as an outlined chip — "FLAC · 24-bit/96kHz". Its
    /// technical detail when the file plays untouched; the tier ("Transcoding")
    /// leads when it doesn't, tinted as the warning it is.
    @ViewBuilder
    private var qualityChip: some View {
        if let quality = controller.currentQuality {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            chipText(quality)
                .font(.system(size: 18, weight: .bold))
                .tracking(0.4)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .overlay(shape.strokeBorder(qualityTint.opacity(0.62), lineWidth: 2))
                .foregroundStyle(qualityTint.opacity(0.92))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(quality.headline))
                .accessibilityValue(Text(verbatim: quality.detail ?? ""))
        }
    }

    private func chipText(_ quality: PlaybackQuality) -> Text {
        guard let detail = quality.detail else { return Text(quality.headline) }
        guard quality.isDirectPlay else {
            return Text(quality.headline) + Text(verbatim: " · \(detail)")
        }
        return Text(verbatim: detail)
    }

    private var qualityTint: Color {
        guard let quality = controller.currentQuality, !quality.isDirectPlay else { return .primary }
        return .orange
    }

    /// The full-width progress bar with elapsed and remaining times beneath it,
    /// below the transport cluster — the Apple TV app's music player.
    private var scrubRow: some View {
        VStack(spacing: 8) {
            MusicScrubBar(model: scrubModel, suppressProgressAnimation: controlsSliding, isFocusable: scrubFocusable)
                .frame(height: 30)
            MusicProgressTimes(model: scrubModel)
        }
        .frame(maxWidth: .infinity)
        // Measure the row's natural height so it can slide fully clear of the
        // bottom edge. Offsets don't change the reported size, so this stays
        // stable whether the row is shown or hidden.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ProgressRowHeightKey.self, value: proxy.size.height)
            }
        )
    }

    /// The compact transport cluster under the text: shuffle, previous, the
    /// white play/pause, next, repeat and lyrics. Previous and next are bare
    /// glyphs; the toggles are round buttons, filled while on. Every button
    /// carries a Focus case so moving between them keeps the bar awake.
    private var transportRow: some View {
        HStack(spacing: 22) {
            transportButton(icon: "shuffle", active: controller.isShuffled) {
                controller.toggleShuffle()
                flashStatus(
                    icon: "shuffle",
                    text: shuffleStatusLabel(controller.isShuffled)
                )
            }
                .focused($focus, equals: .shuffle)

            transportButton(icon: "backward.end.fill", kind: .plain) {
                controller.previous()
                if controller.hasActivePlayback { TouchFeedback.shared.emit(.impact) }
            }
                .focused($focus, equals: .previous)

            playPauseButton

            transportButton(icon: "forward.end.fill", kind: .plain) {
                controller.next()
                if controller.hasActivePlayback { TouchFeedback.shared.emit(.impact) }
            }
                .focused($focus, equals: .next)

            transportButton(icon: repeatIcon, active: controller.repeatMode != .off) {
                controller.cycleRepeatMode()
                let label = repeatStatusLabel(controller.repeatMode)
                flashStatus(icon: label.icon, text: label.text)
            }
                .focused($focus, equals: .repeatMode)

            lyricsToggleButton
                .focused($focus, equals: .lyrics)
        }
    }

    /// The white play/pause — the cluster's one solid control, as the primary
    /// action.
    private var playPauseButton: some View {
        Button {
            controller.togglePlayPause()
            scheduleHide()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 36, weight: .bold))
        }
        .buttonStyle(MusicTransportButtonStyle(kind: .primary))
        .focusEffectDisabled()
        .focused($focus, equals: .playPause)
    }

    /// Toggles the lyrics panel. Filled when on; disabled (and dimmed) only
    /// while lyrics are ON but the current track genuinely has none — turning it
    /// "on" again would do nothing. While lyrics are OFF the toggle stays enabled
    /// so the user can always turn them back on, even on a track that resolved to
    /// "no lyrics" *while disabled* — that resolve deliberately skipped LRCLIB
    /// (our main source) and didn't truly look, so re-enabling re-resolves it.
    private var lyricsToggleButton: some View {
        let hasLyrics = controller.lyricsState.hasLyrics
        let blocked = lyricsEnabled && !hasLyrics
        let on = lyricsEnabled && hasLyrics
        return transportButton(icon: on ? "quote.bubble.fill" : "quote.bubble", active: on) {
            lyricsEnabled.toggle()
        }
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
    }

    /// A secondary transport control. Its button style TYPE is constant —
    /// on/off is a parameter of it, never a swap to another style. Switching
    /// button styles dynamically changes the view's identity, which on tvOS drops
    /// focus (bouncing it to the scrub bar), so toggles must keep one style.
    private func transportButton(
        icon: String,
        kind: MusicTransportButtonStyle.Kind = .round,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            scheduleHide()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: kind == .plain ? 30 : 26, weight: .semibold))
        }
        .buttonStyle(MusicTransportButtonStyle(kind: kind, active: active))
        .focusEffectDisabled()
    }

    private var repeatIcon: String {
        switch controller.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// The icon + wording for the transient confirmation shown when repeat is
    /// cycled. `.off` and `.all` share the `repeat` glyph (they differ only by
    /// tint), so the words are what actually tell the two apart.
    private func repeatStatusLabel(_ mode: AudioPlaybackController.RepeatMode) -> (icon: String, text: LocalizedStringResource) {
        switch mode {
        case .off:
            return (
                "repeat",
                LocalizedStringResource(
                    "music.transport.repeatOff",
                    defaultValue: "Repeat Off",
                    comment: "Transient confirmation after turning music repeat off."
                )
            )
        case .all:
            return (
                "repeat",
                LocalizedStringResource(
                    "music.transport.repeatAll",
                    defaultValue: "Repeat All",
                    comment: "Transient confirmation after setting music to repeat the full queue."
                )
            )
        case .one:
            return (
                "repeat.1",
                LocalizedStringResource(
                    "music.transport.repeatOne",
                    defaultValue: "Repeat One",
                    comment: "Transient confirmation after setting music to repeat the current track."
                )
            )
        }
    }

    private func shuffleStatusLabel(_ enabled: Bool) -> LocalizedStringResource {
        enabled
            ? LocalizedStringResource(
                "music.transport.shuffleOn",
                defaultValue: "Shuffle On",
                comment: "Transient confirmation after turning music shuffle on."
            )
            : LocalizedStringResource(
                "music.transport.shuffleOff",
                defaultValue: "Shuffle Off",
                comment: "Transient confirmation after turning music shuffle off."
            )
    }

    /// Uses the shell-owned presenter; replacement and dismissal timing stay
    /// shared with every other transient confirmation.
    private func flashStatus(icon: String, text: LocalizedStringResource) {
        statusPresenter?.present(
            icon: icon,
            text: text,
            placement: .musicTransport
        )
    }

    /// Best-effort album-cover fallback for `track`, used only when the server
    /// ships no artwork. `nil` track / blank fields yield no fallback.
    private func trackFallback(_ track: MusicTrack?) -> (@Sendable () async -> URL?)? {
        guard let track else { return nil }
        return MusicArtworkFallback.trackCover(
            title: track.title,
            album: track.albumTitle,
            artist: track.artistName
        )
    }
}

// MARK: - Lyrics panel

/// Isolates the lyrics' per-tick `currentTime` read. `AudioPlaybackController` is
/// `@Observable`, so SwiftUI tracks property reads per view body: by reading
/// `currentTime` here (instead of in `NowPlayingView.body`) only the lyrics column
/// — which inherently needs the playback position to highlight + auto-scroll —
/// re-renders on each 4x/sec tick, not the artwork, meta, transport buttons (and
/// their glass effects), equalizer or background.
private struct LyricsPanel: View {
    let controller: AudioPlaybackController
    let showTrackDetails: Bool

    var body: some View {
        NowPlayingLyricsView(
            state: controller.lyricsState,
            currentTime: controller.currentTime,
            showTrackDetails: showTrackDetails
        )
    }
}

/// A zero-size, non-interactive sink that confines the 4x/sec `currentTime` (and
/// `duration`) dependency to itself. Reading those in `NowPlayingView.body` made
/// the whole player re-evaluate on every playback tick; here only this trivial
/// view re-runs, forwarding the position into the scrub model so the scrub bar
/// stays live without dragging the rest of the player into the invalidation.
private struct PlaybackClock: View {
    let controller: AudioPlaybackController
    let model: MusicScrubModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: controller.currentTime, initial: true) { _, time in
                model.duration = controller.duration
                if !model.isScrubbing { model.currentSeconds = time }
            }
            .onChange(of: controller.duration) { _, duration in
                model.duration = duration
            }
    }
}

/// The right-hand lyrics column on the Now Playing screen. Renders the loading
/// state, the lyrics themselves (synced lyrics highlight + auto-scroll the active
/// line; plain lyrics just scroll), or a debug "No lyrics found" placeholder when
/// the track has none.
struct NowPlayingLyricsView: View {
    let state: AudioPlaybackController.LyricsState
    let currentTime: TimeInterval
    /// The lyrics source attribution is part of the optional "track details"
    /// surface, so it only shows when that setting is on. Passed in from the
    /// parent player (per-profile preference).
    let showTrackDetails: Bool
    /// Eases the lines in on first appearance instead of letting them pop.
    @State private var appeared = false
    /// Whether the spinner + "Searching for lyrics…" label should be visible
    /// for the current `.loading` window. Held off for `loadingChromeDelay` so
    /// resolves that finish quickly (cache hits, fast server hits) never flash
    /// the indicator on screen — the panel just stays blank for a beat and
    /// then snaps to the lyrics.
    @State private var showLoadingChrome = false
    private static let loadingChromeDelay: Duration = .milliseconds(500)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if showTrackDetails,
                   case let .loaded(lyrics) = state, let source = lyrics.source {
                    LyricsSourceBadge(source: source)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
            }
            // Reset the gate whenever we leave the loading state, and start the
            // delay countdown each time we enter it. `.task(id:)` cancels its
            // previous instance on identity change, which doubles as our timer
            // cancellation when the state moves to `.loaded`/`.unavailable`
            // before the delay elapses.
            .task(id: isLoadingState) {
                guard isLoadingState else {
                    showLoadingChrome = false
                    return
                }
                showLoadingChrome = false
                try? await Task.sleep(for: Self.loadingChromeDelay)
                guard !Task.isCancelled else { return }
                showLoadingChrome = true
            }
    }

    private var isLoadingState: Bool {
        switch state {
        case .idle, .loading: return true
        case .loaded, .unavailable, .silent: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading, .silent:
            // `.silent` is the "we already know there's nothing, stay quiet"
            // state — render exactly like `.idle` so the panel collapses
            // without ever flashing the spinner or the "No lyrics found"
            // message. The panel won't even be visible in this state thanks
            // to `updateLyricsPanelLatch`, but rendering as blank is the
            // belt-and-braces.
            VStack(spacing: 18) {
                Spacer()
                if showLoadingChrome {
                    ProgressView()
                    Text("Searching for lyrics…")
                        .font(.system(size: 28, weight: .medium))
                        .plozzForeground(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: showLoadingChrome)

        case .unavailable:
            VStack {
                Spacer()
                Text("No lyrics found")
                    .font(.system(size: 34, weight: .semibold))
                    .plozzForeground(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(lyrics):
            lyricsScroll(lyrics)
        }
    }

    /// Where the sung line rests, as a fraction of the column's height: level
    /// with the upper half of the artwork, as the concept sets it, rather than
    /// the screen's centre.
    private static let activeAnchor: CGFloat = 0.32

    private func lyricsScroll(_ lyrics: Lyrics) -> some View {
        let active = activeIndex(in: lyrics)
        // The line to keep at the anchor. Before the first timestamp is reached
        // `active` is nil, so fall back to the upcoming line (line 0 at the very
        // start) — this guarantees the lyrics open in place rather than pinned
        // to the top.
        let focus = focusIndex(in: lyrics)
        let highlight = Animation.spring(response: 0.55, dampingFraction: 0.85)
        let anchor = UnitPoint(x: 0, y: Self.activeAnchor)
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 34) {
                        // Breathing room above and below so the first and last
                        // lines can scroll all the way to the anchor.
                        Color.clear.frame(height: geo.size.height * Self.activeAnchor)
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 50, weight: .bold))
                                .foregroundStyle(.primary)
                                .opacity(Self.opacity(forIndex: index, active: active))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                .animation(highlight, value: active)
                        }
                        Color.clear.frame(height: geo.size.height * (1 - Self.activeAnchor))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(true)
                // No edge-fade mask: the graded opacity already fades the lines
                // toward the column's edges, and a mask over a column this size
                // is an offscreen pass every time the lines move.
                .opacity(appeared ? 1 : 0)
                .onChange(of: focus) { _, newIndex in
                    withAnimation(highlight) {
                        proxy.scrollTo(newIndex, anchor: anchor)
                    }
                }
                // Position correctly as soon as the panel appears and again once
                // the geometry settles (the panel animates in, so the first
                // onAppear can fire before the final height is known). The first
                // appearance also eases the lines in rather than popping.
                .onAppear {
                    proxy.scrollTo(focus, anchor: anchor)
                    withAnimation(.easeOut(duration: 0.5)) { appeared = true }
                }
                .onChange(of: geo.size.height) { _, _ in
                    proxy.scrollTo(focus, anchor: anchor)
                }
            }
        }
    }

    /// The line to keep at the anchor: the active line, or — before the first
    /// timestamp is reached — the next upcoming line (line 0 at song start), so
    /// the lyrics always open in place.
    private func focusIndex(in lyrics: Lyrics) -> Int {
        if let active = activeIndex(in: lyrics) { return active }
        if lyrics.isSynced,
           let upcoming = lyrics.lines.firstIndex(where: { ($0.start ?? .infinity) > currentTime }) {
            return upcoming
        }
        return 0
    }

    /// How visible a line is given its distance from the active one: the sung
    /// line is solid; the next line, the one about to be sung, is the brightest
    /// of the rest; the lines already sung recede faster than those to come;
    /// and every line fades further with distance — which also fades the column
    /// out toward its edges. Opacity only — no per-line blur. With no active line
    /// (unsynced or pre-roll) every line sits at a calm, even brightness.
    static func opacity(forIndex index: Int, active: Int?) -> Double {
        guard let active else { return 0.25 }
        let distance = index - active
        switch distance {
        case 0: return 1
        case 1: return 0.28
        case 2: return 0.2
        case 3: return 0.12
        case -2 ... -1: return 0.18
        case -3: return 0.1
        default: return 0.06
        }
    }

    /// A small anticipation lead (seconds) so a line highlights right as it's
    /// sung rather than a beat late. Compensates for residual sampling latency
    /// and matches how lyric apps nudge the active line slightly early.
    private static let lyricsLeadTime: TimeInterval = 0.3

    /// The index of the line currently being sung, for synced lyrics.
    private func activeIndex(in lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced else { return nil }
        let cue = currentTime + Self.lyricsLeadTime
        var match: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= cue { match = index } else { break }
        }
        return match
    }
}

/// Tiny attribution shown in the lyrics panel header: the source's brand mark
/// (the same app-bundle logos used in Settings for Jellyfin/Plex) plus its name.
/// LRCLIB has no bundled logo, so it uses an SF Symbol stand-in.
struct LyricsSourceBadge: View {
    let source: LyricsSource

    var body: some View {
        HStack(spacing: 6) {
            logo
            Text(source.displayName)
                .font(.caption.weight(.semibold))
        }
        .plozzForeground(.tertiary)
    }

    @ViewBuilder
    private var logo: some View {
        switch source {
        case .jellyfin:
            ProviderBrandMark(
                provider: .jellyfin,
                size: 16,
                showsBackground: false
            )
        case .emby:
            ProviderBrandMark(
                provider: .emby,
                size: 16,
                showsBackground: false
            )
        case .plex:
            ProviderBrandMark(
                provider: .plex,
                size: 16,
                showsBackground: false
            )
        case .lrclib:
            // LRCLIB ships no brand asset we can bundle, so use a lyrics-flavoured
            // SF Symbol sized to match the 16×16 server logos above so all three
            // attributions line up cleanly.
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
        }
    }
}

/// The Now Playing transport's buttons, drawn here rather than with the stock
/// `.glass` styles for two reasons: the resting surface must honour Reduce
/// Transparency and the player-glass reduction (frosted instead of glass, as on
/// Apple TV HD and 4K first generation), which the stock styles cannot; and
/// every control shares the redesign's focus treatment — solid white with
/// page-colour ink and a small lift.
struct MusicTransportButtonStyle: ButtonStyle {
    enum Kind {
        /// A round surface — glass, or frost when reduced — filled while on.
        case round
        /// A bare glyph (previous / next); only focus draws a surface.
        case plain
        /// The solid play/pause.
        case primary
    }

    let kind: Kind
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        MusicTransportButtonBody(configuration: configuration, kind: kind, active: active)
    }
}

private struct MusicTransportButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: MusicTransportButtonStyle.Kind
    let active: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.plozzReducePlayerGlass) private var reducePlayerGlass
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    private var diameter: CGFloat { kind == .primary ? 84 : 64 }
    private var solid: Bool { isFocused || kind == .primary }

    var body: some View {
        configuration.label
            .foregroundStyle(solid ? ink : Color.primary)
            .frame(width: diameter, height: diameter)
            .background { surface }
            .contentShape(Circle())
            // The surface swaps on the same frame focus moves; only the lift
            // and the press are animated.
            .animation(nil, value: isFocused)
            .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    /// The page colour on the white (dark looks) or black (light look) fill.
    private var ink: Color {
        colorScheme == .light ? .white : Color(red: 21 / 255, green: 22 / 255, blue: 26 / 255)
    }

    @ViewBuilder
    private var surface: some View {
        let shape = Circle()
        if solid {
            // A filled shape's shadow, over the still backdrop — not over video.
            shape.fill(Color.primary)
                .shadow(color: .black.opacity(kind == .primary ? 0.35 : 0.25), radius: 17, y: 14)
        } else if kind == .plain {
            Color.clear
        } else if reducePlayerGlass || reduceTransparency {
            shape.fill(Color.primary.opacity(active ? 0.24 : 0))
                .plozzFrostedBackground(shape, raised: active)
                .plozzFrostedBorder(shape)
        } else if #available(tvOS 26.0, iOS 26.0, *) {
            shape.fill(Color.primary.opacity(active ? 0.24 : 0))
                .glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color.primary.opacity(active ? 0.32 : 0.12))
        }
    }
}

/// Elapsed and remaining time under the progress bar. Its own view, so only
/// it re-renders on the 4x/sec playback tick that moves the numbers.
private struct MusicProgressTimes: View {
    let model: MusicScrubModel

    var body: some View {
        HStack {
            Text(MusicFormat.duration(model.displaySeconds))
            Spacer()
            Text(verbatim: "\u{2212}" + MusicFormat.duration(max(0, model.duration - model.displaySeconds)))
        }
        .font(.system(size: 21, weight: .semibold).monospacedDigit())
        .plozzForeground(.secondary)
    }
}

/// Reports the natural height of the progress row so the player can slide it
/// fully off the bottom edge as a single layer.
private struct ProgressRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
