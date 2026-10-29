#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

/// The fixed standard-size, borderless episode column used only on series detail.
///
/// `Equatable` so callers can wrap it in `.equatable()`, and that is a measured
/// requirement rather than a nicety. The card stores its `action` closure, and
/// closures never compare equal, so SwiftUI's structural check on the view value
/// always failed: EVERY card in the rail re-evaluated its body whenever the
/// parent did. `Self._printChanges()` on an A12 Apple TV recorded 2550
/// `@self changed` rebuilds against only 141 real focus changes — an 18×
/// amplification — and most of them fired during hero transitions, when nothing
/// about any card had changed at all.
///
/// Comparing the inputs is sound because everything the card draws is derived
/// from them: `presentation` is built from exactly this pair, and the body's
/// remaining direct reads are all off `item`. Focus and environment values are
/// separate graph dependencies, so they still invalidate the body normally —
/// `.equatable()` only short-circuits the *value* check.
///
/// The synopsis is always visible, as on the Apple TV app's episode rail. It
/// used to fade in 110 ms after focus, which cost a task, two state writes and
/// two animations on every card a focus move touched; its space was already
/// reserved, so showing it at rest changes no layout.
public struct EpisodeColumnCard: View, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.spoilerSettings == rhs.spoilerSettings
    }

    public static let artworkSize = CGSize(width: 480, height: 270)
    public static let trailingSpacing: CGFloat = 16
    public static let slotWidth = artworkSize.width + trailingSpacing

    private let item: MediaItem
    private let spoilerSettings: SpoilerSettings
    private let presentation: EpisodeColumnPresentation
    private let action: () -> Void

    @PlozzCardFocus private var isFocused: Bool
    #if os(tvOS)
    @State private var nativeArtwork = ArtworkResolutionState()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzCardCaptionsHidden) private var captionsHidden
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.detailHeaderSettings) private var detailSettings
    @Environment(\.plozzAppTextScale) private var appTextScale

    private let metrics = PlozzMetrics.standard
    private var textScale: CGFloat {
        #if os(tvOS)
        PlozzTypography.scale(local: detailSettings?.settings.textSize.scale ?? 1, app: appTextScale)
        #else
        1
        #endif
    }

    public init(
        item: MediaItem,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.spoilerSettings = spoilerSettings
        self.presentation = EpisodeColumnPresentation(
            item: item,
            spoilerSettings: spoilerSettings
        )
        self.action = action
    }

    public var body: some View {
        let _ = plozzTraceBodyChanges { Self._printChanges() }
        VStack(alignment: .leading, spacing: 0) {
            episodeArtwork
            if !captionsHidden {
                episodeCaption
            }
        }
        .frame(width: Self.artworkSize.width, alignment: .leading)
        .padding(.trailing, Self.trailingSpacing)
        .focusableCard(
            isFocused: $isFocused,
            cornerRadius: metrics.landscapeCardCornerRadius,
            nativeFocusInContent: true,
            action: action
        )
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused, animates: !reduceMotion)
        .mediaItemContextMenu(for: item)
        .environment(\.plozzCardStyle, .borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var episodeCaption: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow = presentation.eyebrowLine {
                eyebrow
                    .font(.system(size: PlozzTypography.episodeDescription.scaled(by: textScale).pointSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush)
                    .padding(.bottom, 4)
            }
            presentation.titleLine
                .font(.system(size: PlozzTypography.episodeTitle.scaled(by: textScale).pointSize, weight: .semibold))
                .foregroundStyle(presentation.isUpcoming ? .secondary : .primary)
                .lineLimit(1)
                .padding(.top, presentation.eyebrowLine == nil
                    ? metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush : 0)

            SpoilerSafeOverviewText(
                overview: presentation.overviewTreatment == .blurred
                    ? item.overview
                    : presentation.visibleOverview,
                hidesSpoilers: presentation.overviewTreatment == .blurred
                    || presentation.overviewTreatment == .placeholder,
                mode: spoilerSettings.mode,
                // The eyebrow takes the line the synopsis gives up, so the
                // caption keeps its height.
                lineCount: presentation.eyebrowLine == nil ? 3 : 2,
                fontSize: PlozzTypography.episodeDescription.scaled(by: textScale).pointSize,
                lineSpacing: PlozzTypography.episodeDescription.scaled(by: textScale).lineSpacing,
                maxWidth: Self.artworkSize.width
            )
            .padding(.top, 10)
        }
        .offset(y: reduceMotion || isFocused ? 0 : -metrics.focusCaptionPush)
        .animation(
            reduceMotion ? nil : PlozzTheme.Metrics.cardFocusAnimation(
                isFocused: isFocused, focusStyle: focusStyle, reduceMotion: reduceMotion
            ),
            value: isFocused
        )
    }

    @ViewBuilder
    private var episodeArtwork: some View {
        #if os(tvOS)
        if focusStyle.usesSystemEffect {
            nativeEpisodeArtwork
        } else {
            customEpisodeArtwork
        }
        #else
        customEpisodeArtwork
        #endif
    }

    private var customEpisodeArtwork: some View {
        realArtwork
            .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
            .background { if presentation.isUpcoming { palette.cardSurface } }
            .overlay { episodeOverlays }
            .plozzCardArtworkClip(RoundedRectangle(cornerRadius: metrics.landscapeCardCornerRadius, style: .continuous))
            .plozzMediaEdge(
                cornerRadius: metrics.landscapeCardCornerRadius,
                isEnabled: MediaArtworkPlaceholder.Symbol(for: item) == .playback
            )
            .plozzFocusHalo(
                cornerRadius: metrics.landscapeCardCornerRadius,
                focusScale: reduceMotion ? 1 : PlozzTheme.Metrics.mediumFocusedCardScale,
                isFocused: isFocused
            )
    }

    private var episodeOverlays: some View {
        episodeOverlayContent
            .overlay(alignment: .topTrailing) { statusIndicator }
    }

    private var episodeOverlayContent: some View {
        ZStack {
            if presentation.isUpcoming, let air = item.upcomingReleaseText {
                VStack(spacing: 8) {
                    if captionsHidden {
                        presentation.titleLine
                            .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .foregroundStyle(.white)
                    }
                    Label(air, systemImage: "clock")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 12)
            }
            // Once the caption names the runtime ("Episode 3 · 45m") the artwork
            // only needs the chip for an episode in progress.
            if presentation.artworkTreatment != .blurred,
               presentation.eyebrowLine == nil || item.resumeProgressFraction != nil {
                ResumeChipOverlay(item: item).plozzChromeFocused(isFocused)
            }
        }
    }

    #if os(tvOS)
    private var nativeEpisodeArtwork: some View {
        let source = EpisodeArtworkSource(
            item: item, spoilerSettings: spoilerSettings, policy: artworkPolicy.forArea(.episodes)
        )
        let treatment: NativePosterImageTreatment = presentation.isUpcoming
            ? .upcoming(palette.cardSurface)
            : (presentation.artworkTreatment == .blurred ? .blurred : .original)
        return NativeTVPoster(
            image: nativeArtwork.image, treatment: treatment,
            aspectRatio: Self.artworkSize.width / Self.artworkSize.height,
            fallbackWidth: Self.artworkSize.width, title: nil, subtitle: nil,
            overlay: ZStack {
                if captionsHidden && nativeArtwork.image == nil { neutralPlaceholder }
                episodeOverlayContent
            },
            indicators: nativeStatusIndicator,
            focus: $isFocused, action: action
        )
        .focused($isFocused.focusState)
        .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
        .background {
            FallbackAsyncImage(
                references: source.references, variant: .landscapeCard,
                artworkPolicy: source.policy,
                asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity,
                content: { _ in Color.clear }, placeholder: { Color.clear }
            )
            .environment(\.artworkResolutionState, nativeArtwork)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
    #endif

    private var realArtwork: some View {
        let source = EpisodeArtworkSource(
            item: item, spoilerSettings: spoilerSettings, policy: artworkPolicy.forArea(.episodes)
        )
        return FallbackAsyncImage(
            references: source.references,
            variant: .landscapeCard,
            artworkPolicy: source.policy,
            asyncFallbackURL: source.fallbackURL,
            pinIdentity: source.pinIdentity,
            content: { image in
                ArtworkFillImage(image)
                    .blur(radius: presentation.artworkTreatment == .blurred ? 28 : 0)
                    .saturation(presentation.isUpcoming ? 0 : 1)
                    .opacity(presentation.isUpcoming ? 0.05 : 1)
            },
            placeholder: { neutralPlaceholder }
        )
        .showingPlaceholderWhileLoading(captionsHidden)
    }

    private var neutralPlaceholder: some View {
        MediaArtworkPlaceholder(
            symbol: .init(for: item), cornerRadius: metrics.landscapeCardCornerRadius,
            title: captionsHidden && !(presentation.isUpcoming && item.upcomingReleaseText != nil)
                ? presentation.titleLine : nil
        )
        .opacity(presentation.isUpcoming && !captionsHidden ? 0.05 : 1)
    }

    private var statusIndicator: some View {
        nativeStatusIndicator
    }

    private var nativeStatusIndicator: NativePosterIndicators {
        .episode(
            isWatched: presentation.isWatched, hasProgress: presentation.progress != nil,
            isVisible: presentation.artworkTreatment == .visible && !presentation.isUpcoming,
            style: watchStatusIndicator, badgeSize: metrics.watchedBadgeSize, flagSize: metrics.unwatchedFlagSize
        )
    }
}
#endif
