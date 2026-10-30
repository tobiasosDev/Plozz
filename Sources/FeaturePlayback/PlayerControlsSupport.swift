#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

struct ControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the transport block's (scrubber + buttons) height so the Style panel
/// can align its top margin to its side margin.
struct TransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports each panel's natural (unclipped) content height, **keyed by category**,
/// so the glass box can animate ONLY its clip window to that height. The rows are
/// laid out at full size and clipped to the animating frame, so they never
/// cross-fade or spill past the rounded border when a sub-screen adds/removes rows
/// — "animate the container, not what's inside".
///
/// The height is tagged with its owning `Category` because panels overlap during
/// the 0.2s open/close transition: a *closing* panel stays mounted and keeps
/// reporting its (tall) height while the *next* panel is already opening. Keying by
/// category lets the reader pick out only the currently-open panel's height, so a
/// closing panel can never size the panel that's replacing it (which caused short
/// menus like Audio to spawn tall and then animate down).
struct PanelBodyHeightKey: PreferenceKey {
    static let defaultValue: [PlayerControls.Category: CGFloat] = [:]
    static func reduce(
        value: inout [PlayerControls.Category: CGFloat],
        nextValue: () -> [PlayerControls.Category: CGFloat]
    ) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
struct ScrubBar: View {
    /// A thin line, the Apple TV app's scrubber: 8pt with the surface focused,
    /// a hair slimmer when focus has moved to the controls.
    private static let restingBarHeight: CGFloat = 6
    private static let focusedBarHeight: CGFloat = 8
    let model: PlayerControlsModel
    let palette: ThemePalette
    /// Horizontal distance from the scrub track's leading/trailing edge out to the
    /// screen edge, so the trickplay thumbnail can extend past the track (but not
    /// off-screen).
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// The track is the widest single piece of glass in the player, so it gives
    /// its up with the panel rather than staying behind as the one refracting
    /// element left on screen.
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)
            // The bar is "focused" whenever the scrub surface owns focus — the
            // controls are up and focus hasn't dropped to the button row below
            // (scrubbing counts as focused). Focused, the bar is full height,
            // the played fill is bright and the playhead is a thin upright line
            // standing proud of the track (3×26, the Apple TV app's playhead). Once
            // focus moves to the buttons the bar slims, the fill fades and the
            // playhead shortens toward the track.
            // `infoCardOpen` holds the bar in its focused shape for the whole Info
            // reveal. The bar is invisible behind the card, so its appearance there is
            // moot — but without this, focus returning to the surface as the card
            // closes resized the bar (and its playhead) on this view's own 0.2s
            // curve, while the cluster carrying it translated on the reveal's spring.
            // A thin line growing about its centre while sliding reads as arriving
            // from the wrong direction entirely.
            let focused = model.controlsVisible && (!model.controlBarVisible || model.controlBar.infoCardOpen)
            let barHeight: CGFloat = focused ? Self.focusedBarHeight : Self.restingBarHeight
            let knobWidth: CGFloat = focused && model.isScrubbing ? 4 : 3
            let knobHeight: CGFloat = focused ? (model.isScrubbing ? 34 : 26) : 16

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    PlayerScrubTrackSurface(height: barHeight)
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: width * CGFloat(model.bufferedFraction), height: barHeight)
                    UnevenRoundedRectangle(
                        topLeadingRadius: barHeight / 2,
                        bottomLeadingRadius: barHeight / 2,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                        .fill(Color.white.opacity(focused ? 0.95 : 0.6))
                        .frame(width: knobX, height: barHeight)
                }
                .mask {
                    PlayerSkipMarkerTrack(
                        segments: model.skipSegments.segments, duration: model.duration, height: barHeight,
                        restingHeight: Self.restingBarHeight
                    )
                    .equatable()
                }
                RoundedRectangle(cornerRadius: knobWidth / 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)

                if model.isScrubbing && model.hasPreviewFrame {
                    thumbnailPreview(width: width, knobX: knobX)
                        .transition(.thumbnailDismiss)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation(.easeOut(duration: 0.2), value: model.controlBarVisible)
            .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
        }
    }


    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        if let image = model.previewImage {
            // ~15% larger than the previous 420pt thumbnail.
            let thumbWidth: CGFloat = 483
            let aspect = previewAspect
            let thumbHeight = thumbWidth / aspect
            let corner: CGFloat = 18
            let border: CGFloat = 12
            // Account for glass border so visual left edge sits at x=0 (track edge).
            let visualWidth = thumbWidth + 2 * border
            let minX = visualWidth / 2
            let edgeMargin: CGFloat = 16
            let maxX = width + trailingInset - visualWidth / 2 - edgeMargin
            let clampedX = min(max(minX, knobX), max(minX, maxX))

            let content = Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            // Float the trickplay thumbnail above the scrub bar (bar is centred
            // at y=0 in this GeometryReader). `thumbnailLift` is the gap from the
            // bar centre to the *bottom* of the thumbnail — kept tight so the
            // preview hugs the bar.
            let thumbnailLift: CGFloat = 34
            Group {
                if #available(iOS 26.0, tvOS 26.0, *), !reducePanelGlass {
                    content
                        .padding(border)
                        .background {
                            PlayerNativeGlassSurface(RoundedRectangle(
                                cornerRadius: corner + border, style: .continuous
                            ))
                        }
                } else {
                    content
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .stroke(.white.opacity(0.85), lineWidth: border)
                        )
                }
            }
            .position(x: clampedX, y: -(thumbnailLift + thumbHeight / 2))
        }
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}

