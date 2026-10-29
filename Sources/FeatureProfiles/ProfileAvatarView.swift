#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Renders a profile's avatar at `size` pt. Prefers the opt-in real photo
/// (`Profile.avatarImageURL`) when present and reachable; otherwise falls
/// back to the SF Symbol on the colored tile (`avatarSymbol` + `colorIndex`).
///
/// Photos load through the shared `ArtworkImageCache` (via `FallbackAsyncImage`),
/// so an already-decoded avatar renders on the first frame with no flash, the
/// raw download is shared with the picker's background-color extraction, and a
/// re-opened picker shows photos instantly. While a photo is still loading it
/// shows a quiet neutral placeholder (not the colored symbol), so a photo
/// profile never briefly flashes a stand-in icon behind the photo. The symbol
/// fallback is reserved for symbol-only profiles and genuine load failures.
public struct ProfileAvatarView: View {
    public let profile: Profile
    public let size: CGFloat
    public let rendersAsImage: Bool

    public init(profile: Profile, size: CGFloat, rendersAsImage: Bool = false) {
        self.profile = profile
        self.size = size
        self.rendersAsImage = rendersAsImage
    }

    public var body: some View {
        Group {
            if let urlString = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces),
               !urlString.isEmpty,
               let url = URL(string: urlString) {
                FallbackAsyncImage(
                    references: [.remote(url)],
                    variant: Self.variant(for: size),
                    content: { image in
                        if rendersAsImage {
                            nativePhotoImage(image)
                        } else {
                            ArtworkFillImage(image)
                        }
                    }
                ) {
                    // Shown only when the photo genuinely fails to load — keeps the
                    // tile recognizable instead of an empty circle.
                    emojiOrSymbolFallback
                }
            } else {
                emojiOrSymbolFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Emoji (if chosen) else the symbol tile. Used both as the primary
    /// non-photo avatar and as the fallback when a borrowed photo URL fails.
    @ViewBuilder
    private var emojiOrSymbolFallback: some View {
        if rendersAsImage {
            nativeFallbackImage
        } else if let emoji {
            emojiTile(emoji)
        } else {
            symbolFallback
        }
    }

    /// Native Apple emoji rendered as text. By default it sits on a
    /// theme-neutral disc (colours often clash with a multicolour emoji), but a
    /// profile may opt into a palette colour via `avatarEmojiColorIndex` — so the
    /// background is the chosen colour when set, otherwise a neutral surface.
    private func emojiTile(_ emoji: String) -> some View {
        ZStack {
            Circle().fill(emojiBackground)
            Text(emoji)
                .font(.system(size: size * 0.55))
                .minimumScaleFactor(0.5)
        }
    }

    /// Theme-aware neutral disc behind an emoji avatar: a muted grey that reads
    /// on both light and dark themes without competing with the emoji's own
    /// colours.
    private static var neutralEmojiBackground: Color {
        Color.gray.opacity(0.35)
    }

    private var emoji: String? {
        let value = profile.avatarEmoji?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    private var emojiBackground: Color {
        profile.avatarEmojiColorIndex.map(ProfileTileColor.color(forIndex:))
            ?? Self.neutralEmojiBackground
    }

    // Native tab labels on tvOS 26 extract the Image but discard its surrounding
    // view modifiers. Encode the size, crop and colors in the image itself.
    func nativePhotoImage(_ image: Image) -> Image {
        nativeImage { context, bounds in
            let resolved = context.resolve(image)
            let scale = max(
                bounds.width / resolved.size.width,
                bounds.height / resolved.size.height
            )
            let width = resolved.size.width * scale
            let height = resolved.size.height * scale
            context.draw(resolved, in: CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            ))
        }
    }

    var nativeFallbackImage: Image {
        nativeImage { context, bounds in
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if let emoji {
                context.fill(Path(ellipseIn: bounds), with: .color(emojiBackground))
                context.draw(
                    Text(verbatim: emoji).font(.system(size: size * 0.55)),
                    at: center
                )
            } else {
                context.fill(Path(ellipseIn: bounds), with: .radialGradient(
                    Self.symbolGradient(for: profile),
                    center: CGPoint(x: bounds.width * 0.3, y: bounds.height * 0.25),
                    startRadius: 0, endRadius: size * Self.gradientReach
                ))
                context.draw(
                    Text(Image(systemName: profile.avatarSymbol))
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(ProfileTileColor.legibleForeground(for: profile)),
                    at: center
                )
            }
        }
    }

    private func nativeImage(
        draw: @escaping (inout GraphicsContext, CGRect) -> Void
    ) -> Image {
        Image(
            size: CGSize(width: size, height: size),
            label: Text(verbatim: profile.name)
        ) { context in
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            context.clip(to: Path(ellipseIn: bounds))
            draw(&context, bounds)
        }
        .renderingMode(.original)
    }

    /// Where the gradient reaches the tile's own colour, relative to its size.
    private static let gradientReach: CGFloat = 0.72

    /// The tile colour lifted halfway to white at the highlight.
    private static func symbolGradient(for profile: Profile) -> Gradient {
        let base = ProfileTileColor.color(for: profile)
        return Gradient(colors: [base.mix(with: .white, by: 0.5), base])
    }

    /// Picks a cache variant sized to the avatar: a crisp source for the large
    /// picker tiles, a cheap thumbnail for the small Settings rows.
    private static func variant(for size: CGFloat) -> ArtworkImageVariant {
        size >= 160 ? .posterCard : .musicThumbnail
    }

    /// Symbol on colored tile — the original avatar style. Also used as the
    /// fallback when a borrowed photo URL fails to load. The glyph colour adapts
    /// to the tile so it stays legible on light backgrounds (e.g. a white or
    /// yellow tile gets a dark glyph instead of an invisible white one).
    ///
    /// The tile is a still radial gradient, lit from the top-left like the tvOS
    /// profile avatars: one static fill, no layer or effect added.
    private var symbolFallback: some View {
        ZStack {
            Circle().fill(RadialGradient(
                gradient: Self.symbolGradient(for: profile),
                center: UnitPoint(x: 0.3, y: 0.25),
                startRadius: 0, endRadius: size * Self.gradientReach
            ))
            Image(systemName: profile.avatarSymbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(ProfileTileColor.legibleForeground(for: profile))
        }
    }
}
#endif
