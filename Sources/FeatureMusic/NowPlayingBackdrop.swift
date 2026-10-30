#if canImport(SwiftUI) && canImport(UIKit)
import CoreImage
import CoreUI
import SwiftUI
import UIKit

/// The Now Playing backdrop: the current album art, blurred ONCE into a small
/// bitmap and stretched across the screen behind a legibility scrim — the Apple
/// TV app's music player.
///
/// It replaces the morphing mesh (`LiquidArtworkBackground`), which redrew on a
/// 30 fps `TimelineView` for as long as the player was open: continuous GPU work
/// on a screen that otherwise sits still while a song plays. Here a track costs
/// one Core Image pass on a 96-point thumbnail; after that the GPU only
/// composites a texture, and nothing redraws until the track changes.
struct NowPlayingBackdrop: View {
    /// A blurred bitmap and the track it was made from. Identity is the track,
    /// so a change of track cross-fades even when two tracks share their art.
    struct Artwork: Equatable {
        let image: CGImage
        let identity: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    }

    let artwork: Artwork?
    let style: LiquidArtworkBackground.Style

    var body: some View {
        ZStack {
            (style == .light ? Color.white : Color.black)
            if let artwork {
                // Sized by the screen, not by the bitmap: the square art fills
                // the frame and the overflow is clipped to it (a plain bounds
                // clip, not a mask).
                Color.clear
                    .overlay {
                        Image(decorative: artwork.image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .opacity(style == .pureBlack ? 0.5 : 1)
                    .id(artwork.identity)
                    .transition(.opacity)
            }
            scrim
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: artwork)
        .accessibilityHidden(true)
    }

    /// Per-style legibility layers, as `LiquidArtworkBackground` paints them:
    /// a dark veil darkening toward the edges away from the artwork for Dark
    /// and Pure Black, a light veil for the frosted look. Static gradients, so
    /// they composite like a flat fill.
    @ViewBuilder
    private var scrim: some View {
        // Centred on the artwork, which sits left of centre.
        let artCentre = UnitPoint(x: 0.2, y: 0.4)
        switch style {
        case .dark:
            Color.black.opacity(0.2)
            RadialGradient(colors: [.clear, Color.black.opacity(0.4)],
                           center: artCentre, startRadius: 0, endRadius: 1500)
        case .pureBlack:
            Color.black.opacity(0.55)
            RadialGradient(colors: [.clear, Color.black.opacity(0.75)],
                           center: artCentre, startRadius: 0, endRadius: 1400)
        case .light:
            Color.white.opacity(0.4)
            RadialGradient(colors: [.clear, Color.white.opacity(0.2)],
                           center: artCentre, startRadius: 0, endRadius: 1500)
        }
    }
}

/// Blurs album art for `NowPlayingBackdrop`, off the main actor. One shared
/// Core Image context, created once, as `VideoPreviewColorWorker` does.
actor NowPlayingBackdropRenderer {
    static let shared = NowPlayingBackdropRenderer()

    /// Edge of the blurred bitmap. The blur erases all detail anyway, so a
    /// thumbnail stretched to the screen looks the same as a full-size image
    /// blurred at full size, for a fraction of the work and memory.
    static let edge: CGFloat = 96

    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])

    /// The art downscaled, blurred, its colour lifted and its exposure lowered
    /// (the concept's `blur(90px) saturate(1.8) brightness(.8)` at thumbnail
    /// scale). `nil` for an image Core Image cannot read.
    func blurred(_ source: SendableImage) -> SendableImage? {
        let image = CIImage(cgImage: source.cgImage)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let scale = Self.edge / max(extent.width, extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let output = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 5)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.8])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.32])
            .cropped(to: small.extent)
        return context.createCGImage(output, from: small.extent).map(SendableImage.init)
    }

    /// A decoded bitmap handed to and from the renderer. `CGImage` is
    /// immutable, so sharing one across the actor boundary is safe.
    struct SendableImage: @unchecked Sendable {
        let cgImage: CGImage
    }
}
#endif
