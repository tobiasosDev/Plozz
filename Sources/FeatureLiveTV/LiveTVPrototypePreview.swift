import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypePreviewLayout {
    let bounds: CGRect
    let contentFrame: CGRect
    let heroHeight: CGFloat
    let videoFrame: CGRect
    let fadeEnd: CGFloat
    let metadataWidth: CGFloat
    let compact: Bool
    /// A phone on its side: wide enough for the TV's side-by-side info bar,
    /// but with so little height that the bar has to be one short strip and
    /// the gaps tighten, or the guide below it shows barely a row.
    let short: Bool
    let hidesSidebar: Bool
    /// How far the phone's guide reaches past the content margins on each
    /// side, halving the dead space beside the logos and the trailing fade.
    /// Nothing where the edge is a notch or rounded-corner inset.
    let guideSideBleed: CGFloat
    private let isSearching: Bool

    var videoReflectionHeight: CGFloat {
        #if os(iOS)
        guard heroHeight > 0 else { return 0 }
        return min(videoFrame.height, (bounds.maxY - videoFrame.maxY) * 0.65)
        #else
        return 0
        #endif
    }

    var videoTopReflectionHeight: CGFloat {
        guard videoReflectionHeight > 0 else { return 0 }
        return min(videoFrame.height, max(0, videoFrame.minY - bounds.minY))
    }

    var videoLeadingReflectionWidth: CGFloat {
        guard videoReflectionHeight > 0 else { return 0 }
        return min(videoFrame.height, max(0, videoFrame.minX - bounds.minX))
    }

    var videoTrailingReflectionWidth: CGFloat {
        guard videoReflectionHeight > 0 else { return 0 }
        return min(videoFrame.height, max(0, bounds.maxX - videoFrame.maxX))
    }

    /// The gap between the info bar, the toolbar and the guide.
    var sectionGap: CGFloat { short || isSearching ? PrototypeLayout.smallGap : PrototypeLayout.sectionGap }

    var heroArtworkSize: CGSize {
        let height = max(0, min(heroHeight - PrototypeLayout.smallGap, compact ? 92 : 220))
        return CGSize(width: (height * 16 / 9).rounded(), height: height.rounded())
    }

    var heroAlignment: Alignment {
        #if os(tvOS)
        .topLeading
        #else
        .bottomLeading
        #endif
    }

    var availableSidebarWidth: CGFloat {
        #if os(tvOS)
        // A TV's categories are the chip row above the guide, so the guide and
        // the programme header both take the full width.
        return 0
        #else
        return Self.categorySidebarWidth(contentFrame.size)
        #endif
    }

    /// How far the header's programme art reaches down the page: behind the
    /// header and the category chips, fading out above the guide's ruler.
    var programArtHeight: CGFloat {
        (contentFrame.minY - bounds.minY) + heroHeight + sectionGap * 2 + PrototypeLayout.chipHeight
    }

    #if os(iOS)
    private static func hasRoomForCategorySidebar(_ size: CGSize) -> Bool {
        size.width >= 700 && size.height >= 500
    }

    private static func categorySidebarWidth(_ size: CGSize) -> CGFloat {
        guard hasRoomForCategorySidebar(size) else { return 0 }
        return size.width >= 1_400 ? 272 : (size.width >= 960 ? 224 : 200)
    }
    #endif

    var sidebarWidth: CGFloat { hidesSidebar ? 0 : availableSidebarWidth }

    var guideWidth: CGFloat {
        contentFrame.width - (sidebarWidth > 0 ? sidebarWidth + PrototypeLayout.sectionGap : 0)
    }

    var heroWidth: CGFloat {
        #if os(tvOS)
        guideWidth
        #else
        contentFrame.width
        #endif
    }

    var guideBottomExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxY - contentFrame.maxY)
        #else
        0
        #endif
    }

    var guideTrailingExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxX - contentFrame.maxX)
        #else
        guideSideBleed
        #endif
    }

    var guideLeadingExtension: CGFloat {
        #if os(tvOS)
        0
        #else
        guideSideBleed
        #endif
    }

    init(
        size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets(),
        navigationInset: CGFloat = 0, nativeNavigation: Bool = false,
        topNavigationInsets: EdgeInsets = EdgeInsets(),
        largeText: Bool = false, isSearching: Bool = false,
        hidesSidebar: Bool = false, showsCategories: Bool = false,
        showsVideoPreview: Bool = false, toolbarControlsBottom: CGFloat? = nil
    ) {
        #if os(tvOS)
        self.hidesSidebar = hidesSidebar
        #else
        self.hidesSidebar = false
        #endif
        bounds = CGRect(
            x: -safeAreaInsets.leading, y: -safeAreaInsets.top,
            width: size.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: size.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        compact = bounds.width < 650
        #if os(tvOS)
        let side: CGFloat = topNavigationInsets.top > 0 ? topNavigationInsets.trailing : 32
        // The rail and guide share physical-screen coordinates. Title-safe insets
        // can change during mounting and must not move or resize the pinned guide.
        // Without a rail, the header, chips and channels sit on the keyline (the
        // top bar's own when it has one); the guide's surface starts its inner
        // inset before it.
        let keyline = topNavigationInsets.top > 0 ? topNavigationInsets.leading : PrototypeLayout.keyline
        let leading = navigationInset > 0
            ? (topNavigationInsets.top > 0 ? topNavigationInsets.leading : 32) + PrototypeLayout.inset
            : keyline - PrototypeLayout.guideInset
        let top = max(32, topNavigationInsets.top > 0 ? topNavigationInsets.top : safeAreaInsets.top)
            + (nativeNavigation || topNavigationInsets.top > 0 ? 16 : 0)
        let bottom: CGFloat = 20
        guideSideBleed = 0
        #else
        let side = max(16, safeAreaInsets.trailing)
        let leading = max(16, safeAreaInsets.leading)
        guideSideBleed = side == 16 && leading == 16 && navigationInset == 0 ? 14 : 0
        let top = max(12, safeAreaInsets.top)
        let bottom = max(12, safeAreaInsets.bottom)
        #endif
        contentFrame = CGRect(
            x: bounds.minX + leading + navigationInset, y: bounds.minY + top,
            width: max(1, bounds.width - leading - side - navigationInset),
            height: max(1, bounds.height - top - bottom)
        )
        #if os(tvOS)
        short = false
        self.isSearching = isSearching
        #else
        short = !compact && !largeText && contentFrame.height < 500
        self.isSearching = isSearching || (showsCategories && !Self.hasRoomForCategorySidebar(contentFrame.size))
        #endif
        #if os(tvOS)
        let videoLeading = bounds.minX
        let videoWidth = bounds.width
        // The programme header: logo, title, subtitle, facts, time left, actions.
        let headerHeight = largeText ? min(contentFrame.height * 0.5, 480) : PrototypeLayout.headerHeight
        heroHeight = isSearching
            ? min(headerHeight, largeText ? 230 : 180)
            : headerHeight
        #else
        let categoryWidth = Self.categorySidebarWidth(contentFrame.size)
        let videoLeading = categoryWidth > 0
            ? contentFrame.minX + categoryWidth + PrototypeLayout.sectionGap - guideSideBleed
            : bounds.minX + safeAreaInsets.leading
        let videoWidth = max(1, bounds.maxX - safeAreaInsets.trailing - videoLeading)
        let previewTop = (toolbarControlsBottom ?? contentFrame.minY) + 8
        let previewHeight = min(videoWidth * 9 / 16, max(0, bounds.maxY - previewTop) * 0.48)
        heroHeight = self.isSearching || !showsVideoPreview
            ? 0 : max(0, previewTop + previewHeight - contentFrame.minY)
        #endif
        metadataWidth = compact || largeText ? contentFrame.width : contentFrame.width * 0.56
        #if os(iOS)
        let videoHeight = previewHeight
        let videoTop = previewTop
        #else
        let videoHeight = videoWidth * 9 / 16
        let videoTop = bounds.minY
        #endif
        videoFrame = CGRect(
            x: videoLeading,
            y: videoTop,
            width: videoWidth, height: videoHeight
        )
        fadeEnd = min(bounds.height * 0.82, videoHeight * 0.88)
    }
}

