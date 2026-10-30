#if os(tvOS)
import CoreUI
import SwiftUI

enum SettingsRootMetrics {
    /// The category list's column on the trailing side.
    static let listWidth: CGFloat = 940
    /// Below this, the preview is dropped and the list centres on its own
    /// (a pinned sidebar leaves too little room for both).
    static let minimumPreviewWidth: CGFloat = 560
    /// Keeps the preview optically centred in the space the list leaves.
    static let previewTrailingInset: CGFloat = 100
    static let tileSize: CGFloat = 400

    static func showsPreview(in width: CGFloat) -> Bool {
        width - listWidth >= minimumPreviewWidth
    }

    /// The part of `viewport` that is inside the screen's side margins. The top
    /// bar lays its pages out edge to edge and reports the title-safe margins as
    /// `plozzTopNavigationContentInsets`; the rail and sidebar already hand
    /// Settings a viewport inside them.
    static func usableWidth(viewport: CGFloat, insets: EdgeInsets) -> CGFloat {
        max(0, viewport - insets.leading - insets.trailing)
    }
    static let tileCornerRadius: CGFloat = 90
    static let descriptionWidth: CGFloat = 560
}

private struct SettingsRootShowsPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the root shows the focused category's preview beside the list,
    /// so rows can leave their explanatory subtitle to it.
    var settingsRootShowsPreview: Bool {
        get { self[SettingsRootShowsPreviewKey.self] }
        set { self[SettingsRootShowsPreviewKey.self] = newValue }
    }
}

/// The Settings root: a large preview of the focused category on the leading
/// side, and the list on the trailing side, like tvOS Settings.
///
/// The root page itself stays the stack's ordinary centred column, exactly as
/// before the split: a root layer of any other frame (full width, or a
/// trailing column) broke the shell's first-content focus handoff when
/// Settings is re-entered from the profile picker. Where the preview fits,
/// the list is drawn at the trailing margin with an offset and the preview
/// beside it, sized from the viewport the stack reports. The preview never
/// takes focus or hit tests, and only it observes the focused category, so
/// moving through the list re-renders the preview alone.
struct SettingsRootLayout<List: View, Preview: View>: View {
    @ViewBuilder var list: () -> List
    @ViewBuilder var preview: () -> Preview
    @Environment(\.settingsPageViewport) private var viewport
    @Environment(\.plozzTopNavigationContentInsets) private var sideInsets

