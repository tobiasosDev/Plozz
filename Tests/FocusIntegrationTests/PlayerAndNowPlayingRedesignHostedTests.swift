import AVFoundation
import CoreModels
import CoreUI
@testable import FeatureMusic
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

/// The Apple TV redesign of the player transport, its Subtitles menu and the
/// music Now Playing screen, rendered with local fixtures in both material
/// modes: native glass, and the reduced-glass fallback Apple TV HD and 4K first
/// generation use. Each case reads back the copy the layout promises and keeps
/// the frame as an attachment (and, with `PLOZZ_SCREENSHOT_DIR` set in the
/// test runner's environment, as a PNG there).
@MainActor
final class PlayerAndNowPlayingRedesignHostedTests: XCTestCase {
    func testTransportShowsMetaLineRoundTrackControlsAndThreeTimes() async throws {
        let window = try await makeWindow()
        defer { tearDown(window) }
        for reduced in [false, true] {
            let model = makeTransportModel()
            XCTAssertEqual(model.trackControlCategories, [.playback, .audio, .subtitles, .version],
                           "Versions come last, after the per-title tracks.")
            window.rootViewController = UIHostingController(rootView: playerFixture(model: model, reduced: reduced))
            window.makeKeyAndVisible()
            let image = try await capture(window, settle: .milliseconds(900))
            save(image, name: "09-player\(reduced ? "-reduced" : "")")
            let text = try recognizedText(in: image)
            XCTAssertTrue(text.contains("Tears of Steel"), text)
            XCTAssertTrue(text.contains("Movie") && text.contains("2012") && text.contains("Dolby Vision"),
                          "The meta line names the kind, year and picture format: \(text)")
            XCTAssertFalse(text.contains("Atmos"), "Audio formats stay on the Info card: \(text)")
            XCTAssertTrue(text.contains("46:40"), "Elapsed time under the playhead: \(text)")
            XCTAssertTrue(text.contains("Ends at"), "The finish time sits beside the remaining time: \(text)")
            XCTAssertTrue(text.contains("41:40"), "Remaining time at the trailing edge: \(text)")
            XCTAssertTrue(text.contains("Info") && text.contains("Cast"), text)
            window.rootViewController = nil
        }
    }

    func testSubtitlesMenuListsTracksThenTheirSettingsAsRows() async throws {
        let window = try await makeWindow()
        defer { tearDown(window) }
        for reduced in [false, true] {
            let model = makeTransportModel()
            model.subtitleOptions = TrackMenuBuilder.subtitleOptions(
                tracks: [
                    MediaTrack(id: 1, kind: .subtitle, displayTitle: "English", language: "en",
                               codec: "subrip", isHearingImpaired: true),
                    MediaTrack(id: 2, kind: .subtitle, displayTitle: "Deutsch", language: "de", codec: "subrip"),
                    MediaTrack(id: 3, kind: .subtitle, displayTitle: "Français", language: "fr", codec: "subrip"),
                    MediaTrack(id: 4, kind: .subtitle, displayTitle: "Nederlands", language: "nl",
                               codec: "subrip", isForced: true)
                ],
                selectedID: 1, preferred: [], detectedLanguages: [:], locale: Locale(identifier: "en")
            )
            XCTAssertEqual(model.subtitleOptions[1].nativeTitle, "English (SDH)",
                           "Native menus keep the composed label.")
            model.secondarySubtitleOptions = [
                PlayerTrackOption(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: true),
                PlayerTrackOption(id: 2, title: Text("Deutsch"), isSelected: false)
            ]
            model.subtitleDelayAdjustable = true
            model.subtitleDownload.canSearch = true
            let rows = PlayerOptionsPanel.subtitleRows(model: model, actions: PlayerOptionsActions())
            XCTAssertNotNil(rows[1].detail, "Qualifiers move out of the title into their own slot.")
            PlayerScreenshotHook.pendingPanel = .subtitleTracks
            window.rootViewController = UIHostingController(rootView: playerFixture(model: model, reduced: reduced))
            window.makeKeyAndVisible()
            let image = try await capture(window, settle: .milliseconds(1_200))
            save(image, name: "10-player-subs\(reduced ? "-reduced" : "")")
            let text = try recognizedText(in: image)
            for expected in ["Subtitles", "English", "SDH", "Forced", "Dual Subtitles", "Subtitle Sync",
                             "Style", "Download Subtitles"] {
                XCTAssertTrue(text.contains(expected), "\(expected) missing from the Subtitles menu: \(text)")
            }
            XCTAssertFalse(text.contains("(SDH)"), "SDH is a qualifier beside the name, not in parentheses: \(text)")
            window.rootViewController = nil
        }
    }