/// Keep per-sample clock reads out of the full controls tree without changing
/// the transport's established geometry or animation policies.
///
/// Three labels, the Apple TV app's timeline: the elapsed time under the
/// playhead, then "Ends at 21:04" and "−5:50" at the trailing edge. A tap on
/// the surface switches to clock mode — the wall clock under the playhead and
/// the finish time on the right — where "Ends at" would only repeat the
/// trailing label, so it steps aside and the row keeps two labels.
struct PlayerTimelineTimes: View {
    let model: PlayerControlsModel
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    /// The "Ends at" label's rendered width, for the collision fade. Measured
    /// from the visible label itself; it is localized copy, so it cannot be
    /// measured up front the way the bare times are.
    @State private var endsAtWidth: CGFloat = 0

    /// One size for every timeline label, shared with their synchronous width
    /// measurement (`PlayerControls.measuredTimeWidth`).
    static let fontSize: CGFloat = 24
    /// Space between "Ends at …" and the remaining time beside it.
    private static let trailingGap: CGFloat = 26

    var body: some View {
        let clockMode = model.timelineClock.isEnabled && !model.isScrubbing
        // Clock mode ticks every second as before. Otherwise the only wall-clock
        // reading is the minute-resolution "Ends at", which moves on its own
        // only while paused; once a minute is enough, and playback ticks
        // re-evaluate it in between anyway. Both stop with the controls hidden.
        TimelineView(PlayerClockSchedule(paused: !model.controlsVisible, everyMinute: !clockMode)) { context in
            let times = PlayerClockTimes(
                now: clockMode ? context.date : .now,
                position: clockMode ? model.currentSeconds : model.displaySeconds,
                duration: model.duration, speed: model.playbackSpeed,
                locale: locale, timeZone: timeZone
            )
            labels(clock: clockMode ? times : nil, endsAt: clockMode ? nil : times.end)
        }
    }

