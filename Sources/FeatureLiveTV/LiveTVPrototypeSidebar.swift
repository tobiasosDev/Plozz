import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypeBrowseSidebar: View {
    @Bindable var model: LiveTVPrototypeModel
    @Binding var active: Bool
    let focusRequest: Int
    var isSearching = false
    var categoryFocusRequest = 0
    var restoresCategoryFocus = false
    let search: () -> Void
    let enterGuide: () -> Void
    var selectCategory: ((String?) -> Void)?
    var multiviews: (() -> Void)?
    var manageChannels: (() -> Void)?
    @FocusState private var focused: Control?
    @State private var categoryFade = PrototypeScrollFade()
    @State private var completedCategoryFocusRequest = 0
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    @Environment(\.layoutDirection) private var layoutDirection

    private enum Control: Hashable {
        case search
        case multiviews
        case manageChannels
        case category(String?)
    }

    private var isEnteringCategory: Bool {
        restoresCategoryFocus && categoryFocusRequest > completedCategoryFocusRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            Button(action: search) {
                Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                    #if os(tvOS)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .padding(.horizontal, PrototypeLayout.gap)
                    #else
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            #else
            .buttonStyle(.bordered)
            #endif
            .focused($focused, equals: .search)
            .disabled(isEnteringCategory)
            .accessibilityValue(model.query)
            .accessibilityIdentifier("live-tv-search")
            #if DEBUG
            .modifier(PrototypeBrowseLayoutObservation(element: "sidebar-search"))
            #endif
            if let multiviews {
                Button(action: multiviews) {
                    Label("Multiviews", systemImage: "rectangle.split.2x2")
                        #if os(iOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                }
                    #if os(tvOS)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    #else
                    .buttonStyle(.bordered)
                    #endif
                    .focused($focused, equals: .multiviews)
                    .disabled(isEnteringCategory)
                    .accessibilityIdentifier("live-tv-multiview-favorites")
            }
            if let manageChannels {
                Button(action: manageChannels) {
                    Label("Manage channels", systemImage: "slider.horizontal.3")
                        #if os(iOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                }
                    #if os(tvOS)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    #else
                    .buttonStyle(.bordered)
                    #endif
                    .focused($focused, equals: .manageChannels)
                    .disabled(isEnteringCategory)
                    .accessibilityIdentifier("live-tv-manage-channels")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: PrototypeLayout.smallGap) {
                        ForEach([nil] + model.browsingCategories.map { Optional($0.name) }, id: \.self) { category in
                            Button {
                                if let selectCategory { selectCategory(category) }
                                else { model.category = category }
                            } label: {
                                HStack(spacing: PrototypeLayout.smallGap) {
                                    if let category { Text(category) } else { Text("All categories") }
                                    Spacer(minLength: 0)
                                    Text(model.categoryChannelCount(category), format: .number)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .opacity(model.category == category ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .lineLimit(2)
                                #if os(tvOS)
                                .frame(
                                    maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading
                                )
                                .padding(.horizontal, PrototypeLayout.gap)
                                #else
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #endif
                                .contentShape(Rectangle())
                            }
                            #if os(tvOS)
                            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
                            #else
                            .buttonStyle(.bordered)
                            #endif
                            .focused($focused, equals: .category(category))
                            .disabled(isEnteringCategory && category != model.category)
                            .id(Control.category(category))
                            .accessibilityAddTraits(model.category == category ? .isSelected : [])
                            .accessibilityLabel(category.map { Text(verbatim: $0) } ?? Text("All categories"))
                            .accessibilityValue(Text("\(model.categoryChannelCount(category)) channels"))
                            .accessibilityIdentifier("live-tv-sidebar-category-\(category ?? "all")")
                        }
                    }
                    .padding(.vertical, PrototypeLayout.smallGap)
                }
                .scrollIndicators(.hidden)
                .verticalEdgeFadeMask(
                    fadeHeight: PrototypeLayout.verticalFade,
                    topStrength: categoryFade.leading,
                    bottomStrength: categoryFade.trailing
                )
                .onScrollGeometryChange(for: PrototypeScrollFade.self) { geometry in
                    PrototypeScrollFade(
                        before: geometry.contentOffset.y + geometry.contentInsets.top,
                        after: geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                    )
                } action: { _, fade in
                    categoryFade = fade
                }
                .accessibilityIdentifier("live-tv-category-list")
                .onChange(of: categoryFocusRequest) { _, request in
                    guard request > 0 else { return }
                    proxy.scrollTo(Control.category(model.category), anchor: .center)
                    focused = .category(model.category)
                }
                .onAppear {
                    if restoresCategoryFocus {
                        proxy.scrollTo(Control.category(model.category), anchor: .center)
                        focused = .category(model.category)
                    }
                }
            }
        }
        #if os(tvOS)
        .font(.system(size: fontSize, weight: .regular))
        #endif
        .lineLimit(1)
        .focusEffectDisabled()
        #if os(tvOS)
        .focusSection()
        .defaultFocus(
            $focused, restoresCategoryFocus ? .category(model.category) : .search,
            priority: .automatic
        )
        .background {
            NativeFocusRegionObserver(
                isEnabled: restoresCategoryFocus,
                onFocusExited: { completedCategoryFocusRequest = 0 },
                onFocusEntered: {}
            )
        }
        .onMoveCommand { direction in
            guard focused != nil else { return }
            if direction == (layoutDirection == .rightToLeft ? .left : .right) {
                enterGuide()
            }
        }
        #endif
        .onChange(of: focused) { _, target in
            if target != nil { active = true }
            if target == .category(model.category) {
                completedCategoryFocusRequest = categoryFocusRequest
            }
        }
        .onChange(of: focusRequest, initial: true) { _, request in
            guard request > 0, active, !restoresCategoryFocus else { return }
            completedCategoryFocusRequest = categoryFocusRequest
            focused = .search
        }
    }
}

/// What one of the guide's chips narrows it to.
enum PrototypeGuideScope: Hashable {
    case all, favorites, recent
    case category(String)
}

extension LiveTVPrototypeModel {
    /// Picks one chip: the chips are a single choice, so each clears the others.
    func showScope(_ scope: PrototypeGuideScope) {
        favoritesOnly = scope == .favorites
        recentOnly = scope == .recent
        if case .category(let name) = scope { category = name } else { category = nil }
    }

    func isShowing(_ scope: PrototypeGuideScope) -> Bool {
        switch scope {
        case .all: category == nil && !favoritesOnly && !recentOnly
        case .favorites: favoritesOnly
        case .recent: recentOnly
        case .category(let name): category == name
        }
    }

    /// The chip focus returns to: the narrowest choice in effect.
    var currentScope: PrototypeGuideScope {
        if let category { return .category(category) }
        if recentOnly { return .recent }
        return favoritesOnly ? .favorites : .all
    }
}

#if os(tvOS)
/// Focus within the chip row. The page owns it, so its automatic focus can
/// prefer the chosen chip over the header above it.
enum PrototypeChipFocus: Hashable {
    case search
    case scope(PrototypeGuideScope)
}

/// The guide's categories as the Apple TV app's chip row, led by Search.
/// A chip narrows the guide at once and keeps focus here; Down returns to the
/// guide where it was, Up reaches the programme header, and Left from the
/// guide's channels comes back here.
struct PrototypeCategoryChips: View {
    @Bindable var model: LiveTVPrototypeModel
    @Binding var active: Bool
    let focusRequest: Int
    var categoryFocusRequest = 0
    let search: () -> Void
    let select: (PrototypeGuideScope) -> Void
    let focus: FocusState<PrototypeChipFocus?>.Binding
    /// Focus is coming back from outside Live TV: only the chosen chip takes it.
    var onlyChosen = false

    private var scopes: [PrototypeGuideScope] {
        var scopes: [PrototypeGuideScope] = [.all, .favorites]
        // Offered once something was watched, unless the Recently watched row is off.
        if (model.showsRecentChannels && !model.recentChannelIDs.isEmpty) || model.recentOnly {
            scopes.append(.recent)
        }
        return scopes + model.browsingCategories.map { .category($0.name) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    Button(action: search) {
                        Label("Search", systemImage: "magnifyingglass")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: PrototypeLayout.chipHeight, height: PrototypeLayout.chipHeight)
                    }
                    .buttonStyle(PrototypeHeaderButtonStyle(shape: .circle))
                    .focused(focus, equals: .search)
                    .disabled(onlyChosen)
                    .accessibilityValue(model.query)
                    .accessibilityIdentifier("live-tv-search")
                    #if DEBUG
                    .modifier(PrototypeBrowseLayoutObservation(element: "sidebar-search"))
                    #endif
                    ForEach(scopes, id: \.self) { scope in
                        chip(scope)
                            .id(PrototypeChipFocus.scope(scope))
                    }
                }
                // On the guide's channel column.
                .padding(.leading, PrototypeLayout.guideInset)
            }
            // Like a tvOS shelf: chips scroll to the screen edge, and the focused
            // one lifts past the row instead of being cut off.
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .frame(height: PrototypeLayout.chipHeight)
            .accessibilityIdentifier("live-tv-category-list")
            .onChange(of: categoryFocusRequest) { _, request in
                guard request > 0 else { return }
                proxy.scrollTo(PrototypeChipFocus.scope(model.currentScope), anchor: .center)
                focus.wrappedValue = .scope(model.currentScope)
            }
        }
        .focusSection()
        .onChange(of: focus.wrappedValue) { _, target in
            if target != nil { active = true }
        }
        .onChange(of: focusRequest) { _, request in
            guard request > 0 else { return }
            focus.wrappedValue = .search
        }
    }

    private func chip(_ scope: PrototypeGuideScope) -> some View {
        let selected = model.isShowing(scope)
        return Button { select(scope) } label: {
            HStack(spacing: 10) {
                if scope == .favorites {
                    Image(systemName: "star.fill").font(.system(size: 20, weight: .semibold))
                }
                title(scope)
            }
            .font(.system(size: 23, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(height: PrototypeLayout.chipHeight)
        }
        .buttonStyle(PrototypeHeaderButtonStyle(shape: .chip, selected: selected))
        .focused(focus, equals: .scope(scope))
        .disabled(onlyChosen && scope != model.currentScope)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier(scope))
    }

    @ViewBuilder private func title(_ scope: PrototypeGuideScope) -> some View {
        switch scope {
        case .all: Text("All channels")
        case .favorites: Text("Favorites")
        case .recent: Text("Recently watched")
        case .category(let name): Text(verbatim: name)
        }
    }

    private func identifier(_ scope: PrototypeGuideScope) -> String {
        switch scope {
        case .all: "live-tv-sidebar-category-all"
        case .favorites: "live-tv-scope-favorites"
        case .recent: "live-tv-scope-recent"
        case .category(let name): "live-tv-sidebar-category-\(name)"
        }
    }
}
#endif
