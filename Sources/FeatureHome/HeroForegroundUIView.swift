#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
import CoreModels
import CoreUI

@MainActor
@Observable
final class HeroForegroundRatingsState {
    var textScale: CGFloat = 1
    private(set) var ratings: [ExternalRating] = []
    private(set) var familyGuidanceAge: Double?

    func update(_ ratings: [ExternalRating], familyGuidanceAge: Double? = nil) {
        if self.ratings != ratings { self.ratings = ratings }
        if self.familyGuidanceAge != familyGuidanceAge { self.familyGuidanceAge = familyGuidanceAge }
    }
}

private struct HeroForegroundRatingsView: View {
    let state: HeroForegroundRatingsState

    var body: some View {
        RatingsBadgeRow(ratings: state.ratings, familyGuidanceAge: state.familyGuidanceAge)
            .environment(\.metadataTextScale, state.textScale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the interactive hero foreground reports back to `HomeHeroView`.
///
/// Moving between pills never reaches SwiftUI: the focus engine handles it and
/// the pills redraw themselves. Only activation, paging at the row's edges and
/// the hero gaining or losing focus cross back.
struct HeroForegroundEvents {
    /// Remote Select on a pill.
    var activate: (HeroForegroundModel.Pill.Kind) -> Void = { _ in }
    /// Remote Play/Pause anywhere in the row.
    var playPause: () -> Void = {}
    /// A move past the first (`.left`) or last (`.right`) pill. Return `true`
    /// when it was handled (a page, or opening the pinned sidebar).
    var edge: (HeroFocusDirection) -> Bool = { _ in false }
    /// Any remote input inside the row, so auto-advance can pause.
    var interaction: () -> Void = {}
    /// Focus entered (`true`) or left (`false`) the row, with the move's heading.
    var focusChanged: (Bool, UIFocusHeading) -> Void = { _, _ in }
    /// Nothing on screen holds focus and the hero should take it. SwiftUI owns
    /// which representable is focused, so the claim goes through its focus state.
    /// Returns `false` when the hero must not take focus (Home is covered).
    var claimFocus: () -> Bool = { false }
}

/// The persistent UIKit **hero foreground**: logo/title, metadata, overview, the
/// action pills and the paging dots, updated **imperatively in place** by
/// ``HeroForegroundCoordinator`` on a page rather than rebuilt.
///
/// The pills are the hero's focus items. Left/Right between them is native focus
/// movement; a move past either end lands on an invisible edge catcher and is
/// turned into a page, and focus goes straight back to the pill, so the focused
/// pill stays put while the slide changes under it. Entry guides above and below the row
/// send focus coming back from the tab bar or Continue Watching to the pill that
/// was focused last.
///
/// Layout is manual and **bottom-anchored** (the block hugs the bottom of the
/// view's bounds).
final class HeroForegroundUIView: UIView {
    // MARK: Subviews
    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let ratingLabel = PaddedLabel()
    private let metadataLabel = UILabel()
    /// The server brand mark leading the metadata line, as a cached bitmap so
    /// trailer frames and the paging gauge never re-render it.
    private let sourceBadge = UIImageView()
    private var sourceBadgeProvider: ProviderKind?
    /// Outlined spec chips ("4K", "5.1") trailing the metadata line, reused across slides.
    private var qualityLabels: [PaddedLabel] = []
    private let overviewLabel = UILabel()
    /// The air-schedule badge above the logo ("New episode every Wednesday").
    private let scheduleLabel = PaddedLabel()
    private let ratingsState = HeroForegroundRatingsState()
    private lazy var ratingsHost = UIHostingController(
        rootView: HeroForegroundRatingsView(state: ratingsState)
    )
    private let pillsContainer = UIView()
    var contentLocale: Locale = .current
    var logoSize: HeroLogoSize = .default {
        didSet {
            if oldValue != logoSize { setNeedsLayout() }
        }
    }
    var textSize: HeroTextSize = .default {
        didSet {
            guard oldValue != textSize else { return }
            applyTextSizing()
            setNeedsLayout()
        }
    }
    var appTextScale: CGFloat = 1 {
        didSet {
            guard oldValue != appTextScale else { return }
            applyTextSizing()
            setNeedsLayout()
        }
    }
    private var textScale: CGFloat { PlozzTypography.scale(local: textSize.scale, app: appTextScale) }
    /// Effect-less host: dots/pill render directly over the hero with no capsule.
    private let dotsContainer = UIVisualEffectView(effect: nil)
    private let useGauge = HeroForegroundConfig.useGauge

    /// Reused pill views (pooled), so a page updates labels/frames in place rather
    /// than allocating a fresh row — persistent identity, the whole point.
    private var pillViews: [HeroForegroundPillView] = []

    // MARK: Focus

    var events = HeroForegroundEvents()
    /// Left at the first pill should leave the hero (native sidebar on the first
    /// slide). The left edge guide steps aside so the focus engine can reach it.
    var escapesLeftAtFirstPill = false {
        didSet { updateGuides() }
    }
    /// The pill focus returns to, and the one it stays on across a page.
    private var focusedPillIndex = 0
    /// Invisible focus targets just past either end of the row; see `handleEdge`.
    private let leftEdgeCatcher = HeroEdgeCatcher(direction: .left)
    private let rightEdgeCatcher = HeroEdgeCatcher(direction: .right)
    /// Catch focus arriving from above (tab bar) or below (Continue Watching) and
    /// hand it to the last focused pill. Enabled only while focus is elsewhere.
    private let topEntryGuide = UIFocusGuide()
    private let bottomEntryGuide = UIFocusGuide()
    private var containsFocus = false
    /// Paging-dot views keyed by their real slide index (matching the SwiftUI hero's
    /// index-identity `ForEach`). Keying by slide — not by fixed slot — means that on
    /// a windowed page the persisting dots slide slot→slot, the dot leaving the window
    /// fades off its edge and the entering dot fades in, while the active pill holds at
    /// its slot: the "dots scroll under a held pill" animation. Views are created
    /// lazily and removed once they scroll out of the window.
    private var dotViewsByIndex: [Int: HeroPagingDotView] = [:]
    /// The dots to render this page, in slot order (from `HeroPagingDots.layout`).
    private var currentDotLayout: [HeroPagingDots.Dot] = []
    /// The active (fronted) slide index, drawn as the wide pill.
    private var activeDotIndex: Int?
    /// Indices whose view was created for the incoming page, so `layoutDots` can slide
    /// them in from the entering edge (with a fade) rather than popping at the origin.
    private var enteringDotIndices: Set<Int> = []
    /// Signature of the last positioned dot layout, so a same-page re-apply (a
    /// selection / metadata-fade update) is a no-op instead of snapping the dot frames
    /// to final and cancelling a running page-morph animation.
    private var lastDotsSignature: [Int] = []


    /// The slide whose logo the view currently expects, so a late async logo load
    /// is dropped if the slide has since changed (belt-and-braces with the
    /// coordinator's generation guard).
    private var currentItemID: String?
    private var model: HeroForegroundModel?
    /// The current slide's fully-processed logo (image + monochrome/halo flags), so
    /// a light/dark trait change can re-tint a monochrome wordmark and reapply the
    /// halo without reloading it. `nil` when the slide shows its text title.
    private var currentLogo: HeroUIKitLogo?

    /// The last rendered paging index, so a genuine page change can animate the
    /// active-dot morph (dot→pill / pill→dot sliding left→right, matching the SwiftUI
    /// hero); `nil` until the first dotted slide is shown.
    private var lastDotsIndex: Int?
    /// Set for exactly one layout pass whenever the page changed, so `layoutDots`
    /// animates the dot frames into place rather than snapping them.
    private var animateDotsMorph = false
    /// Direction of the last page change: `true` when the index INCREASED (window
    /// scrolls so new dots enter at the RIGHT edge), `false` when it decreased (new
    /// dots enter at the LEFT). Drives which edge an entering dot slides in from.
    private var dotsScrollForward = true
    /// Duration of the dot page-morph (matches the SwiftUI hero's `dotMorph`).
    private let dotsMorphDuration: CFTimeInterval = 0.3
    /// Opacity an entering edge dot starts at (it appears at full height and its final
    /// slot, then fades up to 1 within the morph — a slight initial fill, not a pop
    /// from nothing). Mirrors SwiftUI's opacity insertion transition.
    private let dotEnterStartAlpha: CGFloat = 0.3
    /// Duration of the logo cross-dissolve when a late-resolved logo lands (or a
    /// warm logo replaces the text title) while the description is already on screen.
    /// Mirrors the SwiftUI hero's `HeroLogoArtwork` `.onArrival` opacity transition /
    /// `.contentTransition(.opacity)` so the logo dissolves in instead of hard-snapping
    /// a beat after the metadata has settled. Pure content/alpha crossfade — no backdrop
    /// sampling, so it keeps the flat foreground's hitch-free transition budget.
    private let logoArrivalFade: TimeInterval = 0.3

    // MARK: Metrics (mirror the SwiftUI hero)
    private let columnSpacing: CGFloat = 12
    /// Extra room under the wordmark, on top of `columnSpacing`.
    private let logoBottomSpacing: CGFloat = 14
    /// Extra breathing room above the action-pill row (on top of `columnSpacing`).
    private let pillsTopPadding: CGFloat = 16
    /// Extra margin between the paging dots and the action-pill row above them: the
    /// dots are laid out this far below their normal bottom-anchored slot so the pills
    /// stay put while the pagination gains more air.
    private let buttonsToDotsGap: CGFloat = 40
    private let pillSpacing: CGFloat = 24
    private let dotSize: CGFloat = 10
    private let activeDotWidth: CGFloat = 30
    private let dotSpacing: CGFloat = 12
    // The wordmark's own box is shared with the detail hero — see `HeroLogoLayout`.
    // The dots sit in a flat frosted capsule, the Apple TV app's page control.
    private let dotsGlassHPad: CGFloat = 14
    private let dotsGlassVPad: CGFloat = 9
    private let bottomMargin: CGFloat = 24

    /// Total height of the paging-dot glass capsule (dot + vertical padding), used to
    /// reserve vertical space in the bottom-anchored layout.
    private var dotsGlassHeight: CGFloat { dotSize + dotsGlassVPad * 2 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false

        logoImageView.contentMode = .scaleAspectFit
        logoImageView.isHidden = true
        // The legibility halo (for low-contrast logos) is a layer shadow derived
        // from the image's alpha, so it must not be clipped.
        logoImageView.layer.masksToBounds = false

        titleLabel.numberOfLines = 2

        ratingLabel.textAlignment = .center
        ratingLabel.lineBreakMode = .byTruncatingTail
        ratingLabel.isHidden = true

        metadataLabel.numberOfLines = 1
        sourceBadge.contentMode = .scaleAspectFit
        sourceBadge.isHidden = true
        sourceBadge.isAccessibilityElement = false

        // Chrome matched to the flat idle pill rather than the detail hero's
        // material: this renderer exists because live blur re-samples the moving
        // backdrop every transition frame, and a badge that sampled would give back
        // exactly the hitch the flat styles were introduced to remove.
        scheduleLabel.textAlignment = .center
        scheduleLabel.layer.cornerCurve = .continuous
        // Without this the fill keeps its square corners and only the border is
        // rounded, so the backdrop shows through each corner.
        scheduleLabel.clipsToBounds = true
        scheduleLabel.isHidden = true

        applyTextSizing()
        ratingsHost.view!.backgroundColor = .clear
        ratingsHost.view!.isUserInteractionEnabled = false

        // A low-opacity, wide-radius glyph shadow keeps copy readable over bright
        // artwork without looking outlined. It is static layer chrome (no backdrop
        // sampling), so it preserves the flat foreground's transition advantage.
        for label in [titleLabel, ratingLabel, metadataLabel, overviewLabel] {
            label.layer.shadowOpacity = 0.32
            label.layer.shadowRadius = 7
            label.layer.shadowOffset = CGSize(width: 0, height: 2)
        }
        // A glyph shadow has no path, so Core Animation renders it in its own
        // offscreen pass on every frame the hero recomposites — every trailer
        // frame. Rasterized, the text and its shadow are drawn once per change.
        for view in [titleLabel, ratingLabel, metadataLabel, overviewLabel, logoImageView] as [UIView] {
            view.layer.shouldRasterize = true
        }
        updateRasterizationScale()
        applyThemeColors()

        for v in [logoImageView, titleLabel, ratingLabel, metadataLabel, sourceBadge,
                  overviewLabel, scheduleLabel, ratingsHost.view!, pillsContainer, dotsContainer] {
            addSubview(v)
        }
        dotsContainer.clipsToBounds = true
        dotsContainer.isUserInteractionEnabled = false
        addSubview(leftEdgeCatcher)
        addSubview(rightEdgeCatcher)
        for guide in [topEntryGuide, bottomEntryGuide] {
            addLayoutGuide(guide)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyTextSizing() {
        let scale = textScale
        overviewLabel.numberOfLines = textSize.descriptionLineLimit(base: 3)
        titleLabel.font = .systemFont(ofSize: PlozzTypography.heroFallbackTitle.scaled(by: scale).pointSize, weight: .bold)
        metadataLabel.font = .systemFont(ofSize: PlozzTypography.heroMetadata.scaled(by: scale).pointSize, weight: .medium)
        overviewLabel.font = .systemFont(ofSize: PlozzTypography.heroDescription.scaled(by: scale).pointSize)
        applyOverviewText()
        ratingLabel.font = UIFont(name: "Bungee-Regular", size: 18 * scale)
            ?? .systemFont(ofSize: 18 * scale, weight: .semibold)
        ratingLabel.layer.borderWidth = 3 * scale
        ratingLabel.layer.cornerRadius = 6 * scale
        ratingLabel.insets = UIEdgeInsets(top: 0, left: 11 * scale, bottom: 0, right: 11 * scale)
        ratingLabel.fixedHeight = 36 * scale
        ratingLabel.invalidateIntrinsicContentSize()
        qualityLabels.forEach(styleQualityChip)
        // The brand mark is sized at creation; rebuild it at the new scale.
        sourceBadgeProvider = nil
        scheduleLabel.font = .systemFont(ofSize: PlozzTypography.heroSchedule.scaled(by: scale).pointSize, weight: .semibold)
        scheduleLabel.insets = UIEdgeInsets(top: 0, left: 18 * scale, bottom: 0, right: 18 * scale)
        scheduleLabel.fixedHeight = 52 * scale
        scheduleLabel.layer.cornerRadius = 14 * scale
        scheduleLabel.layer.borderWidth = HeroForegroundGlass.borderWidth * scale
        scheduleLabel.invalidateIntrinsicContentSize()
        ratingsState.textScale = scale
    }

    private func applyOverviewText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = PlozzTypography.heroDescription.scaled(by: textScale).lineSpacing
        paragraph.lineBreakMode = .byTruncatingTail
        overviewLabel.attributedText = model?.overview.map {
            NSAttributedString(string: $0, attributes: [.paragraphStyle: paragraph])
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopContinuousUpdates() }
    }

    /// Explicit representable teardown. A `CADisplayLink` retains its target, so
    /// relying on `deinit` alone would keep this entire renderer alive indefinitely.
    func stopContinuousUpdates() {
        stopDotsGauge()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            applyThemeColors()
            setNeedsLayout()
        }
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            updateRasterizationScale()
        }
    }

    /// Rasterized copy must match the panel's pixel density or it reads soft.
    private func updateRasterizationScale() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        for view in [titleLabel, ratingLabel, metadataLabel, overviewLabel, logoImageView] as [UIView] {
            view.layer.rasterizationScale = scale
        }
    }

    private func applyThemeColors() {
        let primary = HeroForegroundGlass.primaryInk()
        titleLabel.textColor = primary
        ratingLabel.textColor = primary
        // Year / runtime sit alongside the certificate chip and the ratings,
        // which are full strength, so a dimmer tier made them look faded next to
        // their own row. The description is the one thing here that should stay
        // quieter than the title above it.
        metadataLabel.textColor = primary
        overviewLabel.textColor = HeroForegroundGlass.descriptionInk()

        scheduleLabel.textColor = primary
        scheduleLabel.backgroundColor = HeroForegroundGlass.flatFill()
        dotsContainer.backgroundColor = HeroForegroundGlass.flatFill()
        dotsContainer.layer.borderWidth = 1
        dotsContainer.layer.borderColor = HeroForegroundGlass.flatBorder().resolvedColor(with: traitCollection).cgColor
        let resolvedPrimary = primary.resolvedColor(with: traitCollection)
        ratingLabel.layer.borderColor = resolvedPrimary.withAlphaComponent(0.65).cgColor
        for chip in qualityLabels {
            chip.textColor = primary
            chip.layer.borderColor = resolvedPrimary.withAlphaComponent(0.65).cgColor
        }
        scheduleLabel.layer.borderColor = HeroForegroundGlass.flatBorder()
            .resolvedColor(with: traitCollection).cgColor
        let shadow = traitCollection.userInterfaceStyle == .light ? UIColor.white : UIColor.black
        for label in [titleLabel, ratingLabel, metadataLabel, overviewLabel] {
            label.layer.shadowColor = shadow.cgColor
        }
        // A monochrome wordmark is recoloured to the scheme foreground, so a
        // light/dark switch must re-tint it (and re-evaluate the halo colour).
        applyLogoTintAndHalo()
    }

    // MARK: - Source badge and spec chips

    private func applySourceBadge(_ provider: ProviderKind?) {
        sourceBadge.isHidden = provider == nil
        guard let provider, provider != sourceBadgeProvider else { return }
        sourceBadgeProvider = provider
        sourceBadge.image = ProviderBrandMarkBitmap.image(
            provider: provider, size: 31 * textScale,
            scale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        )
    }

    private func applyQualityBadges(_ badges: [String]) {
        while qualityLabels.count < badges.count {
            let chip = PaddedLabel()
            chip.textAlignment = .center
            chip.lineBreakMode = .byClipping
            // Static chrome, like the certificate chip: no backdrop, drawn once.
            chip.layer.shouldRasterize = true
            chip.layer.rasterizationScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
            styleQualityChip(chip)
            let primary = HeroForegroundGlass.primaryInk()
            chip.textColor = primary
            chip.layer.borderColor = primary.resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
            addSubview(chip)
            qualityLabels.append(chip)
        }
        for (offset, chip) in qualityLabels.enumerated() {
            let text = offset < badges.count ? badges[offset] : nil
            chip.text = text
            chip.isHidden = text == nil
        }
    }

    private func styleQualityChip(_ chip: PaddedLabel) {
        let scale = textScale
        chip.font = .systemFont(ofSize: 18 * scale, weight: .bold)
        chip.layer.borderWidth = 2 * scale
        chip.layer.cornerRadius = 6 * scale
        chip.insets = UIEdgeInsets(top: 0, left: 8 * scale, bottom: 0, right: 8 * scale)
        chip.fixedHeight = 30 * scale
        chip.invalidateIntrinsicContentSize()
    }

    // MARK: - Imperative apply

    /// Applies a slide's model in place. On a slide change the description snaps
    /// out and fades back in once the backdrop wipe is under way, while the pills
    /// stay where they are and cross-dissolve their content.
    func apply(_ model: HeroForegroundModel, logo: HeroUIKitLogo?, slideChanged: Bool) {
        let animatesSlide = slideChanged && self.model != nil && window != nil
        self.model = model
        currentItemID = model.itemID

        // Logo vs text-title.
        if let logo {
            configureLogoImage(logo)
            logoImageView.isHidden = false
            titleLabel.isHidden = true
        } else {
            currentLogo = nil
            logoImageView.image = nil
            logoImageView.layer.shadowOpacity = 0
            logoImageView.isHidden = true
            titleLabel.isHidden = false
            titleLabel.text = model.title
        }

        if let rating = model.ratingBadgeText, !rating.isEmpty {
            ratingLabel.text = ContentRatingPresentation(rating).text
            ratingLabel.accessibilityLabel = rating
            ratingLabel.isHidden = false
        } else {
            ratingLabel.isHidden = true
        }

        metadataLabel.text = model.metadataText
        metadataLabel.isHidden = (model.metadataText ?? "").isEmpty
        applySourceBadge(model.sourceProvider)
        applyQualityBadges(model.qualityBadges)

        scheduleLabel.text = model.scheduleLine
        scheduleLabel.isHidden = (model.scheduleLine ?? "").isEmpty

        applyOverviewText()
        overviewLabel.isHidden = (model.overview ?? "").isEmpty
        ratingsState.update(model.ratings, familyGuidanceAge: model.familyGuidanceAge)
        ratingsHost.view!.isHidden = model.ratings.isEmpty && model.familyGuidanceAge == nil

        if animatesSlide {
            UIView.transition(
                with: pillsContainer, duration: Self.pillContentFade,
                options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
            ) {
                self.applyPills(model)
            }
        } else {
            applyPills(model)
        }
        applyDots(model)
        setNeedsLayout()
        layoutIfNeeded()
        if animatesSlide { runSlideFade() }
    }

    /// Late async logo assignment, identity-guarded. Cross-dissolves the logo in when
    /// the description block is already visible (a late resolve landing after the group
    /// fade has settled), mirroring the SwiftUI hero's `HeroLogoArtwork` arrival
    /// transition, instead of a hard snap. When the block is currently hidden (mid
    /// page snap-hide) it just sets the image so the group fade-in brings it up.
    func setLogo(_ logo: HeroUIKitLogo, for itemID: String) {
        guard itemID == currentItemID else { return }
        crossfadeToLogo(logo)
        setNeedsLayout()
    }

    /// Swaps the text title out for `logo`, dissolving when on screen. Sets the image
    /// and lays out at final geometry first (layout only positions the logo once its
    /// image is non-nil), then cross-dissolves via alpha so the logo fades up as the
    /// outgoing title fades out — no frame jump, no backdrop sampling.
    private func crossfadeToLogo(_ logo: HeroUIKitLogo) {
        let onScreen = !isHidden && logoImageView.alpha > 0.01
        configureLogoImage(logo)
        logoImageView.isHidden = false
        guard onScreen else {
            titleLabel.isHidden = true
            return
        }
        // Settle layout for the logo's real size before dissolving, so only opacity
        // animates — not the frame.
        logoImageView.alpha = 0
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: logoArrivalFade, delay: 0,
                       options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.logoImageView.alpha = 1
            self.titleLabel.alpha = 0
        } completion: { _ in
            self.titleLabel.isHidden = true
            self.titleLabel.alpha = 1
        }
    }