    private func labels(clock: PlayerClockTimes?, endsAt: LocalizedStringResource?) -> some View {
        let fadeGap: CGFloat = 16
        let curLabel = clock?.current ?? PlayerControls.timeLabel(model.displaySeconds)
        let remLabel = clock.map { $0.endTime ?? "--:--" }
            ?? ("\u{2212}" + PlayerControls.timeLabel(max(0, model.duration - model.displaySeconds)))
        let curW = PlayerControls.measuredTimeWidth(curLabel, pointSize: Self.fontSize)
        let remW = PlayerControls.measuredTimeWidth(remLabel, pointSize: Self.fontSize)
        return GeometryReader { geo in
            let width = geo.size.width
            let midY = geo.size.height / 2
            let knobX = width * CGFloat(model.progressFraction)
            let halfCur = curW / 2
            let centerX = min(max(knobX, halfCur), max(halfCur, width - halfCur))
            let currentRightEdge = centerX + halfCur
            let remainingLeftEdge = width - remW
            let glyphShown = !model.isScrubbing
                && (model.skipGesture.hintVisible || (model.isPaused && model.intendsPause) || model.isSeeking)
            let glyphReach: CGFloat = glyphShown ? 40 : 0
            let remainingHidden = currentRightEdge + glyphReach + fadeGap >= remainingLeftEdge
            // "Ends at" gives way first: it sits nearer the playhead, and the
            // remaining time is the one figure the viewer is scrubbing against.
            let endsAtHidden = remainingHidden
                || currentRightEdge + glyphReach + fadeGap >= remainingLeftEdge - Self.trailingGap - endsAtWidth

            Text(curLabel)
                .accessibilityIdentifier("player-timeline-current-time")
                .accessibilityLabel(clock == nil ? Text("Elapsed time") : Text("Current time"))
                .accessibilityValue(Text(verbatim: curLabel))
                .monospacedDigit()
                .font(.system(size: Self.fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .shadow(radius: 3)
                .overlay(alignment: .trailing) {
                    statusGlyph
                        .frame(width: 30, height: 30)
                        .offset(x: 40)
                        .opacity(model.isScrubbing ? 0 : 1)
                        .animation(
                            PlayerControls.transportFadeAnimation(scrubbing: model.isScrubbing),
                            value: model.isScrubbing
                        )
                }
                .position(x: centerX, y: midY)

            HStack(spacing: Self.trailingGap) {
                if let endsAt {
                    Text(endsAt)
                        .accessibilityIdentifier("player-timeline-ends-at")
                        .monospacedDigit()
                        .font(.system(size: Self.fontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize()
                        .shadow(radius: 3)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { endsAtWidth = $0 }
                        .opacity(endsAtHidden ? 0 : 1)
                        .animation(.easeOut(duration: 0.15), value: endsAtHidden)
                        .accessibilityHidden(endsAtHidden)
                }
                Text(remLabel)
                    .accessibilityIdentifier("player-timeline-end-time")
                    .accessibilityLabel(clock == nil ? Text("Remaining time") : Text("Estimated end time"))
                    .accessibilityValue(Text(verbatim: remLabel))
                    .monospacedDigit()
                    .font(.system(size: Self.fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                    .shadow(radius: 3)
                    .opacity(remainingHidden ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: remainingHidden)
            }
            .frame(width: width, alignment: .trailing)
            .position(x: width / 2, y: midY)
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        if model.skipGesture.hintVisible {
            Image(systemName: model.skipGesture.hintForward
                ? model.skipGesture.forwardInterval.forwardSymbol
                : model.skipGesture.backwardInterval.backwardSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if model.isSeeking {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else if model.isPaused && model.intendsPause && !model.isScrubbing {
            // A preview pause is not user intent; never flash it at seek commit.
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
        }
    }
}

/// The Info-card action-button style: an **instant** focus treatment (no fade).
/// The stock `.glass` / `.borderedProminent` styles animate their own focus
/// highlight, which can't be disabled from outside — so the Info card draws its
/// own capsule and swaps fill/foreground on the same frame focus changes.
/// `.animation(nil, value: focused)` guarantees the swap never rides an ambient
/// transaction. Icon-only at rest; the label reveals with the button on focus
/// (instant, so the row never janks mid-expand).
struct InfoActionButtonStyle: ButtonStyle {
    /// Read native focus locally unless a caller supplies its own focus state.
    var focused: Bool? = nil
    let prominent: Bool
    /// Scaled with the card — a capsule sized for a three-metre viewing distance
    /// is most of a phone's card height on its own.
    var hPadding: CGFloat = 22
    var vPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(
            configuration: configuration, focused: focused, prominent: prominent,
            hPadding: hPadding, vPadding: vPadding
        )
    }

    private struct ActionBody: View {
        let configuration: ButtonStyle.Configuration
        let focused: Bool?
        let prominent: Bool
        let hPadding: CGFloat
        let vPadding: CGFloat
        @Environment(\.isFocused) private var nativeFocus
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let hasFocus = focused ?? nativeFocus
            let foreground: Color = colorScheme == .light ? .black : .white
            let fill = hasFocus ? foreground : foreground.opacity(prominent ? 0.24 : 0.12)
            return configuration.label
                .foregroundStyle(hasFocus ? (colorScheme == .light ? Color.white : .black) : foreground)
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(Capsule(style: .continuous).fill(fill))
                .clipShape(Capsule(style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(nil, value: hasFocus)
        }
    }
}

/// The Info tab's button style.
///
/// Looks like the transport's other capsule controls, but is drawn here so it
/// **ignores `\.isEnabled`** — the repo's established way to take a control out of
/// the focus order without greying it (see `FocusGatedSwitch` /
/// `SettingsFocusButtonStyle` in CoreUI). The tab needs that because it is only
/// focusable while its card is open, yet must look completely normal the rest of
/// the time. Focus colours swap instantly, like the Info card's own actions.
/// One type scale for both bottom-card tabs.
///
/// The Info panel was on semantic fonts and the Cast pane on fixed point sizes,
/// so the two tabs of one card set text at different sizes — and since they
/// swap in place, that difference is visible as a jump rather than as variety.
///
/// Fixed sizes rather than semantic ones because tvOS has no user text-size
/// control for them to answer to, and because the card's height is a hard
/// constant: a layout budget cannot be reasoned about in terms that might change
/// underneath it. The semantic values these replace were `.headline` (45.35pt
/// per line) and `.footnote` (34.61) — both a size larger than this card, at
/// three metres, actually needs.
/// The scrub bar's base track: native Liquid Glass on 26+, or a subdued
/// flat track when accessibility reduces glass and on older systems.
///
/// Shared by the remote and touch scrub bars. They had drifted apart — the touch
/// one drew a plain white fill — which is how the same control ended up looking
/// like two different controls on two platforms.
public struct PlayerScrubTrackSurface: View {
    public let height: CGFloat
    static let flatFillOpacity = 0.22
    static let glassBackingOpacity = 0.10

    @Environment(\.playerUsesNativeGlass) private var usesNativeGlass
    public init(height: CGFloat) {
        self.height = height
    }

    public var body: some View {
        if #available(iOS 26.0, tvOS 26.0, *), usesNativeGlass {
            #if os(iOS)
            PlayerNativeGlassSurface(Capsule(), glass: .clear)
                .frame(height: height)
            #else
            PlayerNativeGlassSurface(Capsule())
                .frame(height: height)
                .background {
                    Capsule().fill(.white.opacity(Self.glassBackingOpacity))
                }
            #endif
        } else {
            Capsule()
                .fill(.white.opacity(Self.flatFillOpacity))
                .frame(height: height)
        }
    }
}

/// Standalone transport backing. Grouped controls leave surface ownership to
/// their shared capsule instead of nesting glass.
public struct PlayerGlassCircleSurface: View {
    /// A brighter resting surface, for a control that is a call to action.
    private let raised: Bool
    @Environment(\.playerControlsGrouped) private var grouped
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    public init(raised: Bool = false) {
        self.raised = raised
    }

    public var body: some View {
        let shape = Circle()
        if grouped {
            Color.clear
        } else if reducePanelGlass || reduceTransparency {
            shape
                .fill(.clear)
                .plozzFrostedBackground(shape, raised: raised)
                .plozzFrostedBorder(shape)
        } else if #available(iOS 26.0, tvOS 26.0, *) {
            #if os(iOS)
            PlayerNativeGlassSurface(shape, glass: .clear)
            #else
            PlayerNativeGlassSurface(shape, glass: raised ? .regular.tint(.white.opacity(0.30)) : .regular)
            #endif
        } else {
            shape.fill(.clear).plozzFrostedBackground(shape, raised: raised).plozzFrostedBorder(shape)
        }
    }
}

/// Mobile transport uses untinted clear glass over video; tvOS keeps regular
/// glass. Both retain the theme-aware reduced-effects fallback.
public struct PlayerGlassCircleButtonStyle: ButtonStyle {
    /// The button's full circular size, which is also its touch target.
    public let diameter: CGFloat
    /// tvOS: draw the focused look while unfocused — the track control whose
    /// menu is open, which leaves the focus order while its menu holds focus.
    public var highlighted: Bool
    /// tvOS: a brighter resting surface for a call to action (Live TV's Go
    /// Live), distinct from the focused look so it never reads as focus.
    public var prominent: Bool
    @Environment(\.playerControlsGrouped) private var grouped
    @Environment(\.playerUsesNativeGlass) private var nativeGlass
    @Environment(\.playerControlForeground) private var foreground

    public init(diameter: CGFloat, highlighted: Bool = false, prominent: Bool = false) {
        self.diameter = diameter
        self.highlighted = highlighted
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        Group {
            if grouped {
                label(configuration)
            } else {
                #if os(iOS)
                if nativeGlass, #available(iOS 26.0, *) {
                    label(configuration)
                        .glassEffect(.clear.interactive(), in: Circle())
                } else {
                    label(configuration)
                        .background { PlayerGlassCircleSurface() }
                        .clipShape(Circle())
                }
                #else
                FocusableCircle(
                    configuration: configuration, diameter: diameter, highlighted: highlighted,
                    prominent: prominent
                )
                #endif
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: grouped ? 0 : diameter / 2))
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
    }

    #if os(tvOS)
    /// The remote's focus treatment, which a custom style has to draw itself:
    /// solid white with page-colour ink and a small lift, the Apple TV app's
    /// focused control. The surface swaps on the same frame focus moves, like
    /// the tab pills beside it; only the lift is animated.
    ///
    /// No shadow under the lifted circle, for the reason `PanelGlassBackground`
    /// gives: a soft shadow over the moving HDR picture is a per-frame
    /// offscreen pass, and the white fill reads on any frame without one.
    private struct FocusableCircle: View {
        let configuration: ButtonStyle.Configuration
        let diameter: CGFloat
        let highlighted: Bool
        let prominent: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.playerControlForeground) private var foreground
        @Environment(\.themePalette) private var palette

        var body: some View {
            let lit = isFocused || highlighted
            configuration.label
                .foregroundStyle(lit ? palette.backgroundBase : foreground)
                .frame(width: diameter, height: diameter)
                .background {
                    if lit {
                        Circle().fill(Color.white)
                    } else {
                        PlayerGlassCircleSurface(raised: prominent)
                    }
                }
                .clipShape(Circle())
                .animation(nil, value: lit)
                .scaleEffect(lit ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: lit)
        }
    }
    #endif
}

/// The round, icon-only track control above the scrub bar — Playback · Audio ·
/// Subtitles · Version, the Apple TV app's track buttons — shared by the
/// on-demand and live transports so both players draw the same control.
///
/// `highlighted` keeps the focused look on the control whose menu is open;
/// `prominent` raises the resting surface of a call to action (Go Live).
struct PlayerTrackControlButton: View {
    static let diameter: CGFloat = 72

    let title: LocalizedStringResource
    let systemImage: String
    var highlighted = false
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .medium))
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(
            diameter: Self.diameter, highlighted: highlighted, prominent: prominent
        ))
        .accessibilityLabel(Text(title))
    }
}

/// Icon, then title: the Apple TV app's player tabs (Info, Chapters, Cast).
struct PlayerTabLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 24, weight: .semibold))
            configuration.title
        }
    }
}

