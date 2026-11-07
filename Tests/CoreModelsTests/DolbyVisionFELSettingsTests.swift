import XCTest
@testable import CoreModels

final class DolbyVisionFELSettingsTests: XCTestCase {
    func testDefaultAndOlderPayloadsKeepFELDisabled() throws {
        XCTAssertFalse(PlaybackSettings.default.dolbyVisionFELEnabled)
        for payload in [
            #"{}"#,
            #"{"dolbyVisionFELEnabled":null}"#,
            #"{"dolbyVisionFELEnabled":"unknown"}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertFalse(settings.dolbyVisionFELEnabled)
        }
    }

    func testFELChoicesRoundTripWithoutChangingOtherAudioPreferences() throws {
        for enabled in [false, true] {
            let settings = PlaybackSettings(
                audioLanguagePreference: .language("ja"),
                dolbyVisionFELEnabled: enabled
            )
            XCTAssertEqual(
                try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)),
                settings
            )
        }
    }

    @MainActor
    func testBindingRestoresAndTransfersOnlyTheSelectedProfilesChoice() throws {
        let suite = "DolbyVisionFELSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primaryStore = PlaybackSettingsStore(defaults: defaults)
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let guest = PlaybackSettingsModel(store: guestStore)
        guest.settings.dolbyVisionFELEnabled = true

        XCTAssertFalse(PlaybackSettingsModel(store: primaryStore).settings.dolbyVisionFELEnabled)
        XCTAssertTrue(PlaybackSettingsModel(store: guestStore).settings.dolbyVisionFELEnabled)
        XCTAssertTrue(guestStore.load().rememberAudioTrackPerSeries)

        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        XCTAssertTrue(
            PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().dolbyVisionFELEnabled
        )
        guest.settings.dolbyVisionFELEnabled = false
        XCTAssertFalse(guestStore.load().dolbyVisionFELEnabled)
        XCTAssertTrue(
            PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().dolbyVisionFELEnabled
        )
    }
}
