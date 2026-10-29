#if canImport(SwiftUI)
import SwiftUI

/// The profile picker's background: a still, light pastel field like the
/// wallpaper behind the tvOS profile picker — a warm glow top-left, a cool one
/// top-right and a deeper blue pooling at the bottom.
///
/// Deliberately static and theme-independent. It used to be a per-profile
/// colour mesh under a full-screen mask that re-rendered as focus settled;
/// these are plain gradient fills, composited once, with no mask, blur or
/// animation, so moving between profiles costs nothing here.
struct ProfileBackgroundGradient: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.616, green: 0.718, blue: 0.812), Color(red: 0.357, green: 0.525, blue: 0.706)],
                    startPoint: .top, endPoint: .bottom
                )
                glow(Color(red: 0.969, green: 0.718, blue: 0.588), opacity: 0.95,
                     radii: CGSize(width: 900, height: 520), at: CGPoint(x: 0.18, y: 0.16), fade: 0.70, in: size)
                glow(Color(red: 0.471, green: 0.698, blue: 0.886), opacity: 0.95,
                     radii: CGSize(width: 1100, height: 700), at: CGPoint(x: 0.82, y: 0.10), fade: 0.70, in: size)
                glow(Color(red: 0.243, green: 0.439, blue: 0.667), opacity: 1,
                     radii: CGSize(width: 1400, height: 900), at: CGPoint(x: 0.60, y: 0.95), fade: 0.72, in: size)
                glow(.white, opacity: 0.12,
                     radii: CGSize(width: 1200, height: 700), at: CGPoint(x: 0.5, y: 0.5), fade: 0.70, in: size)
            }
        }
        // The glows are larger than the screen; a rectangular clip, not a mask.
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One elliptical glow, scaled from the 1920×1080 design so it keeps its
    /// proportions on other window sizes. `fade` is where it reaches zero, as a
    /// fraction of its radii.
    private func glow(
        _ color: Color, opacity: Double, radii: CGSize, at center: CGPoint, fade: CGFloat, in size: CGSize
    ) -> some View {
        let scale = size.width / 1920
        let width = radii.width * 2 * scale
        let height = radii.height * 2 * scale
        return EllipticalGradient(
            colors: [color.opacity(opacity), color.opacity(0)],
            center: .center, startRadiusFraction: 0, endRadiusFraction: fade / 2
        )
        .frame(width: width, height: height)
        .position(x: size.width * center.x, y: size.height * center.y)
    }
}
#endif
