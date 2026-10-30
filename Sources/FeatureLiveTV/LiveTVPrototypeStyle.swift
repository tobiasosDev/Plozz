import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

enum PrototypeLayout {
    static let gap = PlozzTheme.Spacing.medium
    static let smallGap = PlozzTheme.Spacing.xSmall
    static let radius = PlozzTheme.Metrics.cornerRadius
    static let sectionGap = PlozzTheme.Spacing.large
    static let cellGap = PlozzTheme.Spacing.xSmall
    // On touch the grid is one even mesh: rows, the logo column and programmes
    // all sit a programme-gap apart. The TV keeps wider row and column gaps.
    #if os(iOS)
    static let rowGap = cellGap
    static let columnGap = cellGap
    static let rowInset = PlozzTheme.Spacing.medium
    static let logoRadius = PlozzTheme.Metrics.Radius.content
    #else
    // The TV guide is the Apple TV app's: 88-point rows a small gap apart,
    // so four of them fit under the programme header.
    static let rowGap = PlozzTheme.Spacing.small
    static let columnGap = PlozzTheme.Spacing.medium
    static let rowInset = PlozzTheme.Spacing.small
    static let logoRadius = PlozzTheme.Spacing.xSmall
    #endif
    /// Concentric with the logo plate on a TV and a tablet. A phone's short
    /// rows (`compactRowHeight`) turned that radius into a full capsule, so
    /// its cells get the TV's proportion instead: squarer, like the tvOS grid.
    static var rowRadius: CGFloat {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 14 : logoRadius + rowInset
        #else
        logoRadius + rowInset
        #endif
    }
    static let programInset: CGFloat = 0
    static var programRadius: CGFloat { rowRadius - programInset }
    static let horizontalFade = PlozzTheme.Spacing.large
    static let verticalFade = PlozzTheme.Spacing.xLarge
    static let minimumGuideOpacity = 0.05
    static let guideInset = PlozzTheme.Metrics.Radius.inset
    static let stationArtworkInset = guideInset + 8
    static let guideTrailingInset = guideInset
    static var guideRadius: CGFloat { rowRadius + guideInset }
    static let controlRadius = PlozzTheme.Metrics.Radius.control
    static let controlInset = PlozzTheme.Spacing.xSmall
    static let controlGroupRadius = controlRadius + controlInset
    #if os(tvOS)
    /// The Apple TV app's content keyline: header, chips and channels line up on it.
    static let keyline: CGFloat = 80
    static let inset = PlozzTheme.Spacing.xLarge
    static let stationSize: CGFloat = 64
    static let controlHeight: CGFloat = 56
    static let guideFontSize: CGFloat = 24
    static let detailFontSize: CGFloat = 19
    static let sectionFontSize: CGFloat = 22
    /// The channel number's slot ahead of the logo in the station cell.
    static let channelNumberWidth: CGFloat = 40
    /// Station logos sit on a wide plate beside their number.
    static let stationPlateAspect: CGFloat = 2.5
    static let programPadding: CGFloat = 20
    /// The programme header's fixed lines (see `PrototypeProgramHeader`), so
    /// moving between programmes never moves the guide below it.
    static let headerHeight: CGFloat = 352
    #else
    static let inset = PlozzTheme.Spacing.medium
    static let stationSize: CGFloat = 80
    static let controlHeight: CGFloat = 44
    static let guideFontSize: CGFloat = 16
    static let detailFontSize: CGFloat = 13
    static let sectionFontSize: CGFloat = 14
    static let stationPlateAspect: CGFloat = 1.75
    static let programPadding = rowInset
    #endif
    static let rowHeight = stationSize + rowInset * 2
    #if os(tvOS)
    static let stationColumnWidth = channelNumberWidth + stationSize * stationPlateAspect + rowInset * 3
    #else
    static let stationColumnWidth = stationSize * stationPlateAspect + rowInset * 2
    #endif
    static var guideShape: UnevenRoundedRectangle {
        #if os(tvOS)
        let bottom: CGFloat = 0
        let trailing: CGFloat = 0
        #else
        // Square along the bottom: the list fades out toward the tab bar
        // (see the guide's scroll fade) rather than being cut by a curve.
        let bottom: CGFloat = 0
        let trailing = guideRadius
        #endif
        return UnevenRoundedRectangle(
            topLeadingRadius: guideRadius, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: trailing
        )
    }

    /// Below this the guide is a phone's: a narrow channel column, shorter rows
    /// and one hour of programmes across the screen.
    static let compactWidth: CGFloat = 650