struct PrototypeVideoClip: Shape {
    var reflectionHeight: CGFloat
    var topReflectionHeight: CGFloat = 0
    var leftReflectionWidth: CGFloat = 0
    var rightReflectionWidth: CGFloat = 0
    var cornerRadius: CGFloat
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(reflectionHeight, topReflectionHeight),
                           AnimatablePair(AnimatablePair(leftReflectionWidth, rightReflectionWidth), cornerRadius))
        }
        set {
            reflectionHeight = newValue.first.first
            topReflectionHeight = newValue.first.second
            leftReflectionWidth = newValue.second.first.first
            rightReflectionWidth = newValue.second.first.second
            cornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: rect.minX - leftReflectionWidth, y: rect.minY - topReflectionHeight,
                                width: rect.width + leftReflectionWidth + rightReflectionWidth,
                                height: rect.height + reflectionHeight + topReflectionHeight),
             cornerRadius: cornerRadius)
    }
}

struct PrototypeGuideHitRegion: Shape {
    var top: CGFloat
    var sidebarWidth: CGFloat = 0
    var sidebarOnTrailing = false

    func path(in rect: CGRect) -> Path {
        var path = Path(CGRect(x: rect.minX, y: rect.minY + top, width: rect.width,
                               height: max(0, rect.height - top)))
        if sidebarWidth > 0 {
            path.addRect(CGRect(x: sidebarOnTrailing ? rect.maxX - sidebarWidth : rect.minX,
                                y: rect.minY, width: sidebarWidth, height: max(0, top)))
        }
        return path
    }
}