struct PlayerTabButtonStyle: ButtonStyle {
    let focused: Bool
    /// Whether this tab's card is the one showing.
    ///
    /// Separate from `focused`, and the reason the row reads as a segmented
    /// control rather than a pair of buttons: focus moves down into the card, and
    /// without a selected state nothing then indicates which tab is open. The
    /// season bar on the detail page draws the same distinction.
    var selected: Bool = false

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    /// Safe to branch on for the same reason `reduceTransparency` is: it changes
    /// when playback starts and stops, never while focus is moving, so the view
    /// tree stays a stable shape mid-swipe.
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        // ONE geometry for both states: the label, font and padding are applied
        // once and only the BACKGROUND swaps. Branching into two differently-built
        // chains (a filled capsule vs. `.glassEffect`) let the two states measure
        // differently, so the tab changed size the instant it took focus — and in a
        // bottom-anchored stack a size change moves everything, which reads as the
        // tab jumping rather than travelling.
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(focused ? (colorScheme == .light ? Color.white : .black) : .primary)
            .opacity(focused || selected ? 1 : 0.86)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background { background }
            .clipShape(Capsule(style: .continuous))
            // The surface swap stays instant — see above — but the lift is a
            // transform, not layout, so it can travel without moving the stack.
            .animation(nil, value: focused)
            // NOTHING for `selected` here, deliberately.
            //
            // `.animation(nil, value: selected)` looks like the natural companion
            // to the line above, and it is a trap: it suppresses animation for
            // this view for the whole transaction in which `selected` changes —
            // and that is the same transaction that moves the row, because
            // selection changes precisely when the card opens. The tapped tab
            // therefore SNAPPED to its new position while its neighbour, whose
            // `selected` did not change, travelled normally. Two tabs in one
            // HStack cannot really move at different speeds; that is what it
            // looked like.
            //
            // Both selected states retain the same untinted glass.
            .scaleEffect(configuration.isPressed ? 1.02 : (focused ? 1.08 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
            // The press scale needs a curve of its OWN, and this is the whole
            // reason the tapped tab looked slower than the one beside it.
            //
            // Releasing a tap is what opens the card, so `isPressed` returns to
            // false in the very transaction that animates the strip. With no
            // animation named for it, the scale inherited that transaction and
            // took the card's full 0.24s to settle — so the tab you pressed was
            // still growing back while its neighbour, which had nothing to
            // settle, simply travelled. Both moved together; only one was also
            // finishing a scale.
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        let shape = Capsule(style: .continuous)
        if focused {
            shape.fill(Color.primary)
        } else if reducePanelGlass || reduceTransparency {
            // The same material the panel behind these falls back to. Matching
            // it is the whole point: a glass pill sitting on a frosted panel
            // reads as two materials that do not belong together.
            //
            // Plus a hairline edge. Frost takes its brightness from what is
            // behind it, so over a dark scene it very nearly disappears — glass
            // has a specular edge of its own that does this for free, and
            // without it these pills vanish against the letterboxing.
            shape
                .fill(.clear)
                .plozzFrostedBackground(shape, raised: selected)
                .plozzFrostedBorder(shape)
        } else if !reduceTransparency, #available(iOS 26.0, tvOS 26.0, *) {
            #if os(tvOS)
            PlayerNativeGlassSurface(shape, glass: selected ? .regular.tint(.white.opacity(0.30)) : .regular)
            #else
            PlayerNativeGlassSurface(shape)
            #endif
        } else {
            shape.fill(.clear)
                .plozzFrostedBackground(shape, raised: selected)
                .plozzFrostedBorder(shape)
        }
    }
}

