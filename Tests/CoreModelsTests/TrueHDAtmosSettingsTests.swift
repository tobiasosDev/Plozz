import XCTest
@testable import CoreModels

final class TrueHDAtmosSettingsTests: XCTestCase {
    func testDefaultAndOlderPayloadsKeepSpatialAudioEnabled() throws {
        XCTAssertTrue(PlaybackSettings.default.trueHDAtmosEnabled)
        for payload in [
            #"{}"#,
            #"{"trueHDAtmosEnabled":true}"#,
            #"{"trueHDAtmosEnabled":null}"#,
            #"{"trueHDAtmosEnabled":"unknown"}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings, .default)
            let encoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
            )
            XCTAssertEqual(encoded["trueHDAtmosEnabled"] as? Bool, true)
        }
    }

    func testBothSavedChoicesRoundTripWithoutChangingOtherPlaybackPreferences() throws {
        for enabled in [false, true] {
            let payload = """
            {"trueHDAtmosEnabled":\(enabled),"dolbyVisionFELEnabled":true,"rememberAudioTrackPerSeries":false}
            """
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings, PlaybackSettings(
                trueHDAtmosEnabled: enabled,
                dolbyVisionFELEnabled: true,
                rememberAudioTrackPerSeries: false
            ))
            XCTAssertEqual(
                try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)),
                settings
            )
        }
    }

    @MainActor
    func testSavedOffChoiceRemainsScopedAndSurvivesProfileTransfer() throws {
        let suite = "TrueHDAtmosSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primaryStore = PlaybackSettingsStore(defaults: defaults)
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let guestKey = SettingsKey.scoped("com.plozz.playbackSettings", namespace: "guest")
        defaults.set(Data(
            #"{"trueHDAtmosEnabled":false,"rememberAudioTrackPerSeries":false}"#.utf8
        ), forKey: guestKey)
        let guest = PlaybackSettingsModel(store: guestStore)
        let expected = PlaybackSettings(trueHDAtmosEnabled: false, rememberAudioTrackPerSeries: false)
        XCTAssertEqual(guest.settings, expected)
        XCTAssertEqual(PlaybackSettingsModel(store: primaryStore).settings, .default)

        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        let restoredStore = PlaybackSettingsStore(defaults: defaults, namespace: "restored")
        XCTAssertEqual(restoredStore.load(), expected)

        guest.settings.audioLanguagePreference = .language("ja")
        guest.settings.trueHDAtmosEnabled = true
        XCTAssertEqual(guestStore.load().audioLanguagePreference, .language("ja"))
        XCTAssertEqual(restoredStore.load(), expected)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: guestKey))) as? [String: Any]
        )
        XCTAssertEqual(saved["trueHDAtmosEnabled"] as? Bool, true)
        XCTAssertFalse(restoredStore.load().trueHDAtmosEnabled)
    }
}