struct PrototypeBrowseLayout<Header: View, Sidebar: View, Guide: View>: View {
    let layout: PrototypePreviewLayout
    var extendsGuideToEdges = true
    @ViewBuilder let header: () -> Header
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let guide: () -> Guide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: layout.sidebarWidth > 0 ? PrototypeLayout.sectionGap : 0) {
            sidebarSlot
            VStack(spacing: layout.sectionGap) {
                header()
                guideSlot
            }
            .frame(width: layout.guideWidth)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: layout.hidesSidebar)
        #else
        HStack(alignment: .top, spacing: layout.sidebarWidth > 0 ? PrototypeLayout.sectionGap : 0) {
            sidebarSlot
            VStack(spacing: PrototypeLayout.smallGap) {
                header()
                guideSlot
            }
            .frame(width: layout.guideWidth)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: layout.heroHeight)
        #endif
    }

    @ViewBuilder private var sidebarSlot: some View {
        if layout.availableSidebarWidth > 0 {
            ZStack(alignment: .topLeading) {
                if layout.sidebarWidth > 0 {
                    sidebar()
                        .frame(width: layout.availableSidebarWidth)
                        #if os(tvOS)
                        // Button focus styling cancels leaf animations; move and fade the pane as one unit.
                        .geometryGroup()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        #endif
                }
            }
            .frame(width: layout.sidebarWidth, alignment: .leading)
            .clipped()
        }
    }

    private var guideSlot: some View {
        guide()
            .frame(width: layout.guideWidth + leadingExtension + trailingExtension)
            .padding(.leading, -leadingExtension)
            .padding(.trailing, -trailingExtension)
            .padding(.bottom, -layout.guideBottomExtension)
    }

    private var leadingExtension: CGFloat { extendsGuideToEdges ? layout.guideLeadingExtension : 0 }
    private var trailingExtension: CGFloat { extendsGuideToEdges ? layout.guideTrailingExtension : 0 }
}

