import CoreModels
import CoreUI
import FeatureTonightCore
import SwiftUI

/// Resolves server artwork for a film location. Supplied by the app shell,
/// which owns the providers.
public typealias TonightArtworkResolver = @MainActor (TonightLocation, ImageKind, Int) -> URL?

/// "Tonight": personal suggestions with the request on top as Plozz pills, the
/// selected pick as a hero, and the other picks as a row below.
public struct TonightView: View {
    @Bindable private var model: TonightModel
    private let artwork: TonightArtworkResolver
    private let onPlay: (MediaItem) -> Void
    private let onOpenDetail: (MediaItem) -> Void
    private let isActive: Bool

    @Environment(\.themePalette) private var palette
    @State private var editingMood = false
    @State private var moodDraft = ""
    @State private var showsQuickRate = false
    @State private var confirmsReset = false
    @State private var unavailable = false
    @FocusState private var focusedPick: String?

    public init(
        model: TonightModel,
        artwork: @escaping TonightArtworkResolver,
        onPlay: @escaping (MediaItem) -> Void,
        onOpenDetail: @escaping (MediaItem) -> Void,
        isActive: Bool = true
    ) {
        self.isActive = isActive
        self.model = model
        self.artwork = artwork
        self.onPlay = onPlay
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            content
        }
        .background(palette.backgroundBase)
        // Native navigation keeps hidden destinations alive. Nothing is read or
        // computed until Tonight is actually on screen.
        .task(id: TaskKey(model: ObjectIdentifier(model), isActive: isActive)) {
            if isActive { await model.start() }
        }
        .onChange(of: focusedPick) { _, key in
            if let key, let index = model.picks.firstIndex(where: { $0.id == key }) { model.select(index) }
        }
        .alert("Mood", isPresented: $editingMood) {
            TextField("A rainy Sunday, something light…", text: $moodDraft)
            Button("Apply") { Task { await model.setMood(moodDraft) } }
            Button("Clear", role: .destructive) { moodDraft = ""; Task { await model.setMood(nil) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Describe tonight in your own words. Titles, themes and synopses are matched.")
        }
        .alert("This film isn't on a connected server.", isPresented: $unavailable) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Forget all decisions?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Forget Decisions", role: .destructive) { Task { await model.resetDecisions() } }
        } message: {
            Text("Never, Not Now and quick ratings for this profile are removed. Your watchlist and history stay as they are.")
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showsQuickRate) {
            TonightQuickRateView(model: model, artwork: artwork) { showsQuickRate = false }
        }
        #else
        .sheet(isPresented: $showsQuickRate) {
            TonightQuickRateView(model: model, artwork: artwork) { showsQuickRate = false }
        }
        #endif
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if let pick = model.selectedPick, let location = pick.film.locations.first {
            let urls = [artwork(location, .backdrop, 1920), artwork(location, .primary, 780)].compactMap { $0 }
            FallbackAsyncImage(urls: urls, pinIdentity: "tonight-\(pick.id)") {
                palette.backgroundBase
            }
            .id(pick.id)
            .transition(.opacity)
            .ignoresSafeArea()
            .overlay {
                LinearGradient(
                    colors: [palette.backgroundBase.opacity(0.95), palette.backgroundBase.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    colors: [palette.backgroundBase, palette.backgroundBase.opacity(0.7), .clear],
                    startPoint: .bottom, endPoint: .center
                )
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: pick.id)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            requestPills
            if model.isCurating {
                Label {
                    Text("Claude is choosing…")
                } icon: {
                    ProgressView()
                }
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            switch model.phase {
            case .idle, .loadingLibrary:
                statusMessage(
                    String(localized: "Reading your film library…", comment: "Tonight: first library scan in progress"),
                    showsProgress: true
                )
            case .empty:
                statusMessage(String(localized: "No movies to choose from. Connect a server with a movie library or sign in to Trakt.", comment: "Tonight: empty state"), showsProgress: false)
            case .choosing, .ready:
                if let pick = model.selectedPick {
                    hero(pick)
                    if model.picks.count > 1 { picksRow }
                } else {
                    statusMessage(model.result?.note.map(TonightCopy.note)
                        ?? String(localized: "Nothing left to suggest. Change the request or show more.", comment: "Tonight: all picks decided"),
                        showsProgress: model.phase == .choosing)
                    if model.lastDecision != nil {
                        Button { Task { await model.undoLastDecision() } } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.horizontalInset)
        .padding(.vertical, Layout.verticalInset)
    }

    private func statusMessage(_ text: String, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.medium) {
            if showsProgress { ProgressView() }
            Text(verbatim: text)
                .font(.title3)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: Layout.textWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Layout.verticalInset)
    }

    // MARK: - Request

    private var requestPills: some View {
        BrowseQueryControls {
            Menu {
                ForEach(TonightMode.allCases, id: \.self) { mode in
                    Button { Task { await model.setMode(mode) } } label: {
                        checkLabel(TonightCopy.mode(mode), selected: model.request.mode == mode)
                    }
                }
            } label: {
                pillLabel(TonightCopy.mode(model.request.mode))
            }
            Menu {
                Button { Task { await model.setGenre(nil) } } label: {
                    checkLabel(String(localized: "Any Genre", comment: "Tonight: genre filter, none"), selected: model.request.genre == nil)
                }
                ForEach(TonightGenre.allCases.sorted { TonightCopy.genre($0) < TonightCopy.genre($1) }, id: \.self) { genre in
                    Button { Task { await model.setGenre(genre) } } label: {
                        checkLabel(TonightCopy.genre(genre), selected: model.request.genre == genre)
                    }
                }
            } label: {
                pillLabel(model.request.genre.map(TonightCopy.genre) ?? String(localized: "Any Genre", comment: "Tonight: genre filter, none"))
            }
            Menu {
                Button { Task { await model.setReference(nil) } } label: {
                    checkLabel(String(localized: "No Reference", comment: "Tonight: no reference film"), selected: model.request.like == nil)
                }
                ForEach(model.references) { film in
                    Button { Task { await model.setReference(film) } } label: {
                        checkLabel(film.title, selected: model.request.like?.key == film.key)
                    }
                }
            } label: {
                pillLabel(model.request.like.map { String(localized: "Like \($0.title)", comment: "Tonight: reference film pill, e.g. 'Like Heat'") }
                    ?? String(localized: "No Reference", comment: "Tonight: no reference film"))
            }
            Menu {
                ForEach([nil, 100, 120] as [Int?], id: \.self) { minutes in
                    Button { Task { await model.setMaxRuntime(minutes) } } label: {
                        checkLabel(TonightCopy.runtime(minutes), selected: model.request.maxRuntime == minutes)
                    }
                }
            } label: {
                pillLabel(TonightCopy.runtime(model.request.maxRuntime))
            }
            Button {
                moodDraft = model.request.mood ?? ""
                editingMood = true
            } label: {
                Label {
                    Text(verbatim: model.request.mood ?? String(localized: "Mood", comment: "Tonight: free-text mood pill"))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "text.bubble")
                }
            }
            Menu {
                Button { Task { await model.setOnlyOnServers(!model.request.onlyOnServers) } } label: {
                    checkLabel(String(localized: "Only on My Servers", comment: "Tonight: filter to playable films"), selected: model.request.onlyOnServers)
                }
                Button { Task { await model.showMore() } } label: {
                    Label("Show More", systemImage: "arrow.right.circle")
                }
                Button { showsQuickRate = true } label: {
                    Label(String(localized: "Sharpen Taste (\(model.quickStats.openCount))", comment: "Tonight: opens the quick rating round; number of unrated watched films"),
                          systemImage: "hand.thumbsup")
                }
                Button { Task { await model.refreshLibrary() } } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingLibrary)
                Button(role: .destructive) { confirmsReset = true } label: {
                    Label("Forget Decisions…", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Label {
            Text(verbatim: text).lineLimit(1)
        } icon: {
            Image(systemName: "chevron.up.chevron.down")
        }
    }

    @ViewBuilder
    private func checkLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark") }
        } else {
            Text(verbatim: text)
        }
    }

    // MARK: - Hero

    private func hero(_ pick: TonightPick) -> some View {
        HStack(alignment: .bottom, spacing: PlozzTheme.Spacing.xxLarge) {
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.medium) {
                Text(verbatim: pick.film.title)
                    .font(.system(size: Layout.titleSize, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(palette.primaryText)
                factsLine(pick.film)
                Text(verbatim: TonightCopy.reason(pick.reason))
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: Layout.textWidth, alignment: .leading)
                actions(pick)
                    .padding(.top, PlozzTheme.Spacing.small)
            }
            Spacer(minLength: 0)
            if !pick.evidence.isEmpty {
                evidence(pick)
            }
        }
    }

    private func factsLine(_ film: TonightFilm) -> some View {
        let parts: [String] = [
            film.year.map(String.init),
            film.genres.prefix(2).map(TonightCopy.genre).joined(separator: " · ").nilIfEmpty,
            film.runtimeMinutes.map { Duration.seconds($0 * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) },
        ].compactMap { $0 }
        return HStack(spacing: PlozzTheme.Spacing.small) {
            if let rating = film.officialRating, !rating.isEmpty {
                Text(verbatim: rating)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.primaryText.opacity(0.8), lineWidth: 2))
            }
            Text(verbatim: parts.joined(separator: " · "))
            if !film.isOnServer {
                Text("Not on Your Servers")
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(palette.primaryText)
    }

    private func actions(_ pick: TonightPick) -> some View {
        HStack(spacing: PlozzTheme.Spacing.medium) {
            Button {
                Task { await play(pick) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .padding(.horizontal, PlozzTheme.Spacing.small)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!pick.film.isOnServer)

            iconButton("Save", systemImage: model.decided(.save, pick) ? "bookmark.fill" : "bookmark") {
                Task { await model.decide(.save, on: pick) }
            }
            iconButton("Not Now", systemImage: "clock") { Task { await model.decide(.later, on: pick) } }
            iconButton("Never", systemImage: "nosign") { Task { await model.decide(.never, on: pick) } }
            iconButton("Already Seen", systemImage: "eye") { Task { await model.decide(.seen, on: pick) } }
            iconButton("Details", systemImage: "info.circle") {
                Task {
                    if let item = await model.playableItem(for: pick) { onOpenDetail(item) } else { unavailable = true }
                }
            }
            .disabled(!pick.film.isOnServer)
            if model.lastDecision != nil {
                iconButton("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undoLastDecision() } }
            }
        }
    }

    private func iconButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonBorderShape(.circle)
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(title))
    }

    private func play(_ pick: TonightPick) async {
        guard let item = await model.playableItem(for: pick) else {
            unavailable = true
            return
        }
        onPlay(item)
    }

    private func evidence(_ pick: TonightPick) -> some View {
        let titles = pick.evidence.map(\.title).formatted(.list(type: .and))
        return (Text("Based on") .foregroundStyle(palette.secondaryText) + Text(verbatim: " \(titles)"))
            .font(.callout.weight(.semibold))
            .foregroundStyle(palette.primaryText)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: Layout.evidenceWidth, alignment: .leading)
    }

    // MARK: - Picks row

    private var picksRow: some View {
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
            Text("Also Possible")
                .font(.headline)
                .foregroundStyle(palette.primaryText)
            ScrollView(.horizontal) {
                LazyHStack(spacing: PlozzTheme.Spacing.large) {
                    ForEach(model.picks) { pick in
                        Button {
                            if let index = model.picks.firstIndex(where: { $0.id == pick.id }) { model.select(index) }
                        } label: {
                            poster(pick.film)
                        }
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .focused($focusedPick, equals: pick.id)
                        .accessibilityLabel(Text(verbatim: pick.film.title))
                    }
                }
                .padding(.vertical, PlozzTheme.Spacing.medium)
            }
            // A horizontal scroll view is vertically flexible; without a fixed
            // height it takes the space meant to push the hero to the bottom.
            .frame(height: Layout.posterWidth * 1.5 + PlozzTheme.Spacing.medium * 2)
            .scrollClipDisabled()
        }
    }

    private func poster(_ film: TonightFilm) -> some View {
        let url = film.locations.first.flatMap { artwork($0, .primary, 500) }
        return FallbackAsyncImage(urls: [url].compactMap { $0 }, pinIdentity: "tonight-poster-\(film.key)") {
            ZStack(alignment: .bottomLeading) {
                palette.surface(.raised).fill
                Text(verbatim: film.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .padding(PlozzTheme.Spacing.small)
            }
        }
        .frame(width: Layout.posterWidth, height: Layout.posterWidth * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private enum Layout {
        #if os(tvOS)
        static let horizontalInset: CGFloat = 80
        static let verticalInset: CGFloat = 40
        static let sectionSpacing: CGFloat = 28
        static let titleSize: CGFloat = 76
        static let textWidth: CGFloat = 1000
        static let evidenceWidth: CGFloat = 440
        static let posterWidth: CGFloat = 180
        #else
        static let horizontalInset: CGFloat = 20
        static let verticalInset: CGFloat = 16
        static let sectionSpacing: CGFloat = 16
        static let titleSize: CGFloat = 36
        static let textWidth: CGFloat = 600
        static let evidenceWidth: CGFloat = 220
        static let posterWidth: CGFloat = 96
        #endif
    }
}

private struct TaskKey: Hashable {
    let model: ObjectIdentifier
    let isActive: Bool
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension TonightModel {
    /// Whether the viewer already chose `action` for this pick and can see it.
    func decided(_ action: TonightAction, _ pick: TonightPick) -> Bool {
        lastDecision?.action == action && lastDecision?.film.key == pick.film.key
    }
}
