import SwiftUI

/// Distinguishes content items, automatic separators, and `ItemSeparator` overrides.
///
/// The layout skips separator processing when all subviews are content.
@usableFromInline
enum SeparatorRole: Sendable, Hashable {
    /// A regular content item supplied by the caller.
    case content
    /// A separator drawn between two items on the same line.
    case itemSeparator
    /// An `ItemSeparator` override. Empty overrides suppress the automatic item separator.
    case itemSeparatorOverride(isEmpty: Bool)
    /// A separator drawn between two lines.
    case lineSeparator

    /// Whether this role is a separator (as opposed to content). Used from `@inlinable` cache code,
    /// so it avoids relying on the synthesized `Equatable` conformance there.
    @usableFromInline
    var isSeparator: Bool {
        switch self {
            case .content: false
            case .itemSeparator, .itemSeparatorOverride, .lineSeparator: true
        }
    }
}

/// Stores the separator role for layout and variadic enumeration.
/// Variadic child proxies preserve the trait but need the layout value restored.
@usableFromInline
struct SeparatorRoleLayoutValueKey: LayoutValueKey, _ViewTraitKey {
    @usableFromInline
    static let defaultValue: SeparatorRole = .content
}

/// Reports caller subview line indices, including `ItemSeparator` entries, for line separator identity.
@usableFromInline
struct LineStructureReporterKey: LayoutValueKey {
    @usableFromInline
    static let defaultValue: (@Sendable ([Int]) -> Void)? = nil
}

/// Selects item and line separators between adjacent content items from their ``SeparatorRole`` tags.
///
/// The last `ItemSeparator` override replaces the automatic item separator. Empty overrides select none.
/// The selected line separator is the first one after the last override, or the first one in the gap
/// if no line separator follows the override.
///
/// ``FlowLayout`` chooses which selected separator to display after wrapping.
struct SeparatorPlan {
    struct Gap: Equatable {
        var itemSeparator: Int?
        var lineSeparator: Int?
        /// A gap is eligible only between two real items. Gaps touching a manual line-break marker
        /// (``LineBreak``) are skipped so separators never collide with an explicit break.
        var isEligible: Bool
    }

    /// Content subview indices in source order, excluding all separator roles.
    let contentIndices: [Int]
    /// Separator subview indices, including overrides, used to hide unused separators.
    let separatorIndices: [Int]
    /// `gaps[p]` describes the gap *before* content position `p`. `gaps[0]` (if present) is `nil`.
    private let gaps: [Gap?]
    private let positionByContentIndex: [Int: Int]

    init(roles: [SeparatorRole], isLineBreak: [Bool]) {
        var contentIndices: [Int] = []
        var separatorIndices: [Int] = []
        for index in roles.indices {
            if roles[index] == .content {
                contentIndices.append(index)
            } else {
                separatorIndices.append(index)
            }
        }

        var gaps: [Gap?] = contentIndices.isEmpty ? [] : [nil]
        for position in contentIndices.indices.dropFirst() {
            let previous = contentIndices[position - 1]
            let current = contentIndices[position]
            var gap = Gap(
                itemSeparator: nil,
                lineSeparator: nil,
                isEligible: !isLineBreak[previous] && !isLineBreak[current]
            )
            var overrideIndex: Int?
            for between in (previous + 1) ..< current {
                switch roles[between] {
                    case .itemSeparator: gap.itemSeparator = gap.itemSeparator ?? between
                    case .itemSeparatorOverride: overrideIndex = between
                    case .lineSeparator: gap.lineSeparator = gap.lineSeparator ?? between
                    case .content: break
                }
            }
            if let overrideIndex {
                gap.itemSeparator = roles[overrideIndex] == .itemSeparatorOverride(isEmpty: true) ? nil : overrideIndex
                gap.lineSeparator = ((overrideIndex + 1) ..< current).first { roles[$0] == .lineSeparator } ?? gap.lineSeparator
            }
            gaps.append(gap.itemSeparator != nil || gap.lineSeparator != nil ? gap : nil)
        }

        self.contentIndices = contentIndices
        self.separatorIndices = separatorIndices
        self.gaps = gaps
        positionByContentIndex = Dictionary(
            uniqueKeysWithValues: contentIndices.enumerated().map { ($1, $0) }
        )
    }

    /// The content position (index into ``contentIndices``) of a given subview index, if it is content.
    func position(ofContentIndex index: Int) -> Int? {
        positionByContentIndex[index]
    }

    /// The gap immediately before content position `position`, if any.
    func gap(before position: Int) -> Gap? {
        guard gaps.indices.contains(position) else { return nil }
        return gaps[position]
    }
}
