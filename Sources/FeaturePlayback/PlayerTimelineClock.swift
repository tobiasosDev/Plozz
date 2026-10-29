#if canImport(UIKit)
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class PlayerTimelineClock {
    public var isEnabled = false

    public init() {}
}

public struct PlayerClockTimes {
    public let current: String
    public let endTime: String?
    public let end: LocalizedStringResource?
    public let currentWidthSamples: [String]
    public let endWidthSamples: [LocalizedStringResource]

    static func estimatedEnd(
        now: Date, position: TimeInterval, duration: TimeInterval, speed: Double
    ) -> Date? {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0,
              speed.isFinite, speed > 0 else { return nil }
        let remaining = max(0, duration - position) / speed
        guard remaining.isFinite else { return nil }
        let end = now.addingTimeInterval(remaining)
        guard end >= now, end <= .distantFuture else { return nil }
        return end
    }

    init(
        now: Date, position: TimeInterval, duration: TimeInterval, speed: Double,
        locale: Locale, timeZone: TimeZone
    ) {
        let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        current = now.formatted(format)
        func endLabel(_ time: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "Ends at \(time)", locale: locale,
                comment: "Estimated playback completion time on the clock, for example Ends at 11:42 PM."
            )
        }
        endTime = Self.estimatedEnd(now: now, position: position, duration: duration, speed: speed)
            .map { $0.formatted(format) }
        end = endTime.map(endLabel)
        // Reserve both day periods and two hour digits so a clock rollover cannot
        // move the touch scrubber, including while its labels show the seek target.
        currentWidthSamples = Self.clockWidthSamples(locale: locale)
        endWidthSamples = currentWidthSamples.map(endLabel)
    }

    static func clockWidthSamples(locale: Locale) -> [String] {
        let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: .gmt)
        return [11, 23].map {
            Date(timeIntervalSince1970: Double($0 * 3_600 + 59 * 60)).formatted(format)
        }
    }
}

/// Mounts the wall clock only on demand, keeping its ticks out of the player root.
public struct PlayerClockTimeline<Content: View>: View {
    let model: PlayerControlsModel
    let enabled: Bool
    let paused: Bool
    let content: (PlayerClockTimes?) -> Content
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(
        model: PlayerControlsModel, enabled: Bool, paused: Bool = false,
        @ViewBuilder content: @escaping (PlayerClockTimes?) -> Content
    ) {
        self.model = model
        self.enabled = enabled
        self.paused = paused
        self.content = content
    }
    public var body: some View {
        if enabled {
            TimelineView(PlayerClockSchedule(paused: paused)) { context in
                content(PlayerClockTimes(
                    now: context.date, position: model.currentSeconds, duration: model.duration,
                    speed: model.playbackSpeed, locale: locale, timeZone: timeZone
                ))
            }
        } else {
            content(nil)
        }
    }
}

struct PlayerClockSchedule: TimelineSchedule {
    let paused: Bool
    /// Tick on each minute boundary instead of every second — enough for a
    /// label that only shows hours and minutes ("Ends at 21:04").
    var everyMinute = false

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        if paused { return AnySequence([]) }
        if everyMinute {
            return AnySequence(EveryMinuteTimelineSchedule().entries(from: startDate, mode: mode))
        }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode))
    }
}
#endif