    var body: some View {
        let usable = SettingsRootMetrics.usableWidth(viewport: viewport.width, insets: sideInsets)
        let showsPreview = SettingsRootMetrics.showsPreview(in: usable)
        let outset = SettingsRowCardMetrics.focusOutset
        let column = min(SettingsRootMetrics.listWidth, usable) - outset
        // From the centred page's leading edge to one focus outset before the
        // trailing margin; the focused card draws into that gap. Keeping the
        // scroll view off the title-safe edge also stops it adapting to the
        // safe area, which shifted it under the top bar.
        let page = min(SettingsFormMetrics.pageWidth, viewport.width)
        let trailingEdge = viewport.width - sideInsets.trailing
        let shift = showsPreview ? trailingEdge - outset - column - (viewport.width - page) / 2 : 0
        list()
            .frame(width: column)
            .environment(\.settingsRootShowsPreview, showsPreview)
            .background(alignment: .trailing) {
                if showsPreview {
                    // The spacer stands in for the column; the preview fills
                    // the space before it.
                    HStack(spacing: 0) {
                        preview()
                            .padding(.trailing, SettingsRootMetrics.previewTrailingInset)
                            .frame(width: usable - SettingsRootMetrics.listWidth)
                            .frame(maxHeight: .infinity)
                        Color.clear.frame(width: column)
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            .offset(x: shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsPreview ? .topLeading : .top)
    }
}

/// Icon tile and description for the category that last held focus.
struct SettingsRootPreview: View {
    let navigation: SettingsNavigationModel
    let profileName: String
    let everyoneScope: LocalizedStringResource

    var body: some View {
        let topic = SettingsRootTopic(route: navigation.section)
        // Updated instantly as focus moves: no animation and no transition, so
        // the focus engine never snapshots a view SwiftUI is tearing down (see
        // `SettingsSplitLayout.detailPane`).
        VStack(spacing: 46) {
            SettingsRootTile(topic: topic)
            VStack(spacing: 4) {
                if let summary = topic.summary {
                    Text(summary)
                }
                if topic.isShared {
                    Text(everyoneScope)
                } else {
                    Text(SettingsRootTopic.profileScope(profileName))
                }
            }
            .font(.system(size: 26))
            .lineSpacing(6)
            .plozzForeground(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: SettingsRootMetrics.descriptionWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 60)
    }
}

/// The gradient app-icon tile. Its shadow belongs to a separate shape that
/// never changes, so swapping the topic redraws only the gradient and glyph.
private struct SettingsRootTile: View {
    let topic: SettingsRootTopic

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsRootMetrics.tileCornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(Color.black)
                .padding(2)
                .shadow(color: .black.opacity(0.45), radius: 45, y: 40)
            shape.fill(LinearGradient(colors: topic.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            shape
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 3
                )
            Image(systemName: topic.symbol)
                .font(.system(size: 170, weight: .regular))
                .foregroundStyle(.white)
        }
        .frame(width: SettingsRootMetrics.tileSize, height: SettingsRootMetrics.tileSize)
    }
}

/// What the preview shows for a root destination.
struct SettingsRootTopic: Equatable {
    let symbol: String
    let colors: [Color]
    let summary: LocalizedStringResource?
    /// Household settings say who they reach instead of naming the profile.
    let isShared: Bool

    init(symbol: String, colors: [Color], summary: LocalizedStringResource?, isShared: Bool = false) {
        self.symbol = symbol
        self.colors = colors
        self.summary = summary
        self.isShared = isShared
    }

    static func profileScope(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Applies to \(name) only.",
            comment: "Settings root preview: the focused category belongs to the active profile. The placeholder is the profile's name."
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init(route: SettingsRoute) {
        switch route {
        case .playback:
            self.init(symbol: "play.rectangle.fill", colors: Self.blue, summary: LocalizedStringResource(
                "Audio, autoplay and Up Next, skipping intros and credits, and seeking.",
                comment: "Settings root preview describing the Playback category."
            ))
        case .subtitles:
            self.init(symbol: "captions.bubble.fill", colors: Self.teal, summary: LocalizedStringResource(
                "When subtitles appear, how they look, their language and downloads.",
                comment: "Settings root preview describing the Subtitles category."
            ))
        case .liveTV:
            self.init(symbol: "antenna.radiowaves.left.and.right", colors: Self.red, summary: LocalizedStringResource(
                "Your channels, the guide and how Live TV plays.",
                comment: "Settings root preview describing the Live TV category."
            ))
        case .myLibraries:
            self.init(symbol: "rectangle.stack.fill", colors: Self.orange, summary: LocalizedStringResource(
                "The servers and libraries this profile watches.",
                comment: "Settings root preview describing the Libraries category."
            ))
        case .appearance:
            self.init(symbol: "paintbrush.fill", colors: Self.purple, summary: LocalizedStringResource(
                "Theme, Liquid Glass, display size and card style.",
                comment: "Settings root preview describing the Appearance category. Liquid Glass is Apple's name for the translucent interface material."
            ))
        case .screensNavigation:
            self.init(symbol: "rectangle.3.group.fill", colors: Self.green,
                      summary: ProfileSettingsCategory.screensNavigation.summary)
        case .integrations:
            self.init(symbol: "link", colors: Self.pink, summary: ProfileSettingsCategory.trackers.summary)
        case .language:
            self.init(symbol: "globe", colors: Self.cyan, summary: LocalizedStringResource(
                "The language Plozz uses for menus and buttons.",
                comment: "Settings root preview describing the Language setting."
            ))
        case .profileAppearance, .profileSettings:
            self.init(symbol: "person.crop.circle.fill", colors: Self.blue, summary: LocalizedStringResource(
                "Name, avatar and PIN.",
                comment: "Settings root preview describing the active profile's own page."
            ))
        case .servers, .server, .serverUser, .plexUser:
            self.init(symbol: "server.rack", colors: Self.graphite, summary: LocalizedStringResource(
                "Add and manage the servers and shares Plozz plays from.",
                comment: "Settings root preview describing Everyone > Servers."
            ), isShared: true)
        case .profile:
            self.init(symbol: "person.2.fill", colors: Self.indigo, summary: LocalizedStringResource(
                "Who uses Plozz here, and signing in automatically.",
                comment: "Settings root preview describing Everyone > Profiles."
            ), isShared: true)
        case .topShelf:
            self.init(symbol: "rectangle.topthird.inset.filled", colors: Self.blue, summary: LocalizedStringResource(
                "What Plozz shows above its icon on the Home Screen.",
                comment: "Settings root preview describing Everyone > Top Shelf."
            ), isShared: true)
        case .parentalPIN, .parentalPINSetup, .grownUps:
            self.init(symbol: "figure.and.child.holdinghands", colors: Self.orange, summary: LocalizedStringResource(
                "One PIN that keeps Kids profiles inside their limits.",
                comment: "Settings root preview describing Everyone > Parental PIN."
            ), isShared: true)
        case .seerr, .seerUserPicker:
            self.init(symbol: "sparkles.tv.fill", colors: Self.purple, summary: LocalizedStringResource(
                "Request movies and shows, and see what's trending.",
                comment: "Settings root preview describing Everyone > Seerr, a media request service."
            ), isShared: true)
        case .syncSetup, .syncTroubleshooting:
            self.init(symbol: "icloud.fill", colors: Self.cyan, summary: LocalizedStringResource(
                "Profiles, settings and servers on all your devices.",
                comment: "Settings root preview describing Everyone > iCloud Sync."
            ), isShared: true)
        case .metadata, .metadataDiagnostics:
            self.init(symbol: "sparkles.rectangle.stack.fill", colors: Self.teal, summary: LocalizedStringResource(
                "Where Plozz finds extra artwork and details.",
                comment: "Settings root preview describing Everyone > Metadata Providers."
            ), isShared: true)
        default:
            self.init(symbol: "gearshape.fill", colors: Self.graphite, summary: nil, isShared: true)
        }
    }

    private static let blue = [Color(red: 0.25, green: 0.62, blue: 1.0), Color(red: 0.04, green: 0.40, blue: 0.95)]
    private static let teal = [Color(red: 0.25, green: 0.82, blue: 0.85), Color(red: 0.0, green: 0.52, blue: 0.70)]
    private static let red = [Color(red: 1.0, green: 0.45, blue: 0.35), Color(red: 0.90, green: 0.16, blue: 0.27)]
    private static let orange = [Color(red: 1.0, green: 0.80, blue: 0.30), Color(red: 1.0, green: 0.50, blue: 0.10)]
    private static let purple = [
        Color(red: 0.37, green: 0.36, blue: 0.90), Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 1.0, green: 0.22, blue: 0.37)
    ]
    private static let green = [Color(red: 0.40, green: 0.88, blue: 0.50), Color(red: 0.12, green: 0.62, blue: 0.40)]
    private static let pink = [Color(red: 1.0, green: 0.50, blue: 0.70), Color(red: 0.85, green: 0.20, blue: 0.45)]
    private static let cyan = [Color(red: 0.40, green: 0.80, blue: 1.0), Color(red: 0.10, green: 0.45, blue: 0.85)]
    private static let indigo = [Color(red: 0.55, green: 0.50, blue: 1.0), Color(red: 0.30, green: 0.25, blue: 0.80)]
    private static let graphite = [Color(red: 0.55, green: 0.58, blue: 0.64), Color(red: 0.25, green: 0.27, blue: 0.32)]
}
#endif
