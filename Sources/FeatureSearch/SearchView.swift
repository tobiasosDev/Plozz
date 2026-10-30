#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Search screen: a `.searchable` field with title completions over one
/// horizontal poster row per kind of result (Movies / TV Shows / Episodes), as
/// the TV app lays out its results, with the standard loading, empty and error
/// states.
public struct SearchView: View {
    @State private var viewModel: SearchViewModel
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMediaSourceIdentities) private var sourceIdentities
    @Environment(\.plozzPinnedSidebarInteraction) private var pinnedSidebarInteraction
    @FocusState private var focusedResultID: String?

    public init(
        viewModel: SearchViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }


    public var body: some View {
        content
            .environment(\.plozzCardCaptionView, .search)
            // Results mix servers, so each caption names the one it plays from.
            .environment(\.plozzCardCaptionSourceNames, sourceIdentities)
            .environment(\.plozzCardCaptionLeading, true)
            .searchable(text: $viewModel.query, prompt: "Search movies, shows, and episodes")
            // tvOS draws these as the TV app's chip row under the keyboard.
            .searchSuggestions {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Text(verbatim: suggestion).searchCompletion(suggestion)
                }
            }
            .task(id: viewModel.query) { await viewModel.search() }
            .onChange(of: focusedResultID, initial: true) { _, resultID in
                pinnedSidebarInteraction?.setSearchResultsFocused(resultID != nil)
            }
            .onDisappear {
                pinnedSidebarInteraction?.setSearchResultsFocused(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
                if let mutation = MediaItemMutation.from(note) {
                    viewModel.applyWatchedState(mutation)
                } else {
                    Task { await viewModel.search() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            // Before the first search there's nothing to show — keep it clean.
            Color.clear
        case .empty:
            PlozzEmptyStateView("No results. Try a different search.")
        default:
            ContentStateView(
                state: viewModel.state,
                emptyMessage: "No results. Try a different search.",
                onRetry: { Task { await viewModel.search() } }
            ) { sections in
                results(sections)
            }
        }
    }

    private func results(_ sections: [SearchSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                        Text(section.title)
                            .font(.system(size: metrics.sectionHeaderFontSize, weight: .semibold))
                            .padding(.leading, PlozzTheme.Metrics.screenPadding)
                        resultRow(section)
                    }
                }
            }
            .padding(.vertical, PlozzTheme.Metrics.screenVerticalPadding)
        }
        // Never clip a focused card's lift, shadow or border.
        .scrollClipDisabled()
        .scrollsTopNavigation()
    }

    /// One horizontal row of a section's results. Each card is as wide as a
    /// column of the shared poster wall, so Search and Library posters match
    /// and scale together with the density setting.
    private func resultRow(_ section: SearchSection) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: metrics.gridSpacing) {
                ForEach(section.items) { item in
                    PosterCardView(
                        item: item,
                        style: .poster,
                        spoilerSettings: spoilerSettings,
                        statusCue: SearchSection.availabilityCue(for: item)
                    ) {
                        onSelect(item)
                    }
                    .containerRelativeFrame(
                        .horizontal, count: metrics.posterGridColumns, spacing: metrics.gridSpacing
                    )
                    .focused($focusedResultID, equals: item.stablePresentationID)
                }
            }
            // Line the visible artwork up with the section title, not the
            // card's transparent focus margin.
            .padding(.leading, metrics.cardRowLeadingPadding(PlozzTheme.Metrics.screenPadding, cardStyle: cardStyle))
            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
            // Give focus room so the lifted card isn't clipped.
            .padding(.vertical, metrics.sectionTitleSpacing)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
    }
}

#endif
