import SwiftUI

// MARK: - Feature composition

/// (Internal.) Composes flow content with feature-generated subviews that must be siblings in one layout pass.
/// Created by `HFlow.body` / `VFlow.body` when separator injection is configured.
///
/// Injected item separators are identified by their position; line separators are anchored to
/// the *visual* line boundary they fill (reported back by the layout), so a divider stays the same view
/// as content rewraps through it instead of jumping. Enumeration uses `Group(subviews:)` where available
/// and falls back to `_VariadicView` on earlier systems. If line capping also supplies an overflow
/// indicator, it is appended here so the layout can measure and place all generated children together.
@usableFromInline
struct _FlowFeatureComposition<Content: View>: View {  // swiftlint:disable:this type_name
    @usableFromInline
    let makeLayout: (Int?) -> AnyLayout
    @usableFromInline
    let content: Content

    @Environment(\.flexibility) private var flexibility
    @Environment(\.maxLines) private var maxLines
    @Environment(\._flowItemSeparator) private var itemSeparator
    @Environment(\._flowLineSeparator) private var lineSeparator
    @Environment(\._flowOverflowBuilder) private var overflowBuilder
    @StateObject private var lineStructure = Reported<[Int]>([])
    @StateObject private var overflowCount = Reported(0)

    @usableFromInline
    init(makeLayout: @escaping (Int?) -> AnyLayout, content: Content) {
        self.makeLayout = makeLayout
        self.content = content
    }

    @usableFromInline
    var body: some View {
        let layout = makeLayout(maxLines)
        // Line separators need to know the line structure; item separators do not, so only pay for the
        // reporter when line separators are configured.
        let reporter: (@Sendable ([Int]) -> Void)? = lineSeparator == nil ? nil : lineStructure.reporter()
        return layout {
            interleaved()
                // Attach after enumeration because legacy proxies drop source layout metadata.
                .layoutValue(key: LineStructureReporterKey.self, value: reporter)
            if let overflowBuilder {
                overflowBuilder(overflowCount.value)
                    .overflowIndicator(reporter: overflowCount.reporter())
            }
        }
    }

    @ViewBuilder
    private func interleaved() -> some View {
        // Capture env values into locals so they're stable for the view-update scope and can be
        // referenced safely inside @ViewBuilder and Group(subviews:) closures.
        let itemSep = itemSeparator
        let lineSep = lineSeparator
        let tagged =
            content
            .layoutValue(key: FlexibilityLayoutValueKey.self, value: flexibility)
            .environment(\.maxLines, nil)
            .environment(\._flowItemSeparator, nil)
            .environment(\._flowLineSeparator, nil)
            .environment(\._flowOverflowBuilder, nil)
        if itemSep != nil || lineSep != nil {
            // `Group(subviews:)` ships in the Xcode 16 SDK (Swift 6+); earlier toolchains fall back to the
            // `_VariadicView` SPI, which behaves the same back to the minimum deployment targets.
            #if swift(>=6.0)
                if #available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *) {
                    Group(subviews: tagged) { subviews in
                        interleavedContent(
                            subviews,
                            itemSeparator: itemSep,
                            lineSeparator: lineSep,
                            lineOf: lineStructure.value
                        )
                    }
                } else {
                    variadicInterleaved(tagged, itemSeparator: itemSep, lineSeparator: lineSep)
                }
            #else
                variadicInterleaved(tagged, itemSeparator: itemSep, lineSeparator: lineSep)
            #endif
        } else {
            tagged
        }
    }

    private func variadicInterleaved(
        _ tagged: some View,
        itemSeparator: (() -> AnyView)?,
        lineSeparator: (() -> AnyView)?
    ) -> some View {
        _VariadicView.Tree(
            SeparatorInterleaver(itemSeparator: itemSeparator, lineSeparator: lineSeparator, lineOf: lineStructure.value)
        ) {
            tagged
        }
    }
}

// MARK: - Separator injection

/// Emits caller subviews with configured separators between them, using either enumeration path.
/// `lineOf` includes `ItemSeparator` entries so line separators retain their visual boundary identity.
@ViewBuilder
private func interleavedContent<Elements: RandomAccessCollection>(
    _ elements: Elements,
    itemSeparator: (() -> AnyView)?,
    lineSeparator: (() -> AnyView)?,
    lineOf: [Int],
    separatorRole: ((Elements.Element) -> SeparatorRole)? = nil
) -> some View where Elements.Element: View & Identifiable {
    let last = elements.count - 1
    let positionsInLine = linePositions(for: lineOf)
    ForEach(Array(elements.enumerated()), id: \.element.id) { item in
        if let separatorRole {
            // Variadic proxies lose layout metadata; restore the role carried by the original view's trait.
            item.element.layoutValue(key: SeparatorRoleLayoutValueKey.self, value: separatorRole(item.element))
        } else {
            item.element
        }
        if item.offset < last {
            separators(
                afterIndex: item.offset,
                itemSeparator: itemSeparator,
                lineSeparator: lineSeparator,
                lineOf: lineOf,
                positionsInLine: positionsInLine
            )
        }
    }
}

