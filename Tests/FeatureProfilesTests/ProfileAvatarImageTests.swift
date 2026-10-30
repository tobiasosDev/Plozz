#if canImport(UIKit)
import XCTest
import SwiftUI
import UIKit
@testable import FeatureProfiles
import CoreModels

@MainActor
final class ProfileAvatarImageTests: XCTestCase {
    func testPhotoImageCarriesCircularCropWithoutViewModifiers() throws {
        let avatar = ProfileAvatarView(profile: Profile(name: "Photo"), size: 32, rendersAsImage: true)
        for sourceSize in [
            CGSize(width: 32, height: 32),
            CGSize(width: 96, height: 32),
            CGSize(width: 32, height: 96)
        ] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
                UIColor.green.setFill()
                context.fill(CGRect(
                    x: (sourceSize.width - 32) / 2,
                    y: (sourceSize.height - 32) / 2,
                    width: 32,
                    height: 32
                ))
            }
            let image = try render(avatar.nativePhotoImage(Image(uiImage: source)))
            try assertCircle(image)
            for x in [4, 16, 27] {
                let pixel = try pixel(image, x: x, y: 16)
                XCTAssertEqual(pixel[0], 0, accuracy: 2)
                XCTAssertEqual(pixel[1], 255, accuracy: 2)
                XCTAssertEqual(pixel[3], 255, accuracy: 2)
            }
        }
    }

    func testSymbolFallbackIncludesItsColoredCircle() throws {
        let profile = Profile(name: "Symbol", avatarSymbol: "person.fill", colorIndex: 0)
        let avatar = ProfileAvatarView(profile: profile, size: 32, rendersAsImage: true)
        let image = try render(avatar.nativeFallbackImage)
        try assertCircle(image)
        // A still gradient lit from the top-left: the tile colour at the far
        // edge, lifted toward white near the highlight.
        let color = ProfileTileColor.paletteRGB[0]
        let edge = try pixel(image, x: 26, y: 26)
        XCTAssertEqual(edge[0], color.r * 255, accuracy: 3)
        XCTAssertEqual(edge[1], color.g * 255, accuracy: 3)
        XCTAssertEqual(edge[2], color.b * 255, accuracy: 3)
        XCTAssertEqual(edge[3], 255, accuracy: 2)
        let highlight = try pixel(image, x: 6, y: 10)
        XCTAssertGreaterThan(highlight[1], color.g * 255 + 40)
        XCTAssertGreaterThanOrEqual(highlight[0], color.r * 255 - 2)
        XCTAssertEqual(highlight[3], 255, accuracy: 2)
    }

    func testEmojiFallbackKeepsNeutralOrChosenBackground() throws {
        let colorIndices: [Int?] = [nil, 0]
        for colorIndex in colorIndices {
            var profile = Profile(name: "Emoji")
            profile.avatarEmoji = "\u{1F600}"
            profile.avatarEmojiColorIndex = colorIndex
            let avatar = ProfileAvatarView(profile: profile, size: 32, rendersAsImage: true)
            let image = try render(avatar.nativeFallbackImage)
            try assertCircle(image)
            let background = try pixel(image, x: 16, y: 3)
            XCTAssertEqual(background[3], colorIndex == nil ? 0.35 * 255 : 255, accuracy: 2)
            XCTAssertGreaterThan(try pixel(image, x: 16, y: 16)[3], background[3] - 1)
        }
    }

    func testNativeImageDoesNotTakeTheNavigationTint() throws {
        let avatar = ProfileAvatarView(profile: Profile(name: "Symbol", colorIndex: 0), size: 32)
        let renderer = ImageRenderer(content: avatar.nativeFallbackImage.foregroundStyle(.blue))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(try pixel(image, x: 16, y: 3)[0], 200)
    }

    func testExistingAvatarRenderingRemainsTheDefault() {
        XCTAssertFalse(ProfileAvatarView(profile: Profile(name: "Default"), size: 32).rendersAsImage)
    }

    private func render(_ image: Image) throws -> UIImage {
        let renderer = ImageRenderer(content: image)
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func assertCircle(_ image: UIImage) throws {
        XCTAssertEqual(image.size, CGSize(width: 32, height: 32))
        for (x, y) in [(0, 0), (31, 0), (0, 31), (31, 31)] {
            XCTAssertEqual(try pixel(image, x: x, y: y)[3], 0)
        }
        XCTAssertGreaterThan(try pixel(image, x: 16, y: 3)[3], 0)
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [Double] {
        let pixels = try rgbaPixels(image)
        let offset = (y * pixels.width + x) * 4
        return pixels.bytes[offset..<(offset + 4)].map(Double.init)
    }

    private func rgbaPixels(_ image: UIImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, bytes)
    }
}
#endif
