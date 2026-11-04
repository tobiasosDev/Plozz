#if canImport(SwiftUI) && canImport(UIKit)
import UIKit

/// Shared visual tokens for the hero foreground's pills and paging-dot container, so
/// both build an identical background for the selected `PillStyle`. The two flat
/// styles (`clean`, `glassish`) never sample the backdrop; only `glass` uses a live
/// `UIVisualEffectView`.
enum HeroForegroundGlass {
    /// Fully opaque theme-aware foreground ink. Explicit colors are used instead of
    /// semantic secondary colors so the renderer never gets an implicit alpha.
    static func primaryInk() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light ? .black : .white
        }
    }

    /// Body-copy ink for the hero description: the palette's 60% secondary tier,
    /// expressed in UIKit.
    ///
    /// Replaces an opaque 0.78 / 0.22 ink that predated the palette tiers and
    /// answered to nothing - it sat between 60% secondary and full primary, so
    /// the Home hero's description was noticeably brighter than the detail
    /// page's while meaning to be the same thing.
    static func descriptionInk() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(white: 0, alpha: 0.60)
                : UIColor(white: 1, alpha: 0.60)
        }
    }

    /// Builds the live-glass effect view for the `.glass` style, or an effect-less
    /// container (kept hidden by the caller, which draws a flat capsule instead) for
    /// the flat styles.
    static func makeView() -> UIVisualEffectView {
        guard HeroForegroundConfig.useGlass else { return UIVisualEffectView(effect: nil) }
        if #available(tvOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }

    /// The flat idle-capsule fill. Theme-aware: in dark mode the see-through grey
    /// that tvOS 26 glass reads as at rest over artwork, in light mode a light tint.
    /// `PLZHERO_UIKIT_FILL` (0–1) swaps in a black tint of that alpha for live
    /// eyeballing against the previous look.
    static let fillOverride: CGFloat? = {
        guard let raw = ProcessInfo.processInfo.environment["PLZHERO_UIKIT_FILL"],
              let a = Double(raw), a >= 0 else { return nil }
        return CGFloat(min(1, a))
    }()

    static var fillAlpha: CGFloat { fillOverride ?? 0.5 }

    static func flatFill() -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .light {
                return UIColor.white.withAlphaComponent(max(0, fillAlpha - 0.06))
            }
            // A mid grey rather than a white tint: without the live blur, white
            // over bright art would wash the glyph out, and black reads as a hole.
            return fillOverride.map { UIColor.black.withAlphaComponent($0) }
                ?? UIColor(white: 0.42, alpha: 0.42)
        }
    }

    /// The hairline border stroke for the flat capsule. A faint light edge in dark
    /// mode (and a faint dark edge in light mode) to define the pill against art —
    /// the glass rim. Alpha is tunable via `PLZHERO_UIKIT_BORDER` (0–1) for live
    /// eyeballing; defaults to 0.22 and `0` removes the border entirely.
    static let borderAlpha: CGFloat = {
        if let raw = ProcessInfo.processInfo.environment["PLZHERO_UIKIT_BORDER"],
           let a = Double(raw), a >= 0 {
            return CGFloat(min(1, a))
        }
        return 0.22
    }()

    static var borderWidth: CGFloat { borderAlpha <= 0 ? 0 : 2 }

    static func flatBorder() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor.black.withAlphaComponent(borderAlpha * 0.9)
                : UIColor.white.withAlphaComponent(borderAlpha)
        }
    }
}

/// One hero action **pill**: a real tvOS focus item.
///
/// The focus engine moves between pills natively (sound, swipe, held clicks), and
/// the focused pill draws the bright treatment:
///
/// * **Idle:** a flat capsule (`clean`/`glassish`) or live glass (`glass`) with
///   a theme-aware glyph/label.
/// * **Focused:** a bright white capsule with a dark glyph/label, a 1.06 lift and
///   a soft shadow, animated alongside the focus update.
///
/// Progress pills (Play resume / active download) draw the shared inline capsule
/// gauge (≈150pt, matching `ResumeProgressCapsule`) *between* the glyph and the
/// trailing text, rather than a bar pinned to the bottom edge.
final class HeroForegroundPillView: UIView {
    /// Live-glass container, used only for the `.glass` style; hidden for the flat
    /// styles, which draw the capsule on the view's own layer instead.
    private let glassView: UIVisualEffectView = HeroForegroundGlass.makeView()
    private let style = HeroForegroundConfig.pillStyle
    /// Optional top-down highlight for the `.glassish` style — a faint sheen that
    /// fakes glass without any live backdrop sampling.
    private let sheenLayer = CAGradientLayer()
    private let glyphView = UIImageView()
    private let textLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()

