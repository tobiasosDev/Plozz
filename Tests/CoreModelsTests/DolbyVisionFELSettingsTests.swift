import XCTest
@testable import CoreModels

final class DolbyVisionFELSettingsTests: XCTestCase {
    func testDefaultAndOlderPayloadsEnableLosslessProfile7() throws {
        XCTAssertTrue(PlaybackSettings.default.dolbyVisionFELEnabled)
        for payload in [
            #"{}"#,
            #"{"dolbyVisionLosslessFEL":null}"#,
            #"{"dolbyVisionLosslessFEL":"unknown"}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertTrue(settings.dolbyVisionFELEnabled, payload)
        }
    }

    func testRetiredExperimentalKeyIsIgnoredAndNoLongerEncoded() throws {
        for payload in [
            #"{"dolbyVisionFELEnabled":false,"rememberAudioTrackPerSeries":false}"#,
            #"{"dolbyVisionFELEnabled":true,"rememberAudioTrackPerSeries":false}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings, PlaybackSettings(rememberAudioTrackPerSeries: false), payload)
            let encoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
            )
            XCTAssertNil(encoded["dolbyVisionFELEnabled"])
            XCTAssertEqual(encoded["dolbyVisionLosslessFEL"] as? Bool, true)
        }
        let optedOut = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"dolbyVisionFELEnabled":true,"dolbyVisionLosslessFEL":false}"#.utf8
        ))
        XCTAssertFalse(optedOut.dolbyVisionFELEnabled)
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
        guest.settings.dolbyVisionFELEnabled = false

        XCTAssertTrue(PlaybackSettingsModel(store: primaryStore).settings.dolbyVisionFELEnabled)
        XCTAssertFalse(PlaybackSettingsModel(store: guestStore).settings.dolbyVisionFELEnabled)
        XCTAssertTrue(guestStore.load().rememberAudioTrackPerSeries)

        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        XCTAssertFalse(
            PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().dolbyVisionFELEnabled
        )
        guest.settings.dolbyVisionFELEnabled = true
        XCTAssertTrue(guestStore.load().dolbyVisionFELEnabled)
        XCTAssertFalse(
            PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().dolbyVisionFELEnabled
        )
    }

    @MainActor
    func testProfileSavedByTheExperimentAdoptsLosslessProfile7() throws {
        let suite = "DolbyVisionFELSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: "guest")
        defaults.set(Data(
            #"{"dolbyVisionFELEnabled":false,"rememberAudioTrackPerSeries":false}"#.utf8
        ), forKey: key)

        let settings = PlaybackSettingsStore(defaults: defaults, namespace: "guest").load()
        XCTAssertTrue(settings.dolbyVisionFELEnabled)
        XCTAssertFalse(settings.rememberAudioTrackPerSeries)
    }
}