    /// Installs a resolved logo into `logoImageView` with the same treatment as the
    /// SwiftUI ``HeroLogoArtwork``: a monochrome wordmark is drawn as a template
    /// image (tinted to the scheme foreground in ``applyLogoTintAndHalo``), while
    /// multi-colour brand art draws as-is. Tint/halo are applied separately so a
    /// trait change can recolour without reloading.
    private func configureLogoImage(_ logo: HeroUIKitLogo) {
        currentLogo = logo
        logoImageView.image = logo.image.withRenderingMode(
            logo.isMonochrome ? .alwaysTemplate : .alwaysOriginal
        )
        applyLogoTintAndHalo()
    }

    /// Applies the current logo's scheme-adaptive tint and legibility halo. A
    /// monochrome wordmark is tinted to the scheme foreground (white in dark mode,
    /// black in light) and needs no halo (it contrasts the scheme-tone scrim by
    /// construction). A low-contrast multi-colour logo gets a soft alpha-derived
    /// glow — light for a dark logo, dark for a light one — mirroring
    /// `LogoLegibilityHalo`.
    private func applyLogoTintAndHalo() {
        guard let logo = currentLogo else {
            logoImageView.layer.shadowOpacity = 0
            return
        }
        if logo.isMonochrome {
            logoImageView.tintColor = traitCollection.userInterfaceStyle == .light ? .black : .white
            logoImageView.layer.shadowOpacity = 0
            return
        }
        guard logo.needsHalo else {
            logoImageView.layer.shadowOpacity = 0
            return
        }
        if logo.isDark {
            // Was a white glow. It fired on any mid-to-dark logo and read as an
            // effect stuck on the artwork rather than the logo sitting in front of
            // it; a shadow reads as depth, which is what is actually happening.
            // Matches `LogoLegibilityHalo` so a wordmark looks the same on both
            // renderers and on iOS.
            logoImageView.layer.shadowColor = UIColor.black.cgColor
            logoImageView.layer.shadowOpacity = 0.42
            logoImageView.layer.shadowRadius = 12
        } else if traitCollection.userInterfaceStyle == .light {
            // Softer, lighter dark glow in light mode (matches LogoLegibilityHalo):
            // the bright hero doesn't need a heavy black halo, so drop the opacity
            // and widen the radius for a gentle lift instead of a hard smudge.
            logoImageView.layer.shadowColor = UIColor.black.cgColor
            logoImageView.layer.shadowOpacity = 0.26
            logoImageView.layer.shadowRadius = 15
        } else {
            logoImageView.layer.shadowColor = UIColor.black.cgColor
            logoImageView.layer.shadowOpacity = 0.42
            logoImageView.layer.shadowRadius = 12
        }
        logoImageView.layer.shadowOffset = .zero
    }