    // The guide's own vertical rhythm on touch is a step tighter than the
    // TV's: section labels and the time ruler read at arm's length, and every
    // point they give back is guide.
    #if os(iOS)
    static let sectionLabelHeight: CGFloat = 22
    static let rulerHeight: CGFloat = 28
    static let sectionLabelGap: CGFloat = 2
    static let toolbarGuideGap: CGFloat = 4
    static let rulerGap: CGFloat = 4
    #else
    static let sectionLabelHeight: CGFloat = 44
    static let rulerHeight: CGFloat = 44
    static let sectionLabelGap: CGFloat = rowGap
    static let toolbarGuideGap: CGFloat = sectionGap
    static let rulerGap: CGFloat = gap
    #endif
    static let chipHeight: CGFloat = 50
    static let compactStationWidth: CGFloat = 88
    static let compactRowHeight: CGFloat = 64

    static func isCompact(_ width: CGFloat) -> Bool { width < compactWidth }

    /// A phone keeps its short rows and narrow channel column on its side too:
    /// landscape has no more height than portrait has width, so full-size rows
    /// left room for barely one. The extra width goes to programme time
    /// instead (`viewportSeconds` stays width-based).
    static func usesCompactRows(_ width: CGFloat) -> Bool {
        #if os(iOS)
        isCompact(width) || UIDevice.current.userInterfaceIdiom == .phone
        #else
        isCompact(width)
        #endif
    }

    static func stationWidth(for width: CGFloat) -> CGFloat {
        usesCompactRows(width) ? compactStationWidth : stationColumnWidth
    }

    static func rowHeight(for width: CGFloat, scaledHeight: CGFloat) -> CGFloat {
        usesCompactRows(width) ? scaledHeight * compactRowHeight / rowHeight : scaledHeight
    }

    #if os(tvOS)
    static func guideSectionLabelHeight(fontSize: CGFloat) -> CGFloat {
        max(sectionLabelHeight, ceil(UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight))
    }
    #endif

    static func timelineWidth(for width: CGFloat) -> CGFloat {
        max(1, width - stationWidth(for: width) - columnGap)
    }

    /// How much programme time the visible timeline spans: two half-hour slots
    /// on a phone, four elsewhere.
    static func viewportSeconds(for width: CGFloat) -> TimeInterval {
        isCompact(width) ? 3_600 : 7_200
    }

    /// The scrollable guide starts with six hours whatever the viewport, and
    /// grows by the same step as the viewer nears its end.
    static let timelineSpanSeconds: TimeInterval = 21_600
    /// A week, matching how far ahead the guide cache keeps listings.
    static let maximumTimelineSpanSeconds: TimeInterval = 7 * 86_400

    /// Horizontal distance for a stretch of programme time.
    static func timelineX(_ seconds: TimeInterval, for width: CGFloat) -> CGFloat {
        timelineWidth(for: width) * seconds / viewportSeconds(for: width)
    }

    static func timelineContentWidth(
        for width: CGFloat, span: TimeInterval = timelineSpanSeconds
    ) -> CGFloat {
        timelineX(span, for: width)
    }

    static func maximumTimelineOffset(
        for width: CGFloat, span: TimeInterval = timelineSpanSeconds
    ) -> CGFloat {
        max(0, timelineContentWidth(for: width, span: span) - timelineWidth(for: width))
    }

    static func hoursCoveringTimelineOffset(_ offset: CGFloat, for width: CGFloat) -> Int {
        let initialHours = Int(timelineSpanSeconds / 3_600)
        guard width > 0, offset.isFinite else { return initialHours }
        let visibleEnd = Double(max(0, offset) / timelineWidth(for: width)) * viewportSeconds(for: width)
            + viewportSeconds(for: width)
        let cappedEnd = min(maximumTimelineSpanSeconds, visibleEnd)
        guard cappedEnd.isFinite else { return Int(maximumTimelineSpanSeconds / 3_600) }
        return max(initialHours, Int(ceil(cappedEnd / timelineSpanSeconds)) * initialHours)
    }

    static func programHeight(in rowHeight: CGFloat) -> CGFloat {
        max(1, rowHeight - programInset * 2)
    }
}

extension LiveTVGuideSection {
    var title: LocalizedStringResource {
        switch self {
        case .recent: "Recently watched"
        case .favorites: "Favorites"
        case .channels: "Channels"
        }
    }
}

struct PrototypeScrollFade: Equatable {
    let leading: CGFloat
    let trailing: CGFloat

    init(before: CGFloat = 0, after: CGFloat = 0, distance: CGFloat = PrototypeLayout.verticalFade) {
        leading = min(1, max(0, before) / max(1, distance))
        trailing = min(1, max(0, after) / max(1, distance))
    }
}

extension LiveTVPrototypeSource {
    var title: Text {
        switch self {
        case .iptv: Text(verbatim: "IPTV")
        case .jellyfin: Text(verbatim: "Jellyfin")
        case .plex: Text(verbatim: "Plex")
        case .emby: Text(verbatim: "Emby")
        case .plozz: Text("Plozz channels")
        }
    }
}

