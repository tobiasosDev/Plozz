#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit

/// `ProviderBrandMark` drawn once into a bitmap, for surfaces that show it next
/// to moving content: a Home hero over a playing trailer, a Continue Watching
/// card that lifts on focus. Hosted live, the mark is a RenderBox layer that
/// SwiftUI re-renders through Metal whenever its host lays out, which on the
/// hero is every frame of the paging gauge. A bitmap is plain layer contents.
@MainActor
public enum ProviderBrandMarkBitmap {
    private struct Key: Hashable {
        let provider: ProviderKind
        let size: CGFloat
        let scale: CGFloat
        let colorScheme: ColorScheme
    }

    private static var cache: [Key: UIImage] = [:]

    /// The mark at `size` points and `scale` pixels per point, cached for the
    /// life of the process (a handful of providers × sizes).
    public static func image(
        provider: ProviderKind, size: CGFloat, scale: CGFloat, colorScheme: ColorScheme = .dark
    ) -> UIImage? {
        let key = Key(provider: provider, size: size, scale: max(scale, 1), colorScheme: colorScheme)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(
            content: ProviderBrandMark(provider: provider, size: size)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = key.scale
        guard let image = renderer.uiImage else { return nil }
        cache[key] = image
        return image
    }
}
#endif