    // MARK: Pills

    private func applyPills(_ model: HeroForegroundModel) {
        // Grow the pool as needed; reuse existing views, so the focused pill keeps
        // its identity (and focus) across a page.
        while pillViews.count < model.pills.count {
            let pill = HeroForegroundPillView()
            pillViews.append(pill)
            pillsContainer.addSubview(pill)
        }
        let count = model.pills.count
        let hadPills = !visiblePills.isEmpty
        let clamped = count == 0 ? 0 : min(focusedPillIndex, count - 1)
        if clamped != focusedPillIndex {
            focusedPillIndex = clamped
            // The focused pill is about to disappear (this slide has fewer
            // actions). Move focus to the new last pill before hiding it, or the
            // focus engine would relocate it on its own, down into the rows.
            if containsFocus {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
        for (i, pillView) in pillViews.enumerated() {
            if i < count {
                pillView.configure(model.pills[i], locale: contentLocale)
                pillView.slideTitle = model.title
                pillView.isHidden = false
            } else {
                pillView.isHidden = true
            }
        }
        updateGuides()
        if !hadPills { claimFocusIfUnowned() }
    }

    // MARK: Focus handling

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        let visible = visiblePills
        guard !visible.isEmpty else { return [] }
        return [visible[min(focusedPillIndex, visible.count - 1)]]
    }

    private var visiblePills: [HeroForegroundPillView] { pillViews.filter { !$0.isHidden } }

    private func pillIndex(of item: UIFocusItem?) -> Int? {
        guard let view = item as? HeroForegroundPillView else { return nil }
        return visiblePills.firstIndex { $0 === view }
    }

    private func updateGuides() {
        let pills = visiblePills
        let preferred: [UIFocusEnvironment] = pills.isEmpty
            ? []
            : [pills[min(focusedPillIndex, pills.count - 1)]]
        rightEdgeCatcher.isActive = !pills.isEmpty
        leftEdgeCatcher.isActive = !pills.isEmpty && !escapesLeftAtFirstPill
        topEntryGuide.preferredFocusEnvironments = preferred
        bottomEntryGuide.preferredFocusEnvironments = preferred
        topEntryGuide.isEnabled = !containsFocus && !pills.isEmpty
        bottomEntryGuide.isEnabled = !containsFocus && !pills.isEmpty
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nextIndex = pillIndex(of: context.nextFocusedItem)
        let catcher = context.nextFocusedItem as? HeroEdgeCatcher
        if let nextIndex { focusedPillIndex = nextIndex }
        let inside = nextIndex != nil || catcher != nil
        if inside, context.previouslyFocusedItem.map(isOwnFocusItem) == true {
            events.interaction()
        }
        if let catcher { handleEdge(catcher.direction) }
        if context.previouslyFocusedItem is HeroEdgeCatcher {
            visiblePills.forEach { $0.syncFocusAppearance() }
        }
        guard inside != containsFocus else {
            updateGuides()
            return
        }
        containsFocus = inside
        updateGuides()
        HeroFocusDiagnostics.emit("hero focus \(inside ? "ENTER" : "LEAVE") pill=\(focusedPillIndex) heading=\(context.focusHeading.rawValue)")
        events.focusChanged(inside, context.focusHeading)
    }

    private func isOwnFocusItem(_ item: UIFocusItem) -> Bool {
        pillIndex(of: item) != nil || item is HeroEdgeCatcher
    }

    /// Focus reached an edge catcher: a move past the first or last pill. Page
    /// (or open the pinned sidebar), then put focus straight back on the pill it
    /// came from. The catcher is a real focus target, so the move clicks like any
    /// other and a native sidebar never mistakes a refused move for "open me".
    private func handleEdge(_ direction: HeroFocusDirection) {
        let pills = visiblePills
        HeroFocusDiagnostics.emit("edge \(direction) at pill \(focusedPillIndex)/\(pills.count)")
        focusedPillIndex = direction == .left ? 0 : max(0, pills.count - 1)
        _ = events.edge(direction)
        // A focus update cannot be requested from inside one; return on the next
        // turn of the run loop, once the page has been applied.
        DispatchQueue.main.async { [weak self] in
            guard let self, let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem,
                  focused is HeroEdgeCatcher else { return }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    /// Takes focus when the hero appears and nothing on screen holds it, e.g.
    /// after Home's loading placeholder that held the initial focus goes away.
    /// Never moves focus that something else already owns.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        claimFocusIfUnowned()
    }

    private func claimFocusIfUnowned() {
        guard window != nil, !visiblePills.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let pill = self.preferredFocusEnvironments.first,
                  let system = UIFocusSystem.focusSystem(for: self),
                  system.focusedItem == nil else { return }
            guard self.events.claimFocus() else { return }
            system.requestFocusUpdate(to: pill)
            system.updateFocusIfNeeded()
            HeroFocusDiagnostics.emit("hero claims unowned focus accepted=\(system.focusedItem.map(self.isOwnFocusItem) ?? false)")
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard containsFocus else { return super.pressesBegan(presses, with: event) }
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .select, .playPause:
                events.interaction()
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                events.interaction()
                unhandled.insert(press)
            default:
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard containsFocus else { return super.pressesEnded(presses, with: event) }
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .select:
                if let pill = visiblePills.first(where: \.isFocused), let kind = pill.kind {
                    events.activate(kind)
                }
            case .playPause:
                events.playPause()
            default:
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let passed = containsFocus ? presses.filter { $0.type != .select && $0.type != .playPause } : presses
        if !passed.isEmpty { super.pressesCancelled(passed, with: event) }
    }

    // MARK: Dots

    private func applyDots(_ model: HeroForegroundModel) {
        guard let dots = model.dots else {
            dotViewsByIndex.values.forEach { $0.removeFromSuperview() }
            dotViewsByIndex.removeAll()
            currentDotLayout = []
            activeDotIndex = nil
            enteringDotIndices.removeAll()
            lastDotsSignature = []
            dotsContainer.isHidden = true
            stopDotsGauge()
            lastDotsIndex = nil
            return
        }
        // Animate the whole row's morph on a genuine page change (never on the first
        // show, and never when the page didn't actually move — e.g. a selection or
        // metadata-fade re-apply). Every page change animates, matching SwiftUI's
        // `.animation(value: index)`; `.beginFromCurrentState` lets a rapid burst
        // retarget the in-flight morph instead of piling up.
        if let last = lastDotsIndex, last != dots.index {
            animateDotsMorph = true
            if last == dots.count - 1, dots.index == 0 {
                dotsScrollForward = true
            } else if last == 0, dots.index == dots.count - 1 {
                dotsScrollForward = false
            } else {
                dotsScrollForward = dots.index > last
            }
        } else {
            animateDotsMorph = false
        }
        lastDotsIndex = dots.index

        let layout = HeroPagingDots.layout(count: dots.count, index: dots.index)
        currentDotLayout = layout
        activeDotIndex = dots.index
        enteringDotIndices.removeAll()

        // Get-or-create a view per REAL slide index, so identity is stable across the
        // window scroll and the persisting dots animate slot→slot.
        for d in layout {
            let view: HeroPagingDotView
            if let existing = dotViewsByIndex[d.index] {
                view = existing
            } else {
                view = HeroPagingDotView()
                dotViewsByIndex[d.index] = view
                dotsContainer.contentView.addSubview(view)
                // Entering on an animated page change: it appears at its final slot
                // and full height, starting slightly filled (not from nothing) and
                // fading up to full — matching SwiftUI's opacity insertion. No vertical
                // slide / scale-in ("from the top").
                if animateDotsMorph {
                    enteringDotIndices.insert(d.index)
                    view.alpha = dotEnterStartAlpha
                }
            }
            let scale: CGFloat
            switch d.size {
            case .full: scale = 1.0
            case .medium: scale = 0.78
            case .small: scale = 0.55
            }
            view.configure(
                active: d.index == dots.index,
                tint: HeroForegroundGlass.primaryInk(),
                scale: scale
            )
            view.isHidden = false
        }
        // Drive (or freeze) the active pill's live gauge from the dwell.
        refreshDotsGauge(dots)
    }

    // MARK: Auto-advance gauge

    /// The wide active pill's view (the one that renders the auto-advance gauge).
    private var activeDotView: HeroPagingDotView? {
        guard let activeDotIndex else { return nil }
        return dotViewsByIndex[activeDotIndex]
    }

    /// Starts/stops the display link and sets the active pill's fill for the current
    /// dwell. Mirrors the SwiftUI `brightFillWidth`: no auto-advance ⇒ a full pill;
    /// auto-advance ⇒ a dot growing to the full pill across the dwell; paused ⇒
    /// frozen at `pausedAt`.
    private func refreshDotsGauge(_ dots: HeroForegroundModel.Dots) {
        guard let active = activeDotView else {
            stopDotsGauge()
            return
        }
        guard dots.autoAdvance, useGauge, let start = dots.dwellStart, dots.dwellDuration > 0 else {
            // Auto-advance off, gauge A/B-disabled, or no dwell: the active pill is a
            // solid full pill with no per-frame ticking.
            stopDotsGauge()
            active.setFillFraction(1)
            return
        }
        if let paused = dots.pausedAt {
            // Frozen: hold the fill at the paused instant, no ticking.
            stopDotsGauge()
            active.setFillFraction(gaugeFraction(start: start, duration: dots.dwellDuration, now: paused))
            return
        }
        // Live: state the remaining ramp once and let Core Animation draw it.
        activeDwellStart = start
        activeDwellDuration = dots.dwellDuration
        stopDotsGauge()
        let now = Date()
        active.runGauge(
            from: gaugeFraction(start: start, duration: dots.dwellDuration, now: now),
            remaining: max(0, dots.dwellDuration - now.timeIntervalSince(start))
        )
    }

    private var activeDwellStart: Date?
    private var activeDwellDuration: Double = 0

    private func gaugeFraction(start: Date, duration: Double, now: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / duration)))
    }

    /// The gauge no longer holds a timer, so stopping it is just clearing the
    /// dwell it would restate on the next layout.
    private func stopDotsGauge() {
        activeDwellStart = nil
        activeDwellDuration = 0
    }

    // MARK: Slide fade

    /// The description block that fades on a page. The pills and the dots stay
    /// on screen: the pills hold focus, the dots show where the carousel is.
    private var fadeViews: [UIView] {
        [logoImageView, titleLabel, ratingLabel, metadataLabel,
         overviewLabel, scheduleLabel, ratingsHost.view!]
            + qualityLabels + [sourceBadge]
    }

    /// How long the description stays hidden after a page, so the outgoing title
    /// never sits over the incoming artwork, then how long it takes to return.
    static let descriptionHold: TimeInterval = 0.28
    static let descriptionFade: TimeInterval = 0.3
    static let pillContentFade: TimeInterval = 0.25

    private func runSlideFade() {
        // Snap hide so the outgoing text never lingers over new art, then fade the
        // new slide's text in partway through the backdrop wipe. One animation on
        // the render server; a newer page restarts it from hidden.
        fadeViews.forEach { $0.layer.removeAllAnimations(); $0.alpha = 0 }
        UIView.animate(
            withDuration: Self.descriptionFade,
            delay: Self.descriptionHold,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.fadeViews.forEach { $0.alpha = 1 }
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        // `HomeHeroView.uikitContent` already applies the shared Hero/card leading
        // padding to this representable's host. Applying it again here shifted the
        // UIKit foreground one full gutter to the right of the rows and SwiftUI
        // fallback. Layout in host-local coordinates so physical x matches cards.
        let leading: CGFloat = 0
        let trailing: CGFloat = 60
        let availableWidth = bounds.width - leading - trailing
        let maxWidth = HeroLogoSizing.homeTextWidth(
            for: .television, logoSize: logoSize, availableWidth: availableWidth
        )

        // Measure the bottom-anchored block bottom→top.
        var y = bounds.height - bottomMargin

        // Dots (in their glass capsule) at the very bottom of the block, dropped an
        // extra `buttonsToDotsGap` below the buttons so the pills/metadata stay at the
        // lowered column position while the pagination gains more air beneath them.
        if model?.dots != nil {
            layoutDots(bottom: y + buttonsToDotsGap, leading: leading)
            dotsContainer.isHidden = false
        } else {
            dotsContainer.isHidden = true
        }
        // The dots' room is reserved even without dots, so the pills (and the
        // focus on them) never jump when a curation grows a one-slide hero.
        y -= dotsGlassHeight + columnSpacing

        // Pills row above the dots.
        let pillsHeight = layoutPills(bottom: y, leading: leading)
        layoutFocusGuides(row: pillsContainer.frame)
        y -= pillsHeight + columnSpacing + pillsTopPadding

        if !ratingsHost.view!.isHidden {
            let size = ratingsHost.sizeThatFits(
                in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
            )
            let h = max(size.height, 36 * textScale)
            ratingsHost.view!.frame = CGRect(
                x: leading,
                y: y - h,
                width: maxWidth,
                height: h
            )
            y -= h + columnSpacing
        }

        // Overview above the pills (bottom-anchored: its bottom sits at y).
        if !overviewLabel.isHidden {
            let size = overviewLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let style = PlozzTypography.heroDescription.scaled(by: textScale)
            let h = min(size.height, ceil(style.height(
                lineHeight: overviewLabel.font.lineHeight, lines: overviewLabel.numberOfLines
            )))
            overviewLabel.frame = CGRect(x: leading, y: y - h, width: maxWidth, height: h)
            y -= h + columnSpacing
        }

        // Metadata line.
        let visibleQuality = qualityLabels.filter { !$0.isHidden }
        let showsSourceBadge = !sourceBadge.isHidden
        if !metadataLabel.isHidden || !ratingLabel.isHidden || !visibleQuality.isEmpty || showsSourceBadge {
            let h: CGFloat = 36 * textScale
            let gap = 16 * textScale
            var x = leading
            if showsSourceBadge {
                let side = h * 0.86
                sourceBadge.frame = CGRect(x: x, y: y - h + (h - side) / 2, width: side, height: side)
                x += side + 12 * textScale
            }
            if !ratingLabel.isHidden {
                var rSize = ratingLabel.intrinsicContentSize
                rSize.width = min(rSize.width, min(240, maxWidth * 0.5))
                ratingLabel.frame = CGRect(x: x, y: y - h + (h - rSize.height) / 2, width: rSize.width, height: rSize.height)
                x += rSize.width + gap
            }
            let chipsWidth = visibleQuality.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + 10 * textScale }
            if !metadataLabel.isHidden {
                let available = max(0, maxWidth - (x - leading) - chipsWidth)
                let fitted = min(available, ceil(metadataLabel.sizeThatFits(
                    CGSize(width: .greatestFiniteMagnitude, height: h)).width))
                metadataLabel.frame = CGRect(x: x, y: y - h, width: fitted, height: h)
                x += fitted + gap
            }
            for chip in visibleQuality {
                let size = chip.intrinsicContentSize
                guard x + size.width <= leading + maxWidth else { chip.frame = .zero; continue }
                chip.frame = CGRect(x: x, y: y - h + (h - size.height) / 2, width: size.width, height: size.height)
                x += size.width + 10 * textScale
            }
            y -= h + columnSpacing
        }

        // Logo or title on top of the block, with the schedule badge above it —
        // the same order the detail hero uses, so a series reads identically on
        // both screens.
        // A wordmark is the slide's title, so it wants room beneath it rather than
        // sitting straight on the description — the same breathing space the text
        // title would get from its own line height.
        y -= logoBottomSpacing

        var logoTop = y
        if !logoImageView.isHidden, let image = logoImageView.image, image.size.width > 0 {
            // The frame is the ACTUAL fitted image, not the slot: `.scaleAspectFit`
            // centres within its frame, so a frame wider than the drawn image would
            // push a tall/narrow wordmark right instead of leaving it left-aligned.
            let box = HeroLogoLayout.box(size: logoSize, availableWidth: availableWidth)
            let fitted = HeroLogoFit.fittedSize(
                for: image.size,
                maxWidth: box.width,
                maxHeight: box.height,
                coverage: currentLogo?.coverage ?? 1
            )
            let (w, h) = (fitted.width, fitted.height)
            logoImageView.frame = CGRect(x: leading, y: y - h, width: w, height: h)
            logoTop = y - h
        } else if !titleLabel.isHidden {
            let size = titleLabel.sizeThatFits(CGSize(width: min(maxWidth, 1000), height: .greatestFiniteMagnitude))
            let h = min(size.height, ceil(titleLabel.font.lineHeight * 2))
            titleLabel.frame = CGRect(x: leading, y: y - h, width: min(maxWidth, 1000), height: h)
            logoTop = y - h
        }

        if !scheduleLabel.isHidden {
            let size = scheduleLabel.intrinsicContentSize
            scheduleLabel.frame = CGRect(
                x: leading,
                y: logoTop - columnSpacing - size.height,
                width: min(size.width, maxWidth),
                height: size.height
            )
        }
    }

    /// Places the edge catchers just outside the pill row and the entry guides as
    /// full-width bands above and below it, so any upward or downward move into
    /// the hero meets a guide before a pill.
    private func layoutFocusGuides(row: CGRect) {
        let gap = pillSpacing
        leftEdgeCatcher.frame = CGRect(x: row.minX - gap / 2 - 1, y: row.midY, width: 1, height: 1)
        rightEdgeCatcher.frame = CGRect(x: row.maxX + gap / 2, y: row.midY, width: 1, height: 1)
        let band: CGFloat = 8
        set(topEntryGuide, CGRect(x: 0, y: row.minY - columnSpacing - band, width: bounds.width, height: band))
        set(bottomEntryGuide, CGRect(x: 0, y: row.maxY + columnSpacing, width: bounds.width, height: band))
    }

    /// Constraint constants per guide (leading, top, width, height). A focus
    /// guide is a layout guide, so constraints are the only way to place it.
    private var guideConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    private func set(_ guide: UIFocusGuide, _ frame: CGRect) {
        let key = ObjectIdentifier(guide)
        let constraints: [NSLayoutConstraint]
        if let existing = guideConstraints[key] {
            constraints = existing
        } else {
            constraints = [
                guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                guide.topAnchor.constraint(equalTo: topAnchor),
                guide.widthAnchor.constraint(equalToConstant: 0),
                guide.heightAnchor.constraint(equalToConstant: 0),
            ]
            NSLayoutConstraint.activate(constraints)
            guideConstraints[key] = constraints
        }
        // Only write a changed constant, so placing the guides never schedules
        // another layout pass of this view.
        for (constraint, value) in zip(constraints, [frame.minX, frame.minY, frame.width, frame.height])
            where constraint.constant != value {
            constraint.constant = value
        }
    }

    /// Lays out the pill row with its bottom at `bottom`; returns the row height.
    @discardableResult
    private func layoutPills(bottom: CGFloat, leading: CGFloat) -> CGFloat {
        let visible = pillViews.filter { !$0.isHidden }
        guard !visible.isEmpty else {
            pillsContainer.frame = CGRect(x: leading, y: bottom, width: 0, height: 0)
            return 0
        }
        var height: CGFloat = 0
        var widths: [CGFloat] = []
        for pill in visible {
            let s = pill.preferredSize()
            widths.append(s.width)
            height = max(height, s.height)
        }
        let totalWidth = widths.reduce(0, +) + pillSpacing * CGFloat(visible.count - 1)
        pillsContainer.frame = CGRect(x: leading, y: bottom - height, width: totalWidth, height: height)
        var x: CGFloat = 0
        for (i, pill) in visible.enumerated() {
            // Position via bounds+center, not frame: a selected pill carries a 1.06
            // `transform`, and setting `.frame` on a transformed view back-computes a
            // shrunken bounds (width/1.06) and lays its content out in that smaller box
            // before scaling up — which visibly shifts the glyph/text on focus. bounds
            // and center are transform-independent, so the content stays put and only
            // the uniform scale is applied around the centre.
            pill.bounds = CGRect(x: 0, y: 0, width: widths[i], height: height)
            pill.center = CGPoint(x: x + widths[i] / 2, y: height / 2)
            pill.layoutIfNeeded()
            x += widths[i] + pillSpacing
        }
        return height
    }

    private func layoutDots(bottom: CGFloat, leading: CGFloat) {
        guard !currentDotLayout.isEmpty else {
            dotsContainer.isHidden = true
            return
        }
        dotsContainer.isHidden = false

        // Fixed-pitch slots: the active pill is `activeDotWidth` wide, every other dot
        // occupies a full `dotSize` slot (a shrunk edge dot is centred inside its slot)
        // so the row's total width — and thus the glass capsule — never breathes.
        let slotWidths: [CGFloat] = currentDotLayout.map {
            $0.index == activeDotIndex ? activeDotWidth : dotSize
        }
        var rowWidth: CGFloat = 0
        for (i, w) in slotWidths.enumerated() {
            rowWidth += w
            if i < slotWidths.count - 1 { rowWidth += dotSpacing }
        }
        let glassWidth = rowWidth + dotsGlassHPad * 2
        let glassHeight = dotsGlassHeight
        // Centre the capsule across the hero width, matching the SwiftUI hero.
        let glassX = (bounds.width - glassWidth) / 2
        dotsContainer.frame = CGRect(x: glassX, y: bottom - glassHeight, width: glassWidth, height: glassHeight)
        dotsContainer.layer.cornerRadius = glassHeight / 2
        dotsContainer.layer.cornerCurve = .continuous

        let morph = animateDotsMorph
        animateDotsMorph = false

        // A same-page re-apply (selection / metadata-fade) reaches here with an
        // unchanged layout. Re-running the positioning would snap the dot frames to
        // final and cancel a running page-morph animation, so skip it — the dots are
        // already where they belong. (Only the layout signature matters; the glass
        // capsule frame above is refreshed every pass in case the hero width changed.)
        let signature = [activeDotIndex ?? -1]
            + currentDotLayout.flatMap { [$0.index, $0.size.rank] }
        if !morph && signature == lastDotsSignature { return }
        lastDotsSignature = signature

        // Leading x of each visible slot, in its own (container) coordinate space.
        var slotX: [Int: CGFloat] = [:]
        var cursor = dotsGlassHPad
        for (i, d) in currentDotLayout.enumerated() {
            slotX[d.index] = cursor
            cursor += slotWidths[i] + dotSpacing
        }
        let windowStart = currentDotLayout.first!.index
        let windowEnd = currentDotLayout.last!.index
        let glassH = glassHeight
        let cy = glassH / 2

        // Start entering dots just OUTSIDE the entry edge of the capsule, at their
        // FULL-size (dotSize) height, then let `positionDots` slide them to their slot
        // inside the animation — so a new dot glides in horizontally from the left/right
        // edge (the direction the window scrolled) at full height and fades up from a
        // slight fill, rather than "forming" in place / growing from a corner. This
        // mirrors SwiftUI, where the whole row translates so the newcomer visibly
        // travels in from the edge while its opacity rises.
        let enterEdgeX = dotsScrollForward
            ? glassWidth - dotsGlassHPad + dotSpacing   // just past the right inner edge
            : dotsGlassHPad - dotSize - dotSpacing        // just past the left inner edge
        // A cyclic last↔first wrap replaces the entire visible index window. Starting
        // all eight new views at one edge makes them fan out from a single point.
        // SwiftUI instead treats these as independent insertion/removal transitions,
        // so crossfade each newcomer at its own final slot for this discontinuity.
        let replacesWholeWindow = enteringDotIndices.count > 1
        for idx in enteringDotIndices {
            guard let view = dotViewsByIndex[idx] else { continue }
            let draw = dotSize * view.currentScale
            view.bounds = CGRect(x: 0, y: 0, width: draw, height: draw)
            if replacesWholeWindow, let sx = slotX[idx] {
                view.center = CGPoint(x: sx + dotSize / 2, y: cy)
            } else {
                view.center = CGPoint(x: enterEdgeX + dotSize / 2, y: cy)
            }
            view.alpha = dotEnterStartAlpha
        }
        enteringDotIndices.removeAll()

        // Views that scrolled out of the window: fade them out IN PLACE (again like
        // SwiftUI's removal transition) and remove once faded — but only if they're
        // still outside the window then, so a dot that scrolls back in during rapid
        // reverse paging isn't deleted by a stale completion.
        let leaving = dotViewsByIndex.filter { $0.key < windowStart || $0.key > windowEnd }

        let positionDots = { [self] in
            for d in currentDotLayout {
                guard let view = dotViewsByIndex[d.index] else { continue }
                view.alpha = 1
                if d.index == activeDotIndex {
                    view.bounds = CGRect(x: 0, y: 0, width: activeDotWidth, height: dotSize)
                    view.center = CGPoint(x: slotX[d.index]! + activeDotWidth / 2, y: cy)
                } else {
                    // Shrunk circle centred inside a full-size slot.
                    let draw = dotSize * view.currentScale
                    view.bounds = CGRect(x: 0, y: 0, width: draw, height: draw)
                    view.center = CGPoint(x: slotX[d.index]! + dotSize / 2, y: cy)
                }
                view.layoutIfNeeded()
            }
            // Leaving dots fade in place — keep their current frame, just go transparent.
            for (_, view) in leaving {
                view.alpha = 0
            }
        }
        let cleanup = { [self] in
            for (idx, view) in leaving {
                // Still out of the (latest) window? Then it really left — remove it.
                let start = currentDotLayout.first?.index ?? 0
                let end = currentDotLayout.last?.index ?? -1
                if idx < start || idx > end {
                    view.removeFromSuperview()
                    dotViewsByIndex[idx] = nil
                }
            }
        }
        if morph {
            UIView.animate(withDuration: dotsMorphDuration, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState],
                           animations: positionDots,
                           completion: { _ in cleanup() })
        } else {
            positionDots()
            cleanup()
        }
    }
}

