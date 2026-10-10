import SwiftUI

/// A custom separator between two items in an ``HFlow`` or ``VFlow``.
///
/// Replaces the automatic item separator between the adjacent items, if any.
/// The separator appears only between visible items on the same line.
/// Its size affects wrapping, with item spacing on both sides.
/// An `EmptyView` omits the separator and keeps ordinary item spacing.
///
/// Consecutive `ItemSeparator` views use the last separator.
/// `ItemSeparator` does not count toward hidden items or change line separators.
public struct ItemSeparator<Content: View>: View {
    private let content: Content

    /// Creates a custom separator.
    ///
    /// - Parameter content: The separator content. Multiple views overlap.
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// The separator view.
    public var body: some View {
        // Empty overrides need a subview to carry their separator role.
        Group {
            if Content.self == EmptyView.self {
                Color.clear.frame(width: 0, height: 0)
            } else {
                ZStack { content }
            }
        }
        // Variadic enumeration reads the trait; the layout reads the layout value.
        ._trait(SeparatorRoleLayoutValueKey.self, .itemSeparatorOverride(isEmpty: Content.self == EmptyView.self))
        .layoutValue(key: SeparatorRoleLayoutValueKey.self, value: .itemSeparatorOverride(isEmpty: Content.self == EmptyView.self))
    }
}
