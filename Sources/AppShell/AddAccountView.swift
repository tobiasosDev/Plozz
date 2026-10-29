#if canImport(SwiftUI)
import SwiftUI
import FeatureShareOnboarding
import CoreModels
import CoreUI
import FeatureAuth
import FeatureDiscovery
import FeatureDiscoveryCore

/// Chooses a provider and opens its connection flow before adding the account.
struct AddAccountView: View {
    let deviceID: String
    let canReturnToApp: Bool
    let signedInServers: [SignedInServer]
    let onMediaBrowserServerSelected: (MediaServer) -> Void
    let onPlexAuthenticated: (UserSession) -> Void
    let onIPTVAuthenticated: (UserSession) throws -> Void
    let onPlexAuthenticatedMany: ([UserSession]) -> Void
    let onShareConfigured: (ShareDraft) -> Void
    let onWebDAVShareConfigured: (WebDAVShareConfiguration) -> Void
    let onMediaShareConfigured: (MediaShareOnboardingResult) -> Void
    let onCancel: () -> Void
    var onSetUpFromAnotherDevice: (() -> Void)?
    let initialIPTVPlaylist: LiveTVPlaylistSource?
    let reconnectingIPTV: UserSession?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: ProviderKind?
    @State private var plexAuthViewModel: PlexAuthViewModel
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var pageIsReady = true
    @State private var isTransitioning = false
    @State private var isPreparingPlex = false

    init(
        deviceID: String,
        canReturnToApp: Bool,
        initialProvider: ProviderKind? = nil,
        initialIPTVPlaylist: LiveTVPlaylistSource? = nil,
        reconnectingIPTV: UserSession? = nil,
        signedInServers: [SignedInServer] = [],
        onMediaBrowserServerSelected: @escaping (MediaServer) -> Void,
        onPlexAuthenticated: @escaping (UserSession) -> Void,
        onIPTVAuthenticated: ((UserSession) throws -> Void)? = nil,
        onPlexAuthenticatedMany: @escaping ([UserSession]) -> Void = { _ in },
        onShareConfigured: @escaping (ShareDraft) -> Void = { _ in },
        onWebDAVShareConfigured: @escaping (WebDAVShareConfiguration) -> Void = { _ in },
        onMediaShareConfigured: @escaping (MediaShareOnboardingResult) -> Void = { _ in },
        onCancel: @escaping () -> Void,
        onSetUpFromAnotherDevice: (() -> Void)? = nil
    ) {
        self.deviceID = deviceID
        self.initialIPTVPlaylist = initialIPTVPlaylist
        self.reconnectingIPTV = reconnectingIPTV
        self.canReturnToApp = canReturnToApp
        self.signedInServers = signedInServers
        self.onMediaBrowserServerSelected = onMediaBrowserServerSelected
        self.onPlexAuthenticated = onPlexAuthenticated
        self.onIPTVAuthenticated = onIPTVAuthenticated ?? onPlexAuthenticated
        self.onPlexAuthenticatedMany = onPlexAuthenticatedMany
        self.onShareConfigured = onShareConfigured
        self.onWebDAVShareConfigured = onWebDAVShareConfigured
        self.onMediaShareConfigured = onMediaShareConfigured
        self.onCancel = onCancel
        self.onSetUpFromAnotherDevice = onSetUpFromAnotherDevice
        // Seed the flow's starting screen. This also lets "Add Another Plex
        // Account" enter Plex linking directly instead of returning to the
        // provider chooser.
        _choice = State(initialValue: initialProvider)
        _plexAuthViewModel = State(initialValue: PlexAuthViewModel(
            service: PlexAuthService(deviceID: deviceID),
            onAuthenticated: onPlexAuthenticated,
            onAuthenticatedMany: onPlexAuthenticatedMany
        ))
    }