/// Stable ordering of the windowed dot sizes, used to build a cheap layout signature
/// so a same-page re-apply can be detected and skipped (avoids stomping a running
/// page-morph animation).
private extension HeroPagingDots.Size {
    var rank: Int {
        switch self {
        case .full: return 0
        case .medium: return 1
        case .small: return 2
        }
    }
}

/// One paging indicator drawn in UIKit: a dim capsule track plus (for the active
/// slide) a bright fill that grows from a dot to the full pill as the auto-advance
/// dwell elapses — the UIKit twin of the SwiftUI `pagingIndicator`/`activeDotFill`.
private final class HeroPagingDotView: UIView {
    private(set) var isActive = false
    private(set) var currentScale: CGFloat = 1
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        fill.isHidden = true
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(active: Bool, tint: UIColor, scale: CGFloat) {
        let becameActive = active && !isActive
        isActive = active
        currentScale = scale
        backgroundColor = tint.withAlphaComponent(0.28)
        fill.backgroundColor = tint
        fill.isHidden = !active
        // Only the gauge fill needs the capsule clip. A rounded clip over
        // sublayers is an offscreen pass, and inactive dots draw just their
        // own rounded background.
        clipsToBounds = active
        if becameActive, bounds.height > 0 {
            // Seed the active fill as a full-height circle before the enclosing dot
            // morph begins. Otherwise its first layout animates from CGRect.zero,
            // visibly growing from the parent's top-left corner.
            let height = bounds.height
            UIView.performWithoutAnimation {
                fill.bounds = CGRect(x: 0, y: 0, width: height, height: height)
                fill.center = CGPoint(x: height / 2, y: bounds.midY)
                fill.layer.cornerRadius = height / 2
            }
        }
        setNeedsLayout()
    }

