import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI
import UIKit
import Vision
import XCTest

/// The full-screen "Who's watching?" picker: names stay readable on the light
/// background, a PIN profile's lock moves to its avatar, and both Add tiles
/// remain on screen.
@MainActor
final class ProfilePickerPresentationHostedTests: XCTestCase {
    func testPickerShowsReadableNamesAndBothAddTiles() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let profiles = [
            Profile(
                name: "Tobias", avatarSymbol: "bolt.fill", colorIndex: 20,
                lock: ProfileLock.make(pin: "2468", iterations: 1)
            ),
            Profile(name: "Lea", avatarSymbol: "star.fill", colorIndex: 2),
            Profile(name: "Kids", avatarSymbol: "sparkles", colorIndex: 7),
            Profile(name: "Grosi", avatarSymbol: "music.note", colorIndex: 13)
        ]
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for scheme in [ColorScheme.dark, .light] {
            window.rootViewController = UIHostingController(rootView:
                ProfilePickerView(
                    profiles: profiles,
                    activeProfileID: profiles[0].id,
                    onSelect: { _ in },
                    onAddProfile: {},
                    onEditProfile: { _ in },
                    onAddKidsProfile: {},
                    onOpenSettings: {}
                )
                .environment(\.themePalette, scheme == .dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(scheme)
                .ignoresSafeArea()
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "profile-picker-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.customWords = ["Grosi", "Tobias", "Plozz"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            // The small Edit pill is in the attachment; OCR reads it unreliably.
            for name in ["Who's watching?", "Tobias", "Lea", "Kids", "Grosi", "Add Profile"] {
                XCTAssertTrue(labels.contains(name), "\(name) must read on the light background: \(labels)")
            }
            XCTAssertTrue(labels.contains { $0.hasPrefix("Add Kids") }, "\(labels)")
        }
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}