extension LiveTVPrototypeScenario {
    var title: LocalizedStringResource {
        switch self {
        case .noGuide: "No guide"
        case .mixedGuide: "Partial guide"
        case .fullGuide: "Full guide"
        case .staleGuide: "Stale guide"
        case .failedGuide: "Guide unavailable"
        }
    }
}

extension LiveTVPrototypeSort {
    var title: LocalizedStringResource {
        switch self {
        case .channelNumber: "Channel number"
        case .name: "Name"
        }
    }
}

struct PrototypeStationMark: View {
    let channel: LiveTVPrototypeChannel
    var size: CGFloat = PrototypeLayout.stationSize
    var plateSize: CGSize? = nil
    var cornerRadius: CGFloat = PrototypeLayout.logoRadius
    var insetOverride: CGFloat? = nil

    private var dimensions: CGSize {
        plateSize ?? CGSize(width: size * 1.75, height: size)
    }

    private var artworkInset: CGFloat {
        insetOverride ?? (plateSize == nil ? 6 : PrototypeLayout.stationArtworkInset)
    }

    var body: some View {
        ChannelLogoArtwork(
            name: channel.name, logoURL: channel.logoURL, size: dimensions,
            cornerRadius: cornerRadius, artworkInset: artworkInset,
            plozzChannelID: channel.source == .plozz ? channel.id : nil,
            plozzChannelMood: channel.plozzChannelMood
        )
    }
}

struct PrototypeFocusOutline: View {
    let cornerRadius: CGFloat
    var color: Color = .white
    var lineWidth: CGFloat = 3.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A dark inner keyline keeps the white focus edge visible on pale logos.
        shape.strokeBorder(.black.opacity(0.9), lineWidth: lineWidth * 2)
            .overlay { shape.strokeBorder(color, lineWidth: lineWidth) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PrototypeButtonStyle: ButtonStyle {
    var selected = false
    var padded = true
    var surface: PrototypeButtonSurface = .standard
    var tier: PrototypeProgramTier = .future
    var focusChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        PrototypeButtonBody(
            configuration: configuration, selected: selected, padded: padded,
            surface: surface, tier: tier, focusChanged: focusChanged
        )
    }
}

enum PrototypeButtonSurface: Equatable {
    case standard, guide, station, program, control
}

/// Where a programme sits against the clock. The guide steps its cells from
/// dim (aired) through raised (on now) so the present reads without a fill.
enum PrototypeProgramTier: Equatable {
    case past, now, future

    init(start: Date, end: Date, now: Date) {
        self = end <= now ? .past : (start <= now ? .now : .future)
    }
}

private struct PrototypeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let padded: Bool
    let surface: PrototypeButtonSurface
    let tier: PrototypeProgramTier
    let focusChanged: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var solidFocus: Bool {
        #if os(tvOS)
        // Every focused guide cell is the Apple TV app's: solid, with dark ink.
        focused
        #else
        focused && surface != .station
            && ((surface != .guide && surface != .program) || reduceTransparency || contrast == .increased)
        #endif
    }

    private var emphasis: Double { reduceTransparency || contrast == .increased ? 1.5 : 1 }

    private var cornerRadius: CGFloat {
        switch surface {
        case .standard: PrototypeLayout.radius
        case .guide, .station: PrototypeLayout.rowRadius
        case .program: PrototypeLayout.programRadius
        case .control: PrototypeLayout.controlRadius
        }
    }

    private var fill: Color {
        if solidFocus { return palette.accent }
        if focused || selected { return palette.fill }
        switch surface {
        case .standard: return palette.cardSurface
        case .guide: return .clear
        case .station:
            #if os(tvOS)
            return palette.primaryText.opacity(0.06 * emphasis)
            #else
            return .clear
            #endif
        case .program:
            #if os(tvOS)
            switch tier {
            case .past: return palette.primaryText.opacity(0.07 * emphasis)
            case .now: return palette.primaryText.opacity(0.15 * emphasis)
            case .future: return palette.primaryText.opacity(0.1 * emphasis)
            }
            #else
            return palette.fillSubtle.opacity(reduceTransparency || contrast == .increased ? 1 : 0.45)
            #endif
        case .control: return .clear
        }
    }

    /// A tapped guide cell wears the focus outline, since touch has no focus
    /// of its own to show which programme the info bar is describing.
    private var showsTouchSelection: Bool {
        #if os(iOS)
        selected && (surface == .program || surface == .guide)
        #else
        false
        #endif
    }