    func testNowPlayingLaysOutArtTextControlsProgressLyricsAndSource() async throws {
        let window = try await makeWindow()
        defer { tearDown(window) }
        let art = try XCTUnwrap(Self.albumArt().pngData())
        let server = try IPTVTestHTTPServer { _ in
            IPTVTestHTTPServer.Response(data: art, headers: ["Content-Type": "image/png"])
        }
        let base = try await server.start()
        defer { Task { await server.stop() } }
        let audio = try Self.silentAudio(seconds: 242)
        defer { try? FileManager.default.removeItem(at: audio) }

        for reduced in [false, true] {
            let controller = AudioPlaybackController(nowPlayingPublisher: nil)
            defer { controller.stop() }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "now-playing-redesign-\(UUID().uuidString)"))
            let settings = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(defaults: defaults))
            settings.showTrackDetails = true
            let lines = [
                "Die Stadt schläft nie, sie blinzelt nur", "Regen schreibt Namen an die Scheiben",
                "Und wir fahren, bis der Morgen kommt", "Alle Ampeln grün für uns zwei",
                "Radio leise, Herz so laut", "Nur noch eine Kurve bis nach Haus"
            ]
            controller.play(
                tracks: [MusicTrack(
                    id: "nachtfahrt", title: "Nachtfahrt", albumTitle: "Stadtlichter",
                    artistName: "Lina Sommer", duration: 242,
                    artworkURL: base.appendingPathComponent("art-\(reduced).png"), sourceAccountID: "living-room"
                )],
                startIndex: 0,
                resolveStreamURL: { _ in
                    .init(url: audio, quality: PlaybackQuality(
                        isDirectPlay: true, codec: "flac", sampleRate: 96_000, bitDepth: 24
                    ))
                },
                resolveLyrics: { _, _ in
                    .init(lyrics: Lyrics(lines: lines.enumerated().map {
                        LyricLine(text: $1, start: Double($0) * 10 + 110)
                    }))
                }
            )
            window.rootViewController = UIHostingController(rootView:
                NowPlayingView(controller: controller, appTheme: .dark, musicPlayer: settings)
                    .environment(\.plozzMediaSourceIdentities, [
                        "living-room": MediaSourceIdentity(provider: .jellyfin, serverName: "Wohnzimmer")
                    ])
                    .environment(\.plozzReducePlayerGlass, reduced)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await waitUntil { controller.isPlaying && controller.lyricsState.hasLyrics }
            await controller.seek(to: 134)
            let image = try await capture(window, settle: .milliseconds(1_500))
            save(image, name: "11-music\(reduced ? "-reduced" : "")")
            let text = try recognizedText(in: image)
            for expected in ["Nachtfahrt", "Lina Sommer", "Stadtlichter", "FLAC", "Jellyfin", "Wohnzimmer",
                             "Und wir fahren, bis der Morgen kommt"] {
                XCTAssertTrue(text.contains(expected), "\(expected) missing from Now Playing: \(text)")
            }
            window.rootViewController = nil
        }
    }

    // MARK: Fixtures

    private func makeTransportModel() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        // Library artwork only: the parked Info card must not look the fixture
        // title up online.
        model.artworkPolicy = ArtworkPresentationPolicy(area: .playback, settings: .init(preference: .library))
        model.controlsVisible = true
        model.duration = 5_300
        model.currentSeconds = 2_800
        model.bufferedSeconds = 3_600
        model.title = "Tears of Steel"
        model.infoCard.headline = "Tears of Steel"
        model.infoCard.artworkItem = MediaItem(id: "tos", title: "Tears of Steel", kind: .movie, productionYear: 2012)
        model.infoCard.badges = [
            MediaBadge("4K", style: .prominent),
            MediaBadge("Dolby Vision", style: .dolby),
            MediaBadge("Dolby Atmos", style: .dolby)
        ]
        model.infoCard.cast = [MediaPerson(id: "thom", name: "Derek de Lint", role: "Thom")]
        model.engineCapabilities = [.playbackSpeed]
        model.audioOptions = [
            PlayerTrackOption(id: 1, title: Text("English"), isSelected: true),
            PlayerTrackOption(id: 2, title: Text("Deutsch"), isSelected: false)
        ]
        model.subtitleOptions = [
            PlayerTrackOption(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: true),
            PlayerTrackOption(id: 1, title: Text("English"), isSelected: false)
        ]
        model.versions.options = [
            .init(version: .init(id: "4k"), isSelected: true),
            .init(version: .init(id: "hd"), isSelected: false)
        ]
        return model
    }

    private func playerFixture(model: PlayerControlsModel, reduced: Bool) -> some View {
        PlayerControls(model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {})
            .environment(\.plozzReducePanelGlass, reduced)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, .gmt)
            .background {
                Image(uiImage: Self.videoFrame())
                    .resizable()
                    .ignoresSafeArea()
            }
    }

    /// A stand-in video frame: a bright, busy scene, so glass and frost both have
    /// something to sit over.
    private static func videoFrame() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080)).image { context in
            let colors = [UIColor(red: 0.55, green: 0.66, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.30, green: 0.34, blue: 0.38, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1080), options: [])
            for index in 0..<14 {
                UIColor(white: index.isMultiple(of: 2) ? 0.85 : 0.12, alpha: 0.55).setFill()
                UIBezierPath(rect: CGRect(x: index * 150, y: 600 + (index % 3) * 60, width: 40, height: 480)).fill()
            }
            UIColor(white: 0.08, alpha: 0.8).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 700, width: 1920, height: 22)).fill()
        }
    }

    /// Album art with distinct colour, so the blurred backdrop visibly derives
    /// from it.
    private static func albumArt() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { _ in
            UIColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 600, height: 600)).fill()
            for (index, color) in [UIColor.systemRed, .systemYellow, .systemGreen, .white].enumerated() {
                color.withAlphaComponent(0.85).setFill()
                UIBezierPath(ovalIn: CGRect(x: 60 + index * 120, y: 180 + (index % 2) * 160, width: 90, height: 90)).fill()
            }
        }
    }

    private static func silentAudio(seconds: Double) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 8_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        return file
    }

    // MARK: Window, capture, text

    private func makeWindow() async throws -> UIWindow {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return window
    }

    private var previousKeyWindow: UIWindow?

    private func tearDown(_ window: UIWindow) {
        PlayerScreenshotHook.pendingPanel = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }

    private func capture(_ window: UIWindow, settle: Duration) async throws -> UIImage {
        window.layoutIfNeeded()
        try await Task.sleep(for: settle)
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["PLOZZ_SCREENSHOT_DIR"],
              let data = image.pngData() else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func recognizedText(in image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "de-DE"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
    }

    private func waitUntil(
        timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the fixture")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