/// Drives the trickplay thumbnail's dismissal: it appears instantly (identity
/// insertion) and, on removal, quickly fades while blurring, scaling down a
/// touch, and drifting slightly downward.
struct ThumbnailTransitionModifier: ViewModifier {
    /// 0 = fully visible, 1 = fully dismissed.
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .offset(y: 13 * progress)
            .opacity(Double(max(0, 1 - progress * 4.5)))
    }
}

extension AnyTransition {
    static var thumbnailDismiss: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: ThumbnailTransitionModifier(progress: 1),
                identity: ThumbnailTransitionModifier(progress: 0)
            )
        )
    }
}

typealias PlozzMoveCommandDirection = SettingsMoveCommandDirection

public extension View {
    func playerPanelBackground(cornerRadius: CGFloat = 32) -> some View {
        modifier(PanelGlassBackground(cornerRadius: cornerRadius))
    }
}

/// The floating panel's translucent backing. Native **Liquid Glass** on tvOS
/// 26+, with the profile/accessibility choice and pre-26 fallback retained.
///
/// Still **no `.shadow`** — a soft drop shadow was the original frame-drop
/// culprit over Dolby Vision (a per-frame offscreen blur recomposited on the
/// moving HDR signal). TV retains its 1px edge; mobile uses only the native edge.
///
/// The glass underlay has its own identity instead of wrapping changing text,
/// artwork, and focus controls in the material's layout subtree.
struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 32
    var mediaGlass = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reducePanelGlass || reduceTransparency {
                content
                    .plozzFrostedBackground(shape)
                    .plozzFrostedBorder(shape)
            } else if #available(iOS 26.0, tvOS 26.0, *) {
                #if os(iOS)
                content.background { PlayerNativeGlassSurface(shape, glass: mediaGlass ? .clear : .regular) }
                #else
                content
                    .background { PlayerNativeGlassSurface(shape) }
                    .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
                #endif
            } else {
                content
                    .plozzFrostedBackground(shape)
                    .plozzFrostedBorder(shape)
            }
        }
        .playerPlatformAppearance()
    }
}