    var body: some View {
        configuration.label
            .foregroundStyle(solidFocus ? palette.onAccent : palette.primaryText)
            .padding(padded ? PrototypeLayout.gap : 0)
            .background(
                fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if (focused || showsTouchSelection) && !solidFocus {
                    PrototypeFocusOutline(
                        cornerRadius: cornerRadius,
                        color: surface == .station ? .white : palette.primaryText,
                        lineWidth: contrast == .increased ? 4 : 3.5
                    )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(selected && !focused ? palette.accent.opacity(0.35) : .clear, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            // Directional entry gates remove candidates without dimming the rail.
            .transaction { $0.animation = nil }
            .onChange(of: focused, initial: true) { _, value in
                #if os(iOS)
                // Touch has no focus to lose: a tapped selection stands until
                // another tap replaces it, even as its row scrolls away and back.
                if value { focusChanged?(value) }
                #else
                focusChanged?(value)
                #endif
            }
    }
}

struct PrototypeGuideSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Color.clear.plozzSurface(.raised, cornerRadius: 0)
                    .clipShape(PrototypeLayout.guideShape)
            } else if gradientEnabled {
                Color.clear
            } else {
                PrototypeLayout.guideShape
                    .fill(LinearGradient(
                        stops: [
                            .init(color: palette.backgroundBase.opacity(PrototypeLayout.minimumGuideOpacity), location: 0),
                            .init(color: palette.backgroundBase.opacity(0.12), location: 0.2),
                            .init(color: palette.backgroundBase.opacity(0.4), location: 0.55),
                            .init(color: palette.backgroundBase.opacity(0.75), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One glass underlay, not a glass layer per programme or a focus-dependent style.
/// It can sit over the live preview, so it follows the player's glass setting:
/// devices that can't afford glass over video get the blur-free frosted fill.
struct PrototypeControlSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzReducePlayerGlass) private var reduceGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrototypeLayout.controlGroupRadius, style: .continuous)
        Group {
            if reduceTransparency {
                Color.clear.plozzSurface(.raised, cornerRadius: PrototypeLayout.controlGroupRadius)
            } else if reduceGlass {
                Color.clear.plozzFrostedBackground(shape).plozzFrostedBorder(shape)
            } else {
                Color.clear.plozzGlassPanel(cornerRadius: PrototypeLayout.controlGroupRadius)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The programme header's actions and the category chips. They sit over the
/// programme art or the live preview, so at rest they are a flat see-through
/// fill with a hairline edge, never glass: nothing samples the video behind
/// them. Focus is the Apple TV's solid white with dark ink and a small lift.
struct PrototypeHeaderButtonStyle: ButtonStyle {
    enum Shape { case capsule, circle, chip }
    var shape: Shape = .capsule
    /// Watch Live: solid at rest too, the page's one filled action.
    var prominent = false
    /// A chosen chip keeps its fill when focus moves on.
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        PrototypeHeaderButtonBody(
            configuration: configuration, shape: shape, prominent: prominent, selected: selected)
    }
}

private struct PrototypeHeaderButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: PrototypeHeaderButtonStyle.Shape
    let prominent: Bool
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var solid: Bool { focused || prominent }

    private var ink: Color {
        if solid { return palette.onAccent }
        return shape == .chip && !selected ? palette.secondaryText : palette.primaryText
    }

    var body: some View {
        Group {
            switch shape {
            case .circle: surfaced(Circle())
            case .capsule, .chip: surfaced(Capsule(style: .continuous))
            }
        }
        .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.06 : 1))
        // A plain filled shape's shadow, only while lifted.
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: focused ? 16 : 0, y: focused ? 10 : 0)
        // Not dimmed when disabled: the guide disables the header while it has
        // focus. An action that can't run says so itself.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
    }

    private func surfaced<S: InsettableShape>(_ outline: S) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .background {
                if solid {
                    outline.fill(palette.accent)
                } else if shape != .chip || selected {
                    if reduceTransparency {
                        outline.fill(palette.cardSurface)
                            .overlay { outline.strokeBorder(palette.cardBorder, lineWidth: 1) }
                    } else {
                        outline.fill(palette.primaryText.opacity(0.14)).plozzFrostedBorder(outline)
                    }
                }
            }
            .contentShape(outline)
    }
}

enum PrototypeSheet: Identifiable {
    case filters, sources, guideTime, addPlaylist, serverSetup, multiviewFavorites, organization
    case program(LiveTVPrototypeProgram)
    case diagnostics(PlaybackDiagnosticReport)

    var id: String {
        switch self {
        case .filters: "filters"
        case .organization: "organization"
        case .sources: "sources"
        case .addPlaylist: "add-playlist"
        case .serverSetup: "server-setup"
        case .guideTime: "guide-time"
        case .multiviewFavorites: "multiview-favorites"
        case .program(let program): program.id
        case .diagnostics: "diagnostics"
        }
    }
}