    private let hPadding: CGFloat = 30
    private let vPadding: CGFloat = 18
    private let glyphTextGap: CGFloat = 12
    private let glyphSize: CGFloat = 30
    /// Half the former 150 — the resume trailing now also carries the "S5, E12 • "
    /// prefix, so a shorter bar keeps the pill from growing over-wide. Mirrors
    /// `PlayResumeButtonLabel.capsuleWidth`.
    private let barWidth: CGFloat = 75
    /// Matches `PlayResumeButtonLabel`'s resume bar height on tvOS heroes (the
    /// SwiftUI detail hero passes `barHeight: 10`) so the UIKit home hero pill and
    /// the SwiftUI detail hero render an identical bar.
    private let barHeight: CGFloat = 10

    private var pill: HeroForegroundModel.Pill?
    private var selected = false
    private var prominent = false
    private var progressFraction: CGFloat = 0

    /// Pill identifiers are `home-hero-action-<kind>`; remote tests find the hero
    /// by this prefix.
    static let accessibilityIdentifierPrefix = "home-hero-action-"

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .button

        glassView.clipsToBounds = true
        glassView.isUserInteractionEnabled = false
        glassView.isHidden = (style != .glass)
        addSubview(glassView)

        // Flat styles get a hairline border on the pill's own layer; `.glassish` adds
        // a subtle top sheen behind the content.
        if style != .glass {
            layer.borderColor = HeroForegroundGlass.flatBorder().cgColor
            layer.borderWidth = HeroForegroundGlass.borderWidth
        }
        if style == .glassish {
            sheenLayer.colors = [
                UIColor.white.withAlphaComponent(0.18).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor,
            ]
            sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
            sheenLayer.endPoint = CGPoint(x: 0.5, y: 0.65)
            layer.addSublayer(sheenLayer)
        }

