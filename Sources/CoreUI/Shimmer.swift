#if canImport(SwiftUI)
import SwiftUI

/// A reusable shimmer overlay for placeholder/skeleton content: a soft, slow
/// sheen drifts across the view to gently signal "loading" — deliberately
/// understated (low intensity, wide feathered band, eased timing with an
/// off-screen pause between passes) so it reads as modern and calm rather than a
/// bright sweeping flash.
///
/// Accessibility: respects **Reduce Motion** — when set, the sweep is replaced by
/// a static dim so the placeholder still reads as inactive but nothing animates.
///
/// The sweep runs a few passes and then rests. A placeholder that loads in time
/// looks the same; one that never does — on a page the native sidebar keeps
/// mounted at zero opacity — stops costing frames after `passes`. It is a plain
/// translated gradient: an additive blend over a drawing group made SwiftUI
/// re-render every placeholder through Metal on the main thread each frame.
private struct ShimmerModifier: ViewModifier {
    var active: Bool
    /// One full sweep duration (slower = calmer).
    var duration: Double = 2.3
    /// Sweeps before the band rests off-screen (about nine seconds).
    var passes = 4
    /// Highlight strength in light mode — the card placeholders are a light gray
    /// on a light background, so a white sheen needs more punch to be
    /// visible at all.
    var lightIntensity: Double = 0.45
    /// Highlight strength in dark and Pure Black mode — on near-black the same sheen reads
    /// strongly, so it's kept very low to stay barely-there.
    var darkIntensity: Double = 0.035

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzHiddenDestination) private var hiddenDestination
    @State private var phase: CGFloat = -1

    private var intensity: Double {
        colorScheme == .dark ? darkIntensity : lightIntensity
    }

    func body(content: Content) -> some View {
        // A placeholder on a page that is mounted but not shown — an unselected
        // native sidebar tab, the page the rail keeps behind Live TV — does not
        // sweep at all.
        guard active, !hiddenDestination else { return AnyView(content) }
        if reduceMotion {
            return AnyView(content.opacity(0.65))
        }
        return AnyView(
            content
                .overlay {
                    GeometryReader { geo in
                        let width = geo.size.width
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(intensity), location: 0.5),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // A wide, soft band that travels well past both edges, so
                        // it's off-screen for part of each cycle — that gap is what
                        // gives the calm "breathe in / pause / breathe in" feel
                        // instead of a relentless strobe.
                        .frame(width: max(width, 1) * 0.95)
                        .offset(x: phase * max(width, 1) * 2.0)
                        // Keep the repeat off transactions used to mount unrelated native content.
                        .animation(
                            .easeInOut(duration: duration).repeatCount(passes, autoreverses: false),
                            value: phase
                        )
                        .allowsHitTesting(false)
                    }
                    .mask(content)
                }
                .onAppear {
                    phase = 1
                }
                .onDisappear { phase = -1 }
        )
    }
}

public extension View {
    /// Overlays an animated shimmer used by skeleton placeholders. Pass
    /// `active: false` to disable (e.g. once real content has loaded).
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

#endif