/// Reports the controls layer's own BOTTOM edge in global space, so a measurement
/// taken against the buttons (also global) subtracts two numbers from the same
/// coordinate system. The layer is inset by the tvOS safe area, so its height is NOT
/// its bottom edge — mixing the two put the menus 60pt low, right on the buttons.
struct ControlsBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the track-control row's TOP edge, in the controls layer's coordinate
/// space, so the options menus can be positioned just above the buttons that open
/// them while living outside the transport's view tree.
struct TrackControlsTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#endif

extension View {
    @ViewBuilder
    func plozzFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func plozzRemoteCommands(
        onExit: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onMove: @escaping (PlozzMoveCommandDirection) -> Void
    ) -> some View {
        #if os(tvOS)
        self
            .onExitCommand(perform: onExit)
            .onPlayPauseCommand(perform: onPlayPause)
            .onMoveCommand { direction in
                switch direction {
                case .up: onMove(.up)
                case .down: onMove(.down)
                case .left: onMove(.left)
                case .right: onMove(.right)
                @unknown default: break
                }
            }
        #else
        self
        #endif
    }

    @ViewBuilder
    func plozzMoveCommand(
        perform action: @escaping (PlozzMoveCommandDirection) -> Void
    ) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
        #else
        self
        #endif
    }
}