    /// Sets the bright fill fraction (`0...1`). The fill interpolates from a dot
    /// (`height`) up to the full pill (`width`) so it starts moving immediately,
    /// matching the SwiftUI `brightFillWidth`.
    func setFillFraction(_ f: CGFloat) {
        fraction = max(0, min(1, f))
        runningGauge = nil
        HeroPagingGauge.setStatic(
            fill.layer,
            fraction: fraction,
            trackWidth: bounds.width,
            height: bounds.height
        )
        setNeedsLayout()
    }

    /// Hands the remaining dwell to Core Animation.
    ///
    /// The gauge is a linear ramp, so stating it once lets the render server
    /// draw every frame of it; the display link this replaces woke the app up
    /// thirty times a second to compute the same thing by hand.
    func runGauge(from f: CGFloat, remaining: TimeInterval) {
        fraction = max(0, min(1, f))
        runningGauge = (fraction, remaining)
        guard bounds.height > 0 else { return }
        HeroPagingGauge.animate(
            fill.layer,
            from: fraction,
            remaining: remaining,
            trackWidth: bounds.width,
            height: bounds.height
        )
    }

    /// Kept so a re-layout (a page morph resizing this dot) can restate the
    /// animation against the new track rather than dropping it.
    private var runningGauge: (fraction: CGFloat, remaining: TimeInterval)?

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        guard isActive, bounds.height > 0 else { return }
        HeroPagingGauge.prepare(
            fill.layer,
            height: bounds.height,
            midY: bounds.midY
        )
        // Restate a running gauge against the new track instead of writing a
        // frame under it, which would cancel the animation on every layout.
        if let runningGauge {
            HeroPagingGauge.animate(
                fill.layer,
                from: runningGauge.fraction,
                remaining: runningGauge.remaining,
                trackWidth: bounds.width,
                height: bounds.height
            )
        } else {
            HeroPagingGauge.setStatic(
                fill.layer,
                fraction: fraction,
                trackWidth: bounds.width,
                height: bounds.height
            )
        }
    }
}

/// A 1×1 invisible focus target just past one end of the hero's pill row.
final class HeroEdgeCatcher: UIView {
    let direction: HeroFocusDirection
    var isActive = true

    init(direction: HeroFocusDirection) {
        self.direction = direction
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { isActive }
}

/// A `UILabel` with content insets, used for the bordered rating chip.
private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets.zero
    var fixedHeight: CGFloat?
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(
            width: s.width + insets.left + insets.right,
            height: fixedHeight ?? (s.height + insets.top + insets.bottom)
        )
    }
}
#endif
