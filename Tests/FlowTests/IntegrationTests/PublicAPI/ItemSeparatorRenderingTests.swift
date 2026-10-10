#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import Flow

    @Suite(.tags(.requirements))
    @MainActor
    struct ItemSeparatorRenderingTests {
        @Test(arguments: [false, true], [false, true])
        func overridesUseMeasuredSizeAndNormalSpacing(vertical: Bool, legacy: Bool) {
            for spacing: CGFloat? in [nil, 0, 5] {
                let empty = flow(vertical: vertical, legacy: legacy, spacing: spacing) {
                    box(30, vertical: vertical)
                    ItemSeparator { EmptyView() }
                    box(30, vertical: vertical)
                }
                let custom = flow(vertical: vertical, legacy: legacy, spacing: spacing) {
                    box(30, vertical: vertical)
                    ItemSeparator { box(20, vertical: vertical) }
                    box(30, vertical: vertical)
                }
                let plain = flow(vertical: vertical, legacy: legacy, spacing: spacing) {
                    box(30, vertical: vertical)
                    box(30, vertical: vertical)
                }
                let emptyBreadth: CGFloat = spacing == nil ? 68 : (spacing == 5 ? 65 : 60)
                let customBreadth: CGFloat = spacing == nil ? 96 : (spacing == 5 ? 90 : 80)
                #expect(size(empty, breadth: emptyBreadth, vertical: vertical) == dimensions(emptyBreadth, 10, vertical: vertical))
                #expect(size(custom, breadth: customBreadth, vertical: vertical) == dimensions(customBreadth, 10, vertical: vertical))
                #expect(size(custom, breadth: customBreadth - 1, vertical: vertical) == dimensions(30, 20, vertical: vertical))
                #expect(size(plain, breadth: customBreadth, vertical: vertical) == dimensions(30, 20, vertical: vertical))
            }
        }

        @Test(arguments: [false, true])
        func customDirectiveWorksWithoutGlobalSeparator(vertical: Bool) {
            let content = Group {
                box(30, vertical: vertical)
                ItemSeparator { box(20, vertical: vertical) }
                box(30, vertical: vertical)
            }
            let view = Group {
                if vertical {
                    VFlow(itemSpacing: 5, columnSpacing: 0) { content }
                } else {
                    HFlow(itemSpacing: 5, rowSpacing: 0) { content }
                }
            }
            #expect(size(view, breadth: 90, vertical: vertical) == dimensions(90, 10, vertical: vertical))
            #expect(size(view, breadth: 89, vertical: vertical) == dimensions(30, 20, vertical: vertical))
        }

        @Test func builderContentFormsOneSeparator() {
            let view = HFlow(itemSpacing: 5, rowSpacing: 0) {
                box(30, vertical: false)
                ItemSeparator {
                    Color.red.frame(width: 20, height: 10)
                    Color.blue.frame(width: 10, height: 10)
                }
                box(30, vertical: false)
            }
            .itemSeparator { box(50, vertical: false) }
            #expect(size(view, breadth: 90, vertical: false) == CGSize(width: 90, height: 10))
        }

        @Test(arguments: [false, true], [false, true])
        func trailingDirectiveDoesNotChangeOverflowSpacing(vertical: Bool, empty: Bool) {
            for breadth: CGFloat in [80, 90] {
                let plain = cappedFlow(vertical: vertical, trailingDirective: false, empty: empty)
                let directed = cappedFlow(vertical: vertical, trailingDirective: true, empty: empty)
                let expectedBreadth: CGFloat = breadth == 80 ? 48 : 86
                #expect(size(plain, breadth: breadth, vertical: vertical) == dimensions(expectedBreadth, 10, vertical: vertical))
                #expect(size(directed, breadth: breadth, vertical: vertical) == dimensions(expectedBreadth, 10, vertical: vertical))
            }
        }

        private func cappedFlow(vertical: Bool, trailingDirective: Bool, empty: Bool) -> some View {
            let content = Group {
                ForEach(0 ..< 3) { _ in
                    box(30, vertical: vertical)
                }
                if trailingDirective {
                    if empty {
                        ItemSeparator { EmptyView() }
                    } else {
                        ItemSeparator { ZeroSpacingLayout { box(20, vertical: vertical) } }
                    }
                }
            }
            return Group {
                if vertical {
                    VFlow(itemSpacing: nil, columnSpacing: 0) { content }
                } else {
                    HFlow(itemSpacing: nil, rowSpacing: 0) { content }
                }
            }
            .maxLines(1) { _ in box(10, vertical: vertical) }
        }

        private struct ZeroSpacingLayout: Layout {
            func spacing(subviews: LayoutSubviews, cache: inout ()) -> ViewSpacing { .zero }

            func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
                subviews[0].sizeThatFits(proposal)
            }

            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
                subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            }
        }

        @Test(arguments: [false, true])
        func neighboringStateSurvivesDirectiveChangesAndReordering(legacy: Bool) async throws {
            _ = NSApplication.shared
            let input = StateInput()
            let activity = StateActivity()
            let host = NSHostingView(rootView: StateScene(input: input, activity: activity, legacy: legacy))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 190, height: 100),
                styleMask: .borderless,
                backing: .buffered,
                defer: true
            )
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let initial = activity.tokens
            #expect(Set(initial.keys) == [1, 2, 3])
            for (ids, empty, width) in [([3, 1, 2], true, 35.0), ([2, 3, 1], false, 190.0)] {
                input.ids = ids
                input.empty = empty
                input.revision += 1
                window.setContentSize(CGSize(width: width, height: 100))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                #expect(activity.tokens == initial)
                #expect(activity.revisions == [1: input.revision, 2: input.revision, 3: input.revision])
                if legacy {
                    #expect(activity.lines == (width == 35 ? [-1, 0, 0, 1, 1, 2] : [-1, 0, 0, 0, 0, 0]))
                }
                let builds = activity.lineBuilds
                try await Task.sleep(for: .milliseconds(150))
                #expect(activity.lineBuilds - builds <= 2)
            }
        }

        private final class StateInput: ObservableObject {
            @Published var ids = [1, 2, 3]
            @Published var empty = false
            @Published var revision = 0
        }

        private final class StateActivity {
            var tokens: [Int: UUID] = [:]
            var revisions: [Int: Int] = [:]
            var lines: [Int] = []
            var lineBuilds = 0
        }

        private struct StateScene: View {
            @ObservedObject var input: StateInput
            let activity: StateActivity
            let legacy: Bool
            @StateObject private var lineStructure = Reported<[Int]>([])

            var body: some View {
                let content = Group {
                    ForEach(input.ids, id: \.self) { id in
                        if input.empty {
                            ItemSeparator { EmptyView() }
                        } else {
                            ItemSeparator { Color.orange.frame(width: 10, height: 10) }
                        }
                        StatefulItem(id: id, revision: input.revision, activity: activity)
                    }
                }
                let separator = { [activity] in
                    activity.lineBuilds += 1
                    return Color.gray.frame(height: 2)
                }
                if legacy {
                    HFlowLayout(itemSpacing: 5, rowSpacing: 0) {
                        _VariadicView.Tree(
                            SeparatorInterleaver(
                                itemSeparator: { AnyView(Color.black.frame(width: 20, height: 10)) },
                                lineSeparator: { AnyView(separator()) },
                                lineOf: lineStructure.value
                            )
                        ) {
                            content
                        }
                        .layoutValue(key: LineStructureReporterKey.self, value: lineStructure.reporter())
                    }
                    .task(id: lineStructure.value) { activity.lines = lineStructure.value }
                } else {
                    HFlow(itemSpacing: 5, rowSpacing: 0) { content }
                        .itemSeparator { Color.black.frame(width: 20, height: 10) }
                        .lineSeparator(separator)
                }
            }
        }

        private struct StatefulItem: View {
            let id: Int
            let revision: Int
            let activity: StateActivity
            @State private var token = UUID()

            var body: some View {
                Color.blue.frame(width: 30, height: 10)
                    .task(id: revision) {
                        activity.tokens[id] = token
                        activity.revisions[id] = revision
                    }
            }
        }

        @ViewBuilder
        private func flow(
            vertical: Bool,
            legacy: Bool,
            spacing: CGFloat?,
            @ViewBuilder content: () -> some View
        ) -> some View {
            if legacy {
                let layout =
                    vertical
                    ? AnyLayout(VFlowLayout(itemSpacing: spacing, columnSpacing: 0))
                    : AnyLayout(HFlowLayout(itemSpacing: spacing, rowSpacing: 0))
                layout {
                    _VariadicView.Tree(
                        SeparatorInterleaver(
                            itemSeparator: { AnyView(box(50, vertical: vertical)) },
                            lineSeparator: nil,
                            lineOf: []
                        ),
                        content: content
                    )
                }
            } else if vertical {
                VFlow(itemSpacing: spacing, columnSpacing: 0, content: content)
                    .itemSeparator { box(50, vertical: vertical) }
            } else {
                HFlow(itemSpacing: spacing, rowSpacing: 0, content: content)
                    .itemSeparator { box(50, vertical: vertical) }
            }
        }

        private func box(_ breadth: CGFloat, vertical: Bool) -> some View {
            Color.red.frame(width: vertical ? 10 : breadth, height: vertical ? breadth : 10)
        }

        private func dimensions(_ breadth: CGFloat, _ depth: CGFloat, vertical: Bool) -> CGSize {
            CGSize(width: vertical ? depth : breadth, height: vertical ? breadth : depth)
        }

        private func size(_ view: some View, breadth: CGFloat, vertical: Bool) -> CGSize? {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: vertical ? nil : breadth, height: vertical ? breadth : nil)
            return renderer.nsImage?.size
        }
    }
#endif