/// Emits automatic separators after caller subview `index`.
/// `SeparatorPlan` selects which separators to use between content items.
@ViewBuilder
private func separators(
    afterIndex index: Int,
    itemSeparator: (() -> AnyView)?,
    lineSeparator: (() -> AnyView)?,
    lineOf: [Int],
    positionsInLine: [Int]
) -> some View {
    if let itemSeparator {
        // An item separator is injected into every caller subview gap. The plan reserves its breadth
        // only when no directive overrides it. Identity is the (line, positionInLine) of the subview
        // before the gap — positional, so it survives rewraps. Disabling animation makes it snap to its
        // place (or out of view) instead of sliding to/from the off-screen park position, while it still
        // tracks its row frame-to-frame during a live resize.
        itemSeparator()
            .id(itemSeparatorIdentity(afterPosition: index, lineOf: lineOf, positionsInLine: positionsInLine))
            .layoutValue(key: SeparatorRoleLayoutValueKey.self, value: .itemSeparator)
    }
    if let lineSeparator {
        lineSeparator()
            .id(lineSeparatorIdentity(afterPosition: index, lineOf: lineOf))
            .layoutValue(key: SeparatorRoleLayoutValueKey.self, value: .lineSeparator)
    }
}

/// Whether adjacent caller subviews belong to different visible lines.
/// `ItemSeparator` entries use the preceding content line. Negative line indices indicate hidden entries.
private func isLineBoundary(after index: Int, lineOf: [Int]) -> Bool {
    guard lineOf.indices.contains(index + 1) else { return false }
    let current = lineOf[index]
    let next = lineOf[index + 1]
    return current >= 0 && next >= 0 && current != next
}

/// Pre-computes the position-within-line for every item in O(n), so identity lookups are O(1).
/// Items with a negative line (hidden sentinel) get position 0 — they're parked anyway.
private func linePositions(for lineOf: [Int]) -> [Int] {
    var result = [Int](repeating: 0, count: lineOf.count)
    var countPerLine = [Int: Int]()
    for i in lineOf.indices {
        let line = lineOf[i]
        result[i] = countPerLine[line, default: 0]
        countPerLine[line, default: 0] += 1
    }
    return result
}

/// Identity of the item separator after caller subview `index`.
/// Uses (line, positionInLine) derived from the reported line structure so the separator's SwiftUI
/// identity matches its visual slot — not the element it follows — and survives rewraps stably.
/// Falls back to (0, index) on the bootstrap frame before the layout has reported anything.
private func itemSeparatorIdentity(afterPosition index: Int, lineOf: [Int], positionsInLine: [Int]) -> ItemSeparatorIdentity {
    if lineOf.indices.contains(index), lineOf[index] >= 0 {
        return ItemSeparatorIdentity(line: lineOf[index], positionInLine: positionsInLine[index])
    }
    return ItemSeparatorIdentity(line: 0, positionInLine: index)
}

/// Identity of the line separator after caller subview `index`.
/// Visible line separators use their visual boundary once line structure is known; hidden/bootstrap
/// placeholders use the gap position so every gap contributes a distinct separator subview.
private func lineSeparatorIdentity(afterPosition index: Int, lineOf: [Int]) -> LineSeparatorIdentity {
    if isLineBoundary(after: index, lineOf: lineOf) {
        return LineSeparatorIdentity(boundary: lineOf[index + 1], gap: nil)
    }
    return LineSeparatorIdentity(boundary: nil, gap: index)
}

private struct ItemSeparatorIdentity: Hashable {
    let line: Int
    let positionInLine: Int
}

private struct LineSeparatorIdentity: Hashable {
    let boundary: Int?
    let gap: Int?
}

/// `_VariadicView` fallback used before `Group(subviews:)` is available.
struct SeparatorInterleaver: _VariadicView.MultiViewRoot {
    var itemSeparator: (() -> AnyView)?
    var lineSeparator: (() -> AnyView)?
    var lineOf: [Int]

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        interleavedContent(
            children,
            itemSeparator: itemSeparator,
            lineSeparator: lineSeparator,
            lineOf: lineOf,
            separatorRole: { $0[SeparatorRoleLayoutValueKey.self] }
        )
    }
}
