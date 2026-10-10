import CoreFoundation
import SwiftUI

/// The separator feature: draws separators between items and between lines, much as ``LineCap``
/// handles line limits. ``FlowLayout`` calls it at the two pipeline seams:
///
/// * ``foldIntoContent(_:)`` (input seam) reduces the breaker input to content items only, folding
///   each item separator's breadth into the following item's spacing so wrapping accounts for it
///   while the breaker stays separator-agnostic.
/// * ``materialize(in:justified:proposal:)`` (output seam) re-materializes those separators once the
///   lines are known — item separators as ordinary in-line items, line separators as their own
///   single-item lines — so the core line-construction code treats them like any other subview.
///
/// Created only when a subview carries a non-`content` ``SeparatorRole`` (see ``init?(cache:axis:itemSpacing:)``).
struct SeparatorLayout {
    /// An item separator to draw in-line between two items on the same line.
    private struct ItemSeparator {
        var index: Int
        var breadth: CGFloat
        var leadingSpace: CGFloat
    }

    private let plan: SeparatorPlan
    private let axis: Axis
    private let itemSpacing: CGFloat?
    private let cache: FlowLayoutCache

    init?(cache: FlowLayoutCache, axis: Axis, itemSpacing: CGFloat?) {
        guard cache.hasSeparators else { return nil }
        plan = SeparatorPlan(
            roles: cache.subviewsCache.map(\.separatorRole),
            isLineBreak: cache.subviewsCache.map { $0.layoutValues.isLineBreak }
        )
        self.axis = axis
        self.itemSpacing = itemSpacing
        self.cache = cache
    }

    // MARK: - Input seam

    /// Returns content-only breaker input, including selected item separators in each item's leading spacing.
    func foldIntoContent(_ input: BreakerInput) -> BreakerInput {
        let itemBySubview = Dictionary(uniqueKeysWithValues: zip(input.subviewIndices, input.items))
        var items: [MeasuredItem] = []
        var subviewIndices: [Int] = []
        items.reserveCapacity(plan.contentIndices.count)
        subviewIndices.reserveCapacity(plan.contentIndices.count)
        for position in plan.contentIndices.indices {
            let subviewIndex = plan.contentIndices[position]
            guard var item = itemBySubview[subviewIndex] else { continue }
            item.spacing = breakerSpacing(beforeContentPosition: position)
            items.append(item)
            subviewIndices.append(subviewIndex)
        }
        return BreakerInput(items: items, subviewIndices: subviewIndices)
    }

    /// Leading space the breaker reserves before the content item at `position`: the normal spacing,
    /// plus the item separator's breadth and its own spacing when an eligible gap carries one. The
    /// breaker drops it automatically where a line breaks (first-on-line items get zero leading space),
    /// which is exactly where the item separator yields to a line separator.
    /// Empty overrides use ordinary content-to-content spacing.
    private func breakerSpacing(beforeContentPosition position: Int) -> CGFloat {
        guard position > 0 else { return 0 }
        let current = plan.contentIndices[position]
        let previous = plan.contentIndices[position - 1]
        if let separator = itemSeparator(before: current) {
            return spacing(from: previous, to: separator.index) + separator.breadth + spacing(from: separator.index, to: current)
        }
        return spacing(from: previous, to: current)
    }

    // MARK: - Output seam

    /// Re-materializes separators into the wrapped content lines: an item separator before each
    /// eligible non-first item on a line, and a line separator as its own single-item line at each
    /// break boundary. Records the content line structure and hides any separators left unused.
    func materialize(
        in lines: WrappedLines,
        justified: Bool,
        proposal: ProposedViewSize
    ) -> LineAdaptation {
        let structure = lineStructure(of: lines)
        let breadth = lineSeparatorBreadth(for: lines, justified: justified, proposal: proposal)

        var result: WrappedLines = []
        result.reserveCapacity(lines.count * 2)
        for index in lines.indices {
            if index > 0, let first = lines[index].first?.index, let separator = lineSeparator(startingLineAt: first) {
                // A line separator reuses all the existing line placement, spacing, and alignment
                // machinery for free by being its own single-item line.
                result.append([WrappedItem(index: separator, size: breadth, leadingSpace: 0)])
            }
            result.append(expandItemSeparators(in: lines[index]))
        }

        let placed = Set(result.flatMap { $0.map(\.index) })
        return LineAdaptation(lines: result, hidden: unusedSeparators(placed: placed), lineStructure: structure)
    }

