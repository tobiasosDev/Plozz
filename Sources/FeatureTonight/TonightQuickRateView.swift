import CoreModels
import CoreUI
import FeatureTonightCore
import SwiftUI

/// "Sharpen Taste": one watched, unrated film at a time, answered good, okay
/// or bad. The answers stay in Plozz and are never written to Trakt.
struct TonightQuickRateView: View {
    @Bindable var model: TonightModel
    let artwork: TonightArtworkResolver
    let onDone: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var answered = 0
    @FocusState private var focusedChoice: TonightQuickRating?

    var body: some View {
        ZStack(alignment: .leading) {
            palette.backgroundBase.ignoresSafeArea()
            if let film = model.quickQueue.first {
                backdrop(film)
                VStack(alignment: .leading, spacing: 24) {
                    Text("Sharpen Taste")
                        .font(.headline)
                        .foregroundStyle(palette.secondaryText)
                    Text("How was \(Text(verbatim: film.title))?")
                        .font(.system(size: Layout.questionSize, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: facts(film))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                    HStack(spacing: 20) {
                        choice("Bad", .bad, film)
                        choice("Okay", .okay, film)
                        choice("Good", .good, film)
                        Button("Don't Know") { Task { await model.rate(film, nil); answered += 1 } }
                            .buttonStyle(.borderless)
                    }
                    .padding(.top, 12)
                    Text("\(model.quickStats.openCount) watched films without a rating. Answers stay in Plozz and are not sent to Trakt.")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.top, 40)
                    Button("Done", action: onDone)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, Layout.inset)
                .frame(maxWidth: Layout.width, alignment: .leading)
                .id(film.key)
                .onAppear { focusedChoice = .good }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Every watched film has a rating.")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, Layout.inset)
            }
        }
    }

    private func choice(_ title: LocalizedStringKey, _ rating: TonightQuickRating, _ film: TonightFilm) -> some View {
        Button {
            Task { await model.rate(film, rating); answered += 1 }
        } label: {
            Text(title).padding(.horizontal, 12)
        }
        .buttonStyle(.bordered)
        .focused($focusedChoice, equals: rating)
    }

    @ViewBuilder
    private func backdrop(_ film: TonightFilm) -> some View {
        if let location = film.locations.first {
            let urls = [artwork(location, .backdrop, 1920), artwork(location, .primary, 780)].compactMap { $0 }
            FallbackAsyncImage(urls: urls, pinIdentity: "tonight-rate-\(film.key)") { palette.backgroundBase }
                .ignoresSafeArea()
                .overlay(palette.backgroundBase.opacity(0.7))
                .ignoresSafeArea()
        }
    }

    private func facts(_ film: TonightFilm) -> String {
        var parts: [String] = []
        if let year = film.year { parts.append(String(year)) }
        if let directors = film.directorLine { parts.append(directors) }
        parts.append(String(localized: "Watched \(film.plays) times", comment: "Tonight quick rating: number of viewings"))
        return parts.joined(separator: " · ")
    }

    private enum Layout {
        #if os(tvOS)
        static let questionSize: CGFloat = 64
        static let inset: CGFloat = 80
        static let width: CGFloat = 1200
        #else
        static let questionSize: CGFloat = 30
        static let inset: CGFloat = 20
        static let width: CGFloat = 600
        #endif
    }
}