    var body: some View {
        ZStack {
            ZStack { pageContent }
                .id(pageID)
                // Resolve the page's geometry once at this boundary instead of
                // pushing the transition down to independently hosted focus rows.
                .geometryGroup()
                .transition(pageTransition)
                .allowsHitTesting(!isTransitioning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let overflowing scroll content reach the physical window edges. The
        // window remains the final clip for the full-page directional push.
        .ignoresSafeArea(.container, edges: .vertical)
        .onChange(of: plexAuthViewModel.phase) { _, phase in
            continueToPreparedPlexPage(for: phase)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch choice {
        case .none:
            chooser
        case .jellyfin:
            ServerPickerView(
                provider: .jellyfin,
                isPageReady: pageIsReady,
                signedInServers: signedInServers.filter { $0.server.provider == .jellyfin },
                onBack: navigateBackToChooser
            ) { onMediaBrowserServerSelected($0) }
        case .emby:
            ServerPickerView(
                provider: .emby,
                isPageReady: pageIsReady,
                signedInServers: signedInServers.filter { $0.server.provider == .emby },
                onBack: navigateBackToChooser
            ) { onMediaBrowserServerSelected($0) }
        case .plex:
            PlexLinkView(
                viewModel: plexAuthViewModel,
                onCancel: navigateBackToChooser
            )
        case .silo:
            ServerPickerView(
                provider: .silo,
                isPageReady: pageIsReady,
                signedInServers: signedInServers.filter { $0.server.provider == .silo },
                onBack: navigateBackToChooser
            ) { onMediaBrowserServerSelected($0) }
        case .iptv:
            IPTVSignInView(
                deviceID: deviceID, address: initialIPTVPlaylist?.playlistURL.absoluteString ?? "",
                name: initialIPTVPlaylist?.name ?? "",
                guideAddress: initialIPTVPlaylist?.guideURLs.first?.absoluteString ?? "",
                guideURLs: initialIPTVPlaylist?.guideURLs ?? [],
                reconnecting: reconnectingIPTV,
                onAuthenticated: onIPTVAuthenticated, onCancel: navigateBackToChooser
            )
        case .mediaShare:
            AddMediaShareView(
                isPageReady: pageIsReady,
                onBack: navigateBackToChooser,
                onSMBConfigured: onShareConfigured,
                onWebDAVConfigured: onWebDAVShareConfigured,
                onMediaShareConfigured: onMediaShareConfigured
            )
        }
    }

    private var chooser: some View {
        ProviderChooserView(
            showsBranding: !canReturnToApp,
            showsBackButton: canReturnToApp,
            isPreparingPlex: isPreparingPlex,
            onBack: cancelPreparationOrReturn,
            onSelect: navigate(to:),
            onSetUpFromAnotherDevice: onSetUpFromAnotherDevice
        )
    }

    private var pageTransition: AnyTransition {
        OnboardingPageMotion.transition(
            direction: navigationDirection,
            reduceMotion: reduceMotion
        )
    }

    private var pageID: String {
        switch choice {
        case .none: "providerChooser"
        case .jellyfin: "jellyfin"
        case .emby: "emby"
        case .plex: "plex"
        case .silo: "silo"
        case .iptv: "iptv"
        case .mediaShare: "mediaShare"
        }
    }

    private func navigate(to destination: ProviderKind) {
        if destination == .plex {
            guard !isPreparingPlex, !isTransitioning else { return }
            isPreparingPlex = true
            plexAuthViewModel.start()
            return
        }
        transition(to: destination, direction: .forward)
    }

    private func continueToPreparedPlexPage(for phase: PlexAuthViewModel.Phase) {
        guard isPreparingPlex else { return }
        switch phase {
        case .idle, .requesting:
            return
        case .awaitingLink, .loadingServers, .selectingServer, .error:
            isPreparingPlex = false
            transition(to: .plex, direction: .forward)
        }
    }

    private func cancelPreparationOrReturn() {
        if isPreparingPlex {
            isPreparingPlex = false
            plexAuthViewModel.cancel()
        } else {
            onCancel()
        }
    }

    private func navigateBackToChooser() {
        transition(to: nil, direction: .backward)
    }

    private func transition(to destination: ProviderKind?, direction: OnboardingNavigationDirection) {
        guard !isTransitioning else { return }

        isTransitioning = true
        pageIsReady = false
        navigationDirection = direction
        withAnimation(
            OnboardingPageMotion.animation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            choice = destination
        } completion: {
            pageIsReady = true
            isTransitioning = false
        }
    }
}

private enum ProviderChooserFocus: Hashable {
    case back
    /// Invisible sink just before the first tile; see `ProviderChooserView`.
    case backGuard
    case jellyfin
    case emby
    case plex
    case silo
    case iptv
    case mediaShare
    case setUpFromAnotherDevice

    init(provider: ProviderKind) {
        switch provider {
        case .jellyfin: self = .jellyfin
        case .emby: self = .emby
        case .plex: self = .plex
        case .silo: self = .silo
        case .iptv: self = .iptv
        case .mediaShare: self = .mediaShare
        }
    }
}

private struct ProviderChooserView: View {
    let showsBranding: Bool
    let showsBackButton: Bool
    let isPreparingPlex: Bool
    let onBack: () -> Void
    let onSelect: (ProviderKind) -> Void
    var onSetUpFromAnotherDevice: (() -> Void)?
    @FocusState private var focusedControl: ProviderChooserFocus?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsBranding {
                FirstRunPosterWall()
            }

            VStack(spacing: 0) {
                if showsBranding {
                    FirstRunWelcome()
                        .padding(.bottom, 96)
                }

                ProviderChoiceTiles(
                    focusedControl: $focusedControl,
                    isPreparingPlex: isPreparingPlex,
                    leadingGuardActive: showsBackButton
                        && (focusedControl == .firstTile || focusedControl == .backGuard),
                    onSelect: onSelect
                )
                .allowsHitTesting(!isPreparingPlex)

                if let onSetUpFromAnotherDevice {
                    Button(action: onSetUpFromAnotherDevice) {
                        Label("Set up from another device", systemImage: "qrcode")
                            .font(.system(size: 26, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(PlozzOpaquePillButtonStyle())
                    .focused($focusedControl, equals: .setUpFromAnotherDevice)
                    .padding(.top, 108)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsBackButton {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .back)
                .padding(.horizontal, 80)
                .padding(.vertical, 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        .defaultFocus($focusedControl, .firstTile)
        .onAppear { focusedControl = .firstTile }
        .onChange(of: focusedControl) { _, focus in
            // Left from the first tile lands on the guard, which hands focus to
            // Back. Resolving it here rather than in `onMoveCommand` matters: a
            // container's move handler can observe the post-move focus, so it
            // can't tell "Left from the first tile" from "Left onto it".
            if focus == .backGuard { focusedControl = .back }
        }
        .onMoveCommand(perform: bridgeBackButtonFocus)
        .onExitCommand {
            if showsBackButton || isPreparingPlex { onBack() }
        }
    }

    /// Back sits above the tiles' leading end, outside the focus engine's
    /// search beam from either side. Only the way out of it needs bridging:
    /// the engine finds nothing beside it, so this sees the pre-move value.
    private func bridgeBackButtonFocus(_ direction: MoveCommandDirection) {
        guard showsBackButton, focusedControl == .back else { return }
        let towardTiles: MoveCommandDirection = layoutDirection == .rightToLeft ? .left : .right
        if direction == towardTiles { focusedControl = .firstTile }
    }
}

private extension ProviderChooserFocus {
    static var firstTile: Self { Self(provider: ProviderChoiceTiles.providers[0]) }
}

/// The welcome header above the first-run tiles.
private struct FirstRunWelcome: View {
    var body: some View {
        VStack(spacing: 0) {
            Image("PlozzLogo")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 150, height: 150)
                .padding(.bottom, 22)
                .accessibilityLabel(Text(verbatim: "Plozz"))

            Text(LocalizedStringResource(
                "Welcome to Plozz",
                comment: "First-run heading above the media-source choices. Plozz is the app name."
            ))
            .font(.system(size: 64, weight: .bold))
            .tracking(-1.2)

            Text(LocalizedStringResource(
                "Free forever and open source. Choose where your movies, shows and music live.",
                comment: "First-run subtitle under Welcome to Plozz, above the media-source choices."
            ))
            .font(.system(size: 28))
            .plozzForeground(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
        }
        .padding(.horizontal, 80)
    }
}

/// The concept's tilted poster wall, without posters: there is no server yet
/// and no artwork is bundled, so poster-shaped tiles in muted tones stand in.
///
/// Drawn once into a single `Canvas` layer and dimmed by a veil painted in the
/// page colour. No image assets, no animation, no blur and no mask. The view
/// has no inputs that change with focus, so moving between tiles never redraws
/// it.
private struct FirstRunPosterWall: View {
    @Environment(\.themePalette) private var palette

    private static let tones: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.50, blue: 0.70), Color(red: 0.14, green: 0.20, blue: 0.33)),
        (Color(red: 0.62, green: 0.40, blue: 0.72), Color(red: 0.24, green: 0.14, blue: 0.32)),
        (Color(red: 0.30, green: 0.62, blue: 0.62), Color(red: 0.10, green: 0.24, blue: 0.26)),
        (Color(red: 0.76, green: 0.52, blue: 0.30), Color(red: 0.30, green: 0.17, blue: 0.10)),
        (Color(red: 0.40, green: 0.64, blue: 0.40), Color(red: 0.13, green: 0.25, blue: 0.15)),
        (Color(red: 0.74, green: 0.34, blue: 0.40), Color(red: 0.28, green: 0.10, blue: 0.14)),
        (Color(red: 0.30, green: 0.52, blue: 0.84), Color(red: 0.09, green: 0.18, blue: 0.36)),
        (Color(red: 0.56, green: 0.56, blue: 0.62), Color(red: 0.20, green: 0.20, blue: 0.25))
    ]

    var body: some View {
        Canvas { context, size in
            let posterSize = CGSize(width: 220, height: 330)
            let gap: CGFloat = 28
            let columns = 11
            let rows = 5
            let gridWidth = CGFloat(columns) * (posterSize.width + gap)
            let gridHeight = CGFloat(rows) * (posterSize.height + gap)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(-9))
            context.opacity = 0.55
            for column in 0..<columns {
                for row in 0..<rows {
                    let x = CGFloat(column) * (posterSize.width + gap) - gridWidth / 2
                    let y = CGFloat(row) * (posterSize.height + gap) - gridHeight / 2
                        + (column.isMultiple(of: 2) ? 0 : 60)
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: posterSize)
                    let tone = Self.tones[(column * 3 + row * 5) % Self.tones.count]
                    let poster = Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
                    context.fill(poster, with: .linearGradient(
                        Gradient(colors: [tone.0, tone.1]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                    ))
                    // A faint title block, so the shapes read as posters.
                    let title = CGRect(x: rect.minX + 24, y: rect.maxY - 92, width: rect.width - 48, height: 22)
                    context.fill(Path(roundedRect: title, cornerRadius: 6), with: .color(.white.opacity(0.22)))
                }
            }
        }
        .overlay {
            EllipticalGradient(
                stops: [
                    .init(color: palette.backgroundBase.opacity(0.94), location: 0),
                    .init(color: palette.backgroundBase.opacity(0.78), location: 0.6),
                    .init(color: palette.backgroundBase.opacity(0.55), location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.52),
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
        }
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: palette.backgroundBase.opacity(0.9), location: 0),
                    .init(color: palette.backgroundBase.opacity(0), location: 0.4)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
        .background(palette.backgroundBase)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One horizontal run of provider tiles, in the model's provider order.
private struct ProviderChoiceTiles: View {
    static let providers = ProviderKind.allCases

    let focusedControl: FocusState<ProviderChooserFocus?>.Binding
    let isPreparingPlex: Bool
    /// Only while the first tile (or the guard itself) holds focus, so Down
    /// from Back and moves along the row never land on it.
    let leadingGuardActive: Bool
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        HStack(spacing: ProviderChoiceTile.spacing) {
            ForEach(Self.providers, id: \.self) { provider in
                ProviderChoiceTile(
                    provider: provider,
                    isLoading: provider == .plex && isPreparingPlex,
                    focusedControl: focusedControl
                ) {
                    onSelect(provider)
                }
            }
        }
        .overlay(alignment: .leading) {
            // Laid out (not merely drawn) one gap before the first tile, so the
            // focus engine finds it when searching from that tile.
            Color.clear
                .frame(width: 1, height: ProviderChoiceTile.size.height)
                .focusable(leadingGuardActive)
                .focused(focusedControl, equals: .backGuard)
                .accessibilityHidden(true)
                .alignmentGuide(.leading) { $0.width + ProviderChoiceTile.spacing }
        }
    }
}

private struct ProviderChoiceTile: View {
    static let size = CGSize(width: 236, height: 212)
    static let spacing: CGFloat = 30

    let provider: ProviderKind
    var isLoading = false
    let focusedControl: FocusState<ProviderChooserFocus?>.Binding
    let action: () -> Void

    /// Media Share keeps its product name; the caption names the transports
    /// so the generic name still says what it connects to.
    private var caption: String? {
        guard provider == .mediaShare else { return nil }
        return [MediaShareTransportKind.smb, .webDAV, .nfs].map(\.badgeLabel).joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 20) {
                Group {
                    if isLoading {
                        ProviderLoadingIndicator()
                    } else {
                        ProviderBrandMark(provider: provider, size: 74, showsBackground: false)
                    }
                }
                .frame(width: 74, height: 74)

                // Provider names are brands: rendered verbatim so they are never
                // extracted as translatable copy, and derived from the provider so a
                // caller can't pass a name that disagrees with the logo above it.
                VStack(spacing: 6) {
                    Text(verbatim: provider.displayName)
                        .font(.system(size: 26, weight: .semibold))
                    if let caption {
                        Text(verbatim: caption)   // l10n:content — transport protocol names
                            .font(.system(size: 19, weight: .medium))
                            .settingsRowSecondary()
                    }
                }
                .lineLimit(1)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .contentShape(RoundedRectangle(cornerRadius: ProviderChoiceTileStyle.cornerRadius, style: .continuous))
        }
        .buttonStyle(ProviderChoiceTileStyle())
        .focused(focusedControl, equals: ProviderChooserFocus(provider: provider))
    }
}

/// Flat frosted tile at rest; the tvOS inverted card with a lift on focus.
private struct ProviderChoiceTileStyle: ButtonStyle {
    static let cornerRadius: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var focusFill: Color { colorScheme == .dark ? .white : .black }
        private var focusInk: Color { colorScheme == .dark ? Color(white: 0.08) : .white }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: ProviderChoiceTileStyle.cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(focusInk) : AnyShapeStyle(.primary))
                .environment(\.settingsRowIsFocused, isFocused)
                .environment(\.settingsRowFocusForeground, focusInk)
                .background {
                    if isFocused {
                        shape.fill(focusFill)
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 30)
                    } else {
                        Color.clear
                            .plozzFrostedBackground(shape, raised: true)
                            .plozzFrostedBorder(shape)
                    }
                }
                // The fill and ink switch instantly, like Settings rows; only
                // the lift eases.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18)) { tile in
                    tile.scaleEffect(isFocused ? (configuration.isPressed ? 1.04 : 1.08) : 1)
                }
        }
    }
}

private struct ProviderLoadingIndicator: View {
    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.settingsRowFocusForeground) private var focusForeground

    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .tint(isFocused ? focusForeground : .accentColor)
            .accessibilityLabel("Requesting a code")
    }
}

#endif