struct PrototypeGuidePlacement<Content: View>: View {
    let frame: CGRect
    let canvasWidth: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(
                x: layoutDirection == .rightToLeft ? canvasWidth - frame.midX : frame.midX,
                y: frame.midY
            )
    }
}

/// The player stays mounted beneath this scrim; watching only removes the guide.
struct PrototypePreviewScrim: View {
    let layout: PrototypePreviewLayout
    let reduceTransparency: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    var body: some View {
        ZStack(alignment: .top) {
            HeroLegibilityScrim(
                tone: palette.backgroundBase, edgePeak: 0.96, wash: 0.08,
                edges: [.leading], bottomFadeTop: 0.3
            )
            if gradientEnabled {
                AppBackground(palette: palette)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                                .frame(height: layout.fadeEnd)
                            Color.white
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: (0 ... 24).map { step in
                            let t = Double(step) / 24
                            return .init(color: palette.backgroundBase.opacity(t * t * (3 - 2 * t)), location: t)
                        },
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: layout.fadeEnd)
                    palette.backgroundBase
                }
            }
            if reduceTransparency {
                palette.backgroundBase
                    .frame(width: layout.metadataWidth + 48, height: layout.heroHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, layout.contentFrame.minY - layout.bounds.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The guide's info bar: the programme's art (the channel's logo when the guide
/// has none) with the channel, title, a progress bar between the start and end
/// times, and "subtitle – description" beside it.
struct PrototypePreviewHero: View {
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let layout: PrototypePreviewLayout
    let watch: () -> Void
    var watchTitle: LocalizedStringResource?
    var isLoading = false
    var now = Date()
    var actions = PrototypeHeaderActions()
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        #if os(tvOS)
        Group {
            if isLoading {
                PrototypePreviewHeroSkeleton(layout: layout)
                    .clipped()
            } else {
                PrototypeProgramHeader(
                    channel: channel, program: program, now: now, layout: layout,
                    watch: watch, watchTitle: watchTitle, actions: actions
                )
            }
        }
        // Not clipped: the focused action lifts past the header's last line.
        .frame(width: layout.heroWidth, height: layout.heroHeight, alignment: layout.heroAlignment)
        #if DEBUG
        .modifier(PrototypeHeroLayoutObservation(phase: isLoading ? "loading" : "content"))
        #endif
        #else
        bar
        #endif
    }

    private var bar: some View {
        Group {
            if isLoading {
                PrototypePreviewHeroSkeleton(layout: layout)
            } else if let channel {
                if layout.compact {
                    compactBar(channel)
                } else if layout.short {
                    shortBar(channel)
                } else {
                    // Top-aligned in a box the art's height, so the art and the
                    // first line of text sit in the same place whatever the text
                    // or the image's own proportions turn out to be.
                    VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                        HStack(alignment: .top, spacing: PrototypeLayout.sectionGap) {
                            artwork(channel)
                            details(channel)
                                .frame(maxWidth: .infinity, maxHeight: artSize.height, alignment: .topLeading)
                                .clipped()
                        }
                        .frame(height: artSize.height, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(iOS)
                        watchButton
                        #endif
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: PrototypeLayout.rowGap) {
                    Text("Find your next channel")
                        .font(.title.weight(.semibold))
                    Text("Browse by channel, genre or what's on.")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                }
                .frame(width: layout.metadataWidth, alignment: .leading)
            }
        }
        .frame(width: layout.heroWidth, height: layout.heroHeight, alignment: layout.heroAlignment)
        .clipped()
        #if DEBUG
        .modifier(PrototypeHeroLayoutObservation(phase: isLoading ? "loading" : "content"))
        #endif
    }

    /// The TV's info bar squeezed into a phone's landscape strip: art, then
    /// the details, then Watch, all on one line so none of it needs a row of
    /// its own.
    private func shortBar(_ channel: LiveTVPrototypeChannel) -> some View {
        HStack(alignment: .center, spacing: PrototypeLayout.gap) {
            artwork(channel)
            details(channel)
                .frame(maxWidth: layout.metadataWidth, maxHeight: artSize.height, alignment: .leading)
                .clipped()
            #if os(iOS)
            watchButton
                .fixedSize()
            #endif
            Spacer(minLength: 0)
        }
        .frame(height: layout.heroHeight, alignment: .center)
    }

    private var artSize: CGSize {
        layout.heroArtworkSize
    }

    private var watchButton: some View {
        Button(action: watch) {
            Label {
                Text(watchTitle ?? "Watch channel")
            } icon: {
                Image(systemName: watchTitle == nil ? "play.fill" : "rectangle.split.2x2")
            }
        }
        #if os(iOS)
        .plozzActionButton(role: .secondary)
        #else
        .font(.subheadline.weight(.semibold))
        .plozzGlassPillButton()
        #endif
        .accessibilityIdentifier("live-tv-info-watch")
    }

    /// The phone's info bar, top to bottom: the art beside its channel and the
    /// Watch button, then the title, the progress bar between its times, and
    /// "subtitle – description". Every line keeps its place whether or not the
    /// guide has it, so tapping from programme to programme never reflows.
    private func compactBar(_ channel: LiveTVPrototypeChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: PrototypeLayout.gap) {
                artwork(channel)
                VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                    Text(channel.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                    watchButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(program?.title ?? channel.name)
                .font(.headline)
                .lineLimit(1)
            Group {
                if let program {
                    timing(program)
                } else {
                    Text(channel.category).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            Text(program?.playerInfo.summary ?? " ")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A fixed 16:9 plate with the art fitted inside it, never cropped or
    /// resized to the image: a poster and a wide still occupy the same box.
    private func artwork(_ channel: LiveTVPrototypeChannel) -> some View {
        let size = artSize
        return ZStack {
            palette.primaryText.opacity(0.06)
            if let url = program?.details?.artworkURL {
                FallbackAsyncImage(references: [.remote(url)]) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    logo(channel, size: size)
                }
            } else {
                logo(channel, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PrototypeLayout.logoRadius, style: .continuous))
        #if DEBUG
        .modifier(PrototypeBrowseLayoutObservation(element: "artwork"))
        #endif
        .accessibilityHidden(true)
    }

    private func logo(_ channel: LiveTVPrototypeChannel, size: CGSize) -> some View {
        PrototypeStationMark(channel: channel, plateSize: size)
    }

    private func details(_ channel: LiveTVPrototypeChannel) -> some View {
        VStack(alignment: .leading, spacing: layout.compact ? 2 : PrototypeLayout.smallGap) {
            Text(program == nil ? channel.category : channel.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            Text(program?.title ?? channel.name)
                .font((layout.compact ? Font.headline : Font.title3).weight(.semibold))
                .lineLimit(1)
            if let program {
                timing(program)
                if let summary = program.playerInfo.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(layout.compact || layout.short ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Start time, how far through the programme we are, end time.
    private func timing(_ program: LiveTVPrototypeProgram) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: PrototypeLayout.gap) {
                Text(verbatim: program.start.formatted(.dateTime.hour().minute().locale(locale)))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.secondaryText.opacity(0.35))
                        Capsule().fill(palette.primaryText)
                            .frame(width: geometry.size.width * program.progress(at: context.date))
                    }
                }
                .frame(maxWidth: layout.compact ? .infinity : 220)
                .frame(height: 6)
                Text(verbatim: program.end.formatted(.dateTime.hour().minute().locale(locale)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(program.start.formatted(.dateTime.hour().minute().locale(locale))) – \(program.end.formatted(.dateTime.hour().minute().locale(locale)))"))
        }
    }
}

/// What the TV header's buttons do. Fixtures that only show the bar leave
/// them out, and the header shows just the actions it was given.
struct PrototypeHeaderActions {
    var isFavorite = false
    var canToggleFavorite = true
    var toggleFavorite: (() -> Void)?
    var details: ((LiveTVPrototypeProgram) -> Void)?
    var multiviews: (() -> Void)?
    var manageChannels: (() -> Void)?
    var filters: (() -> Void)?
    var sources: (() -> Void)?
    var guideTime: (() -> Void)?
    /// Reports focus entering the header, so the guide gates its re-entry.
    var focusChanged: ((Bool) -> Void)?
}

#if os(tvOS)
/// The Apple TV app's programme header: the channel's logo and a LIVE badge,
/// the programme title, its subtitle, facts and time left, and the actions.
/// Every line keeps its place whether or not the guide has it, so moving
/// between programmes never moves the buttons or the guide below.
struct PrototypeProgramHeader: View {
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let now: Date
    let layout: PrototypePreviewLayout
    let watch: () -> Void
    var watchTitle: LocalizedStringResource?
    var actions = PrototypeHeaderActions()
    @FocusState private var focused: Control?
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale

    private enum Control: Hashable { case watch, favorite, details, multiviews, more }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let channel {
                channelLine(channel)
                    .frame(height: 44)
                    .padding(.bottom, 18)
                Text(program?.title ?? channel.name)
                    .font(.system(size: 64, weight: .bold))
                    .kerning(-0.9)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 76, alignment: .leading)
                Text(verbatim: subtitle ?? " ")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(palette.primaryText.opacity(0.86))
                    .lineLimit(1)
                    .frame(height: 36, alignment: .leading)
                    .padding(.top, 6)
                facts(channel)
                    .frame(height: 30, alignment: .leading)
                    .padding(.top, 12)
                timing
                    .frame(height: 28, alignment: .leading)
                    .padding(.top, 12)
            } else {
                Spacer(minLength: 0)
                Text("Find your next channel")
                    .font(.system(size: 48, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Browse by channel, genre or what's on.")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 8)
            }
            buttons
                .padding(.top, 24)
        }
        .foregroundStyle(palette.primaryText)
        .frame(width: layout.metadataWidth, alignment: .leading)
        .padding(.leading, PrototypeLayout.guideInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var subtitle: String? {
        guard let program else { return nil }
        let value = program.subtitle.isEmpty ? program.details?.episode : program.subtitle
        return value?.isEmpty == false ? value : nil
    }

    private var isOnNow: Bool {
        guard let program else { return true }
        return program.start <= now && now < program.end
    }

    private func channelLine(_ channel: LiveTVPrototypeChannel) -> some View {
        HStack(spacing: 16) {
            PrototypeStationMark(
                channel: channel, plateSize: CGSize(width: 110, height: 44),
                cornerRadius: PrototypeLayout.logoRadius, insetOverride: 4
            )
            if isOnNow { PrototypeLiveBadge() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(channel.name))
        .accessibilityValue(isOnNow ? Text("Live") : Text(verbatim: ""))
        #if DEBUG
        .modifier(PrototypeBrowseLayoutObservation(element: "artwork"))
        #endif
    }

    /// "Documentary · 20:05–21:05 · German" and the rating, when the guide has them.
    private func facts(_ channel: LiveTVPrototypeChannel) -> some View {
        HStack(spacing: 12) {
            let genre = program?.details?.categories.first ?? channel.category
            if !genre.isEmpty {
                Text(verbatim: genre)
                separator
            }
            if let program {
                Text(verbatim: "\(clock(program.start))–\(clock(program.end))")
                    .monospacedDigit()
            } else {
                Text("No listing", comment: "Programme header when the guide has nothing for this channel now.")
            }
            if let language = program?.details?.languages.first {
                separator
                Text(verbatim: locale.localizedString(forLanguageCode: language) ?? language)
            }
            if let rating = program?.details?.rating, !rating.isEmpty {
                Text(verbatim: rating)
                    .font(.system(size: 18, weight: .bold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(palette.primaryText.opacity(0.62), lineWidth: 2)
                    }
            }
        }
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(palette.primaryText.opacity(0.92))
        .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
    }

    /// The progress bar and time left while it airs, otherwise when it starts.
    @ViewBuilder private var timing: some View {
        if let program, isOnNow {
            HStack(spacing: 14) {
                Capsule().fill(palette.primaryText.opacity(0.32))
                    .frame(width: 260, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(palette.primaryText)
                            .frame(width: 260 * program.progress(at: now))
                    }
                    .accessibilityHidden(true)
                Text("\(duration(program.end.timeIntervalSince(now))) left",
                     comment: "Time remaining in the programme airing now. The argument is a duration such as 33 min.")
            }
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(palette.secondaryText)
        } else if let program, program.start > now {
            Text("Starts in \(duration(program.start.timeIntervalSince(now)))",
                 comment: "When an upcoming programme begins. The argument is a duration such as 25 min.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.secondaryText)
        } else {
            Color.clear
        }
    }

    private var buttons: some View {
        HStack(spacing: 22) {
            if let channel {
                Button(action: watch) {
                    HStack(spacing: 14) {
                        Image(systemName: watchTitle == nil ? "play.fill" : "rectangle.split.2x2")
                            .font(.system(size: 26, weight: .semibold))
                        Text(watchTitle ?? LocalizedStringResource(
                            "Watch Live", comment: "Programme header button that plays the channel live."))
                    }
                    .font(.system(size: 30, weight: .semibold))
                    .padding(.leading, 36)
                    .padding(.trailing, 44)
                    .frame(height: 66)
                }
                .buttonStyle(PrototypeHeaderButtonStyle(prominent: true))
                .focused($focused, equals: .watch)
                .accessibilityIdentifier("live-tv-info-watch")
                if let toggleFavorite = actions.toggleFavorite {
                    circle(
                        actions.isFavorite ? "star.fill" : "star",
                        label: actions.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        action: toggleFavorite
                    )
                    .focused($focused, equals: .favorite)
                    .disabled(!actions.canToggleFavorite)
                    .opacity(actions.canToggleFavorite ? 1 : 0.5)
                    .accessibilityAddTraits(actions.isFavorite ? .isSelected : [])
                    .accessibilityIdentifier("live-tv-favorite-\(channel.number)")
                }
                if let details = actions.details {
                    circle("info", label: "Program details") {
                        if let program { details(program) }
                    }
                    .focused($focused, equals: .details)
                    .disabled(program == nil)
                    .opacity(program == nil ? 0.5 : 1)
                    .accessibilityIdentifier("live-tv-program-details")
                }
            }
            if let multiviews = actions.multiviews {
                circle("square.grid.2x2", label: "Multiviews", action: multiviews)
                    .focused($focused, equals: .multiviews)
                    .accessibilityIdentifier("live-tv-multiview-favorites")
            }
            if actions.manageChannels != nil || actions.filters != nil
                || actions.sources != nil || actions.guideTime != nil {
                Menu {
                    if let manageChannels = actions.manageChannels {
                        Button("Manage channels", systemImage: "slider.horizontal.3", action: manageChannels)
                            .accessibilityIdentifier("live-tv-manage-channels")
                    }
                    if let filters = actions.filters {
                        Button("Filters", systemImage: "line.3.horizontal.decrease", action: filters)
                            .accessibilityIdentifier("live-tv-category")
                    }
                    if let sources = actions.sources {
                        Button("Sources", systemImage: "antenna.radiowaves.left.and.right", action: sources)
                            .accessibilityIdentifier("live-tv-sources")
                    }
                    if let guideTime = actions.guideTime, program != nil {
                        Button("Guide time", systemImage: "calendar", action: guideTime)
                            .accessibilityIdentifier("live-tv-guide-time")
                    }
                } label: {
                    Label {
                        Text("More", comment: "Live TV header menu with channel management, filters, sources and guide time.")
                    } icon: {
                        Image(systemName: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 66, height: 66)
                }
                .buttonStyle(PrototypeHeaderButtonStyle(shape: .circle))
                .focused($focused, equals: .more)
                .accessibilityIdentifier("live-tv-more")
            }
        }
        // Across the header's width, so Up from any chip beneath it enters it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Entering from the chips lands on the primary action. The header is
        // disabled while the guide has focus, so this never pulls focus out of it.
        .focusSection()
        .defaultFocus($focused, channel == nil ? .multiviews : .watch, priority: .userInitiated)
        .onChange(of: focused) { _, target in
            actions.focusChanged?(target != nil)
        }
    }

    private func circle(
        _ symbol: String, label: LocalizedStringResource, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label { Text(label) } icon: { Image(systemName: symbol) }
                .labelStyle(.iconOnly)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 66, height: 66)
        }
        .buttonStyle(PrototypeHeaderButtonStyle(shape: .circle))
    }

    private func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// Whole minutes, rounded up: a programme with 20 seconds to go has 1 min left.
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// The header's programme art across the top of the page. One image with its
/// fades painted in the page colour: no mask and no blur, so it costs one
/// decoded bitmap and two gradient fills, less than the live preview it
/// stands in for. Art waits for focus to settle before it loads.
struct PrototypeProgramBackdrop: View {
    let url: URL?
    let size: CGSize
    let textWidth: CGFloat
    @State private var shown: URL?
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown {
                FallbackAsyncImage(references: [.remote(shown)], variant: .heroBackdrop) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .id(shown)
                .transition(.opacity)
                LinearGradient(
                    stops: [
                        .init(color: palette.backgroundBase, location: 0),
                        .init(color: palette.backgroundBase.opacity(0.75), location: 0.22),
                        .init(color: palette.backgroundBase.opacity(0), location: 0.6)
                    ],
                    startPoint: .bottom, endPoint: .top
                )
                LinearGradient(
                    stops: reduceTransparency
                        ? [.init(color: palette.backgroundBase, location: 0),
                           .init(color: palette.backgroundBase, location: textReach),
                           .init(color: palette.backgroundBase.opacity(0), location: min(1, textReach + 0.15))]
                        : [.init(color: palette.backgroundBase.opacity(0.85), location: 0),
                           .init(color: palette.backgroundBase.opacity(0.5), location: 0.38),
                           .init(color: palette.backgroundBase.opacity(0), location: 0.64)],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: shown)
        .task(id: url) {
            // Passing over a row of programmes shouldn't decode each one's art.
            if shown != nil, url != nil {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            shown = url
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var textReach: CGFloat {
        size.width > 0 ? min(0.8, textWidth / size.width) : 0.5
    }
}
#endif

struct PrototypeLiveBadge: View {
    var compact = false

    var body: some View {
        Text("LIVE", comment: "Badge on a channel or programme airing now.")
            .font(.system(size: compact ? 15 : 17, weight: .bold))
            .kerning(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: compact ? 24 : 28)
            .background(PrototypeLiveBadge.red, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The Apple TV's live red, used for nothing else.
    static let red = Color(red: 1, green: 0.271, blue: 0.227)
}

struct PrototypeSearchSummary: View {
    let channelCount: Int
    let category: String?
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: PrototypeLayout.smallGap) {
            Text("\(channelCount) channels")
            if let category {
                Text("in \(category)", comment: "Search summary: channels in the named category or genre. %@ is a category, not a time duration.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
}