        glyphView.contentMode = .scaleAspectFit
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressFill.backgroundColor = .white
        progressTrack.isHidden = true
        progressTrack.clipsToBounds = true
        for v in [glyphView, textLabel, progressTrack] { addSubview(v) }
        progressTrack.addSubview(progressFill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { pill != nil && !isHidden }

    var kind: HeroForegroundModel.Pill.Kind? { pill?.kind }

    /// The slide title, read after the action name ("Play, Severance").
    var slideTitle: String? {
        didSet { accessibilityValue = slideTitle }
    }

    func configure(_ pill: HeroForegroundModel.Pill, locale: Locale = .current) {
        self.pill = pill
        self.locale = locale
        prominent = pill.prominent
        accessibilityIdentifier = Self.accessibilityIdentifierPrefix + "\(pill.kind)"
        applyContent()
        applyLift()
    }

    private var locale: Locale = .current

    /// Draws the glyph, label, progress and background for the current pill and
    /// focus state. Focus alone marks the active button on tvOS, so a pill is only
    /// bright while it is the focused one, never an always-lit "primary" fill.
    private func applyContent() {
        guard let pill else { return }
        let bright = selected

        let tint: UIColor = bright ? .black : HeroForegroundGlass.primaryInk()
        if let symbol = pill.systemImage {
            glyphView.image = UIImage(systemName: symbol)
            glyphView.tintColor = tint
            glyphView.isHidden = false
        } else {
            glyphView.image = nil
            glyphView.isHidden = true
        }
        let displayText: String?
        if var title = pill.localizedTitle {
            title.locale = locale
            displayText = String(localized: title) + (pill.text ?? "") // l10n:content — UIKit presentation boundary, refreshed on environment-locale changes
        } else {
            displayText = pill.text
        }
        if let text = displayText {
            textLabel.text = text
            textLabel.textColor = tint
            textLabel.isHidden = false
        } else {
            textLabel.text = nil
            textLabel.isHidden = true
        }
        if var name = pill.accessibilityName {
            name.locale = locale
            accessibilityLabel = String(localized: name) // l10n:content — UIKit accessibility boundary, refreshed with the pill
        } else {
            accessibilityLabel = displayText
        }

        if let progress = pill.progress {
            progressTrack.isHidden = false
            let progressTint: UIColor = bright ? .black : HeroForegroundGlass.primaryInk()
            progressFill.backgroundColor = progressTint
            progressTrack.backgroundColor = progressTint.withAlphaComponent(0.3)
            progressFraction = max(0, min(1, progress))
        } else {
            progressTrack.isHidden = true
        }

        applyBackgroundAppearance()
        setNeedsLayout()
    }

    private func applyLift() {
        transform = selected ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // A hop onto an edge catcher is a page, not leaving the pill: focus comes
        // straight back, so the pill keeps its focused look in between.
        let focused = context.nextFocusedView === self
            || (context.previouslyFocusedView === self && context.nextFocusedView is HeroEdgeCatcher)
        guard focused != selected else { return }
        selected = focused
        // Colour and fill snap with the focus update (no comet trail); only the
        // lift animates, on the focus engine's own timing.
        UIView.performWithoutAnimation {
            applyContent()
            layoutIfNeeded()
        }
        coordinator.addCoordinatedAnimations({ self.applyLift() })
    }

    /// Re-reads the real focus state, for the case a hop onto an edge catcher
    /// did not come back to this pill.
    func syncFocusAppearance() {
        guard selected != isFocused else { return }
        selected = isFocused
        applyContent()
        applyLift()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
        // Refresh explicit layer-backed colors when tvOS changes appearance.
        applyContent()
    }

    /// Resolves the pill background for the current style and selection:
    /// * **selected** — a bright white capsule (dark ink), any glass/sheen hidden.
    /// * **idle `.glass`** — the live `UIGlassEffect` view.
    /// * **idle `.clean` / `.glassish`** — a flat theme-aware translucent fill on the
    ///   view's own layer (plus a hairline border, and a sheen for `.glassish`), which
    ///   never samples the moving backdrop so it stays on the ~17ms frame budget.
    private func applyBackgroundAppearance() {
        if selected {
            glassView.isHidden = true
            sheenLayer.isHidden = true
            layer.borderWidth = 0
            backgroundColor = .white
        } else if style == .glass {
            glassView.isHidden = false
            backgroundColor = .clear
        } else {
            glassView.isHidden = true
            sheenLayer.isHidden = (style != .glassish)
            layer.borderWidth = HeroForegroundGlass.borderWidth
            layer.borderColor = HeroForegroundGlass.flatBorder().resolvedColor(with: traitCollection).cgColor
            backgroundColor = HeroForegroundGlass.flatFill()
        }
    }

    /// The label's natural single-line width, ceil'd with a hair of slack so the
    /// exact-fit capsule never truncates it (the sub-pixel remainder was showing as an
    /// ellipsis, most visibly once a focused pill scales up).
    private func naturalTextWidth() -> CGFloat {
        guard !textLabel.isHidden, !(textLabel.text ?? "").isEmpty else { return 0 }
        let fit = textLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude))
        return ceil(fit.width) + 1
    }

    /// The pill's natural size for the parent's manual row layout.
    func preferredSize() -> CGSize {
        let height = max(glyphSize, textLabel.font.lineHeight) + vPadding * 2
        // Icon-only pills (no text, no progress bar) render as a perfect circle: a
        // square whose side equals the capsule height, so the height/2 corner radius
        // rounds it fully rather than leaving a stadium/oval.
        if textLabel.isHidden && progressTrack.isHidden {
            return CGSize(width: height, height: height)
        }
        var contentWidth: CGFloat = 0
        if !glyphView.isHidden { contentWidth += glyphSize }
        if !progressTrack.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            contentWidth += barWidth
        }
        if !textLabel.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            contentWidth += naturalTextWidth()
        }
        let width = contentWidth + hPadding * 2
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        glassView.frame = bounds
        glassView.layer.cornerRadius = radius
        if sheenLayer.superlayer != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sheenLayer.frame = bounds
            sheenLayer.cornerRadius = radius
            CATransaction.commit()
        }

        if selected {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.30
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: 8)
            // The capsule's own outline. Without a path Core Animation derives the
            // shadow from the layer's alpha in an offscreen pass on every frame the
            // hero recomposites, which under a playing trailer is every frame.
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }

        let midY = bounds.midY
        // Icon-only circular pill: centre the glyph both axes.
        if !glyphView.isHidden && textLabel.isHidden && progressTrack.isHidden {
            glyphView.frame = CGRect(x: bounds.midX - glyphSize / 2,
                                     y: midY - glyphSize / 2,
                                     width: glyphSize, height: glyphSize)
            return
        }

        var x = hPadding
        if !glyphView.isHidden {
            glyphView.frame = CGRect(x: x, y: midY - glyphSize / 2, width: glyphSize, height: glyphSize)
            x += glyphSize + glyphTextGap
        }
        if !progressTrack.isHidden {
            progressTrack.frame = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            progressTrack.layer.cornerRadius = barHeight / 2
            // Floor the RESUME fill at a single dot (one bar height → a circle) so
            // any real progress reads as an intentional start, not a hairline
            // sliver (matching ResumeProgressCapsule). A live download gauge is
            // left exact so it isn't misrepresented at low percentages.
            let floorsFill = pill?.kind == .play
            let fillWidth: CGFloat
            if progressFraction <= 0 {
                fillWidth = 0
            } else if floorsFill {
                fillWidth = min(barWidth, max(barHeight, barWidth * progressFraction))
            } else {
                fillWidth = barWidth * progressFraction
            }
            progressFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: barHeight)
            progressFill.layer.cornerRadius = barHeight / 2
            x += barWidth + glyphTextGap
        }
        if !textLabel.isHidden {
            let remaining = bounds.width - x - hPadding
            // Prefer the label's own natural width so it never truncates; only fall
            // back to the (equal, by construction) remaining space if it's larger.
            let w = max(naturalTextWidth(), remaining)
            textLabel.frame = CGRect(x: x, y: 0, width: max(0, w), height: bounds.height)
        }
    }
}
#endif