    /// Returns line indices in caller subview order, excluding injected separators.
    /// `ItemSeparator` entries use the preceding content item's line index.
    /// Hidden content and overrides without preceding visible content use `hiddenLineSentinel`.
    func lineStructure(of visible: WrappedLines) -> [Int] {
        var lineBySubview: [Int: Int] = [:]
        for lineIndex in visible.indices {
            for item in visible[lineIndex] {
                lineBySubview[item.index] = lineIndex
            }
        }
        var lineOf: [Int] = []
        var precedingLine = Self.hiddenLineSentinel
        for index in cache.subviewsCache.indices {
            switch cache.subviewsCache[index].separatorRole {
                case .content:
                    precedingLine = lineBySubview[index] ?? Self.hiddenLineSentinel
                    lineOf.append(precedingLine)
                case .itemSeparatorOverride:
                    lineOf.append(precedingLine)
                case .itemSeparator, .lineSeparator:
                    break
            }
        }
        return lineOf
    }

    /// Sentinel stored in `lineStructure` for content items absent from the visible output (capped by
    /// maxLines). The value is negative so the view layer can check `>= 0` for visibility.
    static let hiddenLineSentinel = -1

    /// The eligible line separator for the boundary before the line that begins with `contentIndex`.
    /// Returns `nil` for the overflow indicator.
    private func lineSeparator(startingLineAt contentIndex: Int) -> Int? {
        guard contentIndex != cache.overflowSubviewIndex,
            let position = plan.position(ofContentIndex: contentIndex),
            let gap = plan.gap(before: position),
            gap.isEligible
        else { return nil }
        return gap.lineSeparator
    }

    /// The breadth proposed to line separators: the justified width when justifying, otherwise the
    /// widest content line, so a full-width separator (e.g. a `Divider`) spans the laid-out content.
    private func lineSeparatorBreadth(for lines: WrappedLines, justified: Bool, proposal: ProposedViewSize) -> CGFloat {
        if justified, proposal.value(on: axis).isFinite {
            return proposal.value(on: axis)
        }
        return lines.map { line in line.sum { $0.size + $0.leadingSpace } }.max() ?? 0
    }

    /// Splits each folded item separator back out of the following content item's leading space,
    /// inserting it as an ordinary in-line item with its own breadth and spacing.
    private func expandItemSeparators(in line: WrappedLine) -> WrappedLine {
        var items: WrappedLine = []
        items.reserveCapacity(line.count)
        for indexInLine in line.indices {
            var output = line[indexInLine]
            if indexInLine > 0, let separator = itemSeparator(before: output.index) {
                items.append(WrappedItem(index: separator.index, size: separator.breadth, leadingSpace: separator.leadingSpace))
                output.leadingSpace -= separator.leadingSpace + separator.breadth
            }
            items.append(output)
        }
        return items
    }

    /// Separators left unused — orphaned at an edge, mid-line, or in a truncated/ineligible gap. They
    /// must still be placed once and collapsed off-screen, like truncated content.
    private func unusedSeparators(placed: Set<Int>) -> [Int] {
        plan.separatorIndices.filter { !placed.contains($0) }
    }

    // MARK: - Shared geometry

    /// The eligible item separator drawn before content item `contentIndex`, or `nil` when its gap
    /// carries no in-line separator. Used by both seams — to reserve its breadth before wrapping, and
    /// to re-insert it after.
    /// Returns `nil` for the overflow indicator.
    private func itemSeparator(before contentIndex: Int) -> ItemSeparator? {
        guard contentIndex != cache.overflowSubviewIndex,
            let position = plan.position(ofContentIndex: contentIndex),
            let gap = plan.gap(before: position),
            gap.isEligible,
            let separator = gap.itemSeparator
        else { return nil }
        return ItemSeparator(
            index: separator,
            breadth: cache.subviewsCache[separator].ideal.breadth,
            leadingSpace: spacing(from: plan.contentIndices[position - 1], to: separator)
        )
    }

    private func spacing(from previous: Int, to current: Int) -> CGFloat {
        cache.spacing(from: previous, to: current, itemSpacing: itemSpacing, axis: axis)
    }
}
