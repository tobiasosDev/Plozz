import SwiftUI
import CoreModels

public struct BrowseQueryControls<Content: View>: View {
    @Environment(\.themePalette) private var palette
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: PlozzTheme.Spacing.medium) { content }
            .menuStyle(.button)
            .buttonStyle(BrowseQueryPillButtonStyle())
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { content.fixedSize() }
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.subheadline)
        .tint(palette.primaryText)
        #endif
    }
}

#if os(tvOS)
/// The TV app's query pill: a frosted capsule at rest that turns solid white
/// with dark ink under focus. A translucent fill, never a live blur — these
/// pills sit on flat pages, where a blur only samples the page colour back.
public struct BrowseQueryPillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.themePalette) private var palette
        @Environment(\.plozzReduceTransparency) private var reduceTransparency

        var body: some View {
            let capsule = Capsule(style: .continuous)
            configuration.label
                .font(.body.weight(.semibold))
                .labelStyle(BrowseQueryPillLabelStyle())
                .foregroundStyle(isFocused
                    ? (colorScheme == .dark ? palette.backgroundBase : .white)
                    : palette.primaryText)
                .padding(.horizontal, 24)
                .frame(minHeight: 62)
                .background {
                    if isFocused {
                        capsule.fill(colorScheme == .dark ? Color.white : .black)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    } else if reduceTransparency {
                        capsule.fill(palette.raised.fill)
                    } else {
                        capsule.fill(.clear)
                            .plozzFrostedBackground(capsule, raised: true)
                            .plozzFrostedBorder(capsule)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

private struct BrowseQueryPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
        }
    }
}
#endif

public struct BrowseSortMenu: View {
    private let sort: CoreModels.SortDescriptor
    private let fields: [SortField]
    private let onChange: (CoreModels.SortDescriptor) -> Void

    public init(
        sort: CoreModels.SortDescriptor,
        fields: [SortField],
        onChange: @escaping (CoreModels.SortDescriptor) -> Void
    ) {
        self.sort = sort
        self.fields = fields
        self.onChange = onChange
    }

    public var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { sort.field },
                set: { onChange(.init(field: $0, direction: $0.defaultDirection)) }
            )) {
                ForEach(fields, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Order", selection: Binding(
                get: { sort.direction },
                set: { onChange(.init(field: sort.field, direction: $0)) }
            )) {
                ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } label: {
            Label {
                #if os(tvOS)
                // The TV app names the control, dimmed, before the current order.
                HStack(spacing: 10) {
                    Text("Sort", comment: "Dimmed prefix on the TV sort button, before the current sort field.")
                        .fontWeight(.medium)
                        .opacity(0.62)
                    Text(sort.field.displayName)
                }
                #else
                Text(sort.field.displayName)
                #endif
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
        }
        .accessibilityLabel(Text("Sort: \(sort.field.displayName)"))
    }
}

public struct BrowseFilterMenu<Content: View>: View {
    private let activeCount: Int
    private let summary: String
    private let content: Content

    public init(activeCount: Int, summary: String, @ViewBuilder content: () -> Content) {
        self.activeCount = activeCount
        self.summary = summary
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            BrowseFilterLabel(activeCount: activeCount, summary: summary)
        }
    }
}

public struct BrowseFilterLabel: View {
    @Environment(\.locale) private var locale
    private let activeCount: Int
    private let summary: String

    public init(activeCount: Int, summary: String) {
        self.activeCount = activeCount
        self.summary = summary
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            Label {
                #if os(tvOS)
                // The TV app's unfiltered button names the control; a filter
                // still shows what it narrows to.
                if activeCount == 0 {
                    Text("Filter", comment: "TV filter button title while no library filter is active.")
                } else {
                    Text(verbatim: selection)
                }
                #else
                Text(verbatim: selection)
                #endif
            } icon: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .fixedSize()
            if activeCount > 0 {
                Label {
                    Text(activeCount, format: .number)
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .fixedSize()
            }
        }
        .accessibilityLabel(Text("Filter: \(selection)"))
    }

    private var selection: String {
        if activeCount == 0 {
            return String(localized: "All", locale: locale) // l10n:content — resolves the shared unfiltered choice
        }
        return summary
    }
}
