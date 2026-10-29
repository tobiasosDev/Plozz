#if canImport(SwiftUI)
import SwiftUI

/// Gives the description the facts row's natural width without a measurement/state feedback loop.
public struct HeroDescriptionFactsLayout: Layout {
    public static let minimumWidth: CGFloat = 800
    public static let maximumWidth: CGFloat = 1200
    private let spacing: CGFloat
    private let factsFirst: Bool

    /// - Parameter factsFirst: stack the facts row above the description, the
    ///   Apple TV app's order on detail pages. The column width still follows the
    ///   facts row either way; only the vertical order changes.
    public init(spacing: CGFloat = 12, factsFirst: Bool = false) {
        self.spacing = spacing
        self.factsFirst = factsFirst
    }

    func columnWidth(factsWidth: CGFloat, availableWidth: CGFloat?) -> CGFloat {
        min(
            max(1, availableWidth ?? Self.maximumWidth),
            Self.maximumWidth,
            max(Self.minimumWidth, factsWidth)
        )
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        precondition(subviews.count == 2)
        let width = columnWidth(
            factsWidth: subviews[1].sizeThatFits(.unspecified).width,
            availableWidth: proposal.width
        )
        let column = ProposedViewSize(width: width, height: nil)
        return CGSize(
            width: width,
            height: subviews[0].sizeThatFits(column).height + spacing + subviews[1].sizeThatFits(column).height
        )
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        precondition(subviews.count == 2)
        let column = ProposedViewSize(width: bounds.width, height: nil)
        guard factsFirst else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: column)
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(column).height + spacing),
                anchor: .topLeading, proposal: column
            )
            return
        }
        // Facts lead. An empty facts row keeps its gap below the description
        // instead, so the description doesn't drop and the overall height — and
        // with it the action row — stays where it was.
        let factsHeight = subviews[1].sizeThatFits(column).height
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: column)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + factsHeight + (factsHeight > 0 ? spacing : 0)),
            anchor: .topLeading, proposal: column
        )
    }
}
#endif
