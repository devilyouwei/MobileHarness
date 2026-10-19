#if os(macOS)
    import AppKit
    import Observation
    import SwiftUI
    import Testing
    @testable import UI

    @MainActor @Observable private final class NavigationHarnessState {
        var path: [Int] = []
        var tick = 0
    }

    @MainActor private final class HomeMountEvidence {
        var creations = 0
        var detachments = 0
        weak var view: NSView?
        var ticks: [Int] = []
        var visited: Set<Int> = []
        var taskStarted = false
        var taskEnded = false
        let hold = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    }

    @MainActor private final class HomeWitnessView: NSView {
        let evidence: HomeMountEvidence
        private var attached = false
        init(evidence: HomeMountEvidence) {
            self.evidence = evidence
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { attached = true }
            if window == nil && attached { evidence.detachments += 1 }
        }
    }

    @MainActor private struct HomeWitness: NSViewRepresentable {
        let evidence: HomeMountEvidence
        let tick: Int
        func makeNSView(context: Context) -> HomeWitnessView {
            evidence.creations += 1
            let view = HomeWitnessView(evidence: evidence)
            evidence.view = view
            return view
        }
        func updateNSView(_ view: HomeWitnessView, context: Context) { evidence.ticks.append(tick) }
    }

    @MainActor private struct NavigationHarness: View {
        @Bindable var state: NavigationHarnessState
        let evidence: HomeMountEvidence
        var body: some View {
            PersistentHomeNavigation(path: $state.path) {
                HomeWitness(evidence: evidence, tick: state.tick)
                    .task {
                        evidence.taskStarted = true
                        for await _ in evidence.hold.stream {}
                        evidence.taskEnded = true
                    }
            } destination: { page in
                Text("Page \(page)")
                    .onAppear { evidence.visited.insert(page) }
            }
        }
    }

    @MainActor private func awaitNavigation(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func deepNavigationRetainsNativeHomeAndItsWorkUntilRootDestruction() async throws {
        _ = NSApplication.shared
        let state = NavigationHarnessState()
        let evidence = HomeMountEvidence()
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(NavigationHarness(state: state, evidence: evidence)))
        window.contentView = host
        window.orderBack(nil)
        defer {
            evidence.hold.continuation.finish()
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await awaitNavigation("Initial native home mount and task") {
            evidence.taskStarted && evidence.view?.window === window
        }
        let original = try #require(evidence.view)

        // Settings → history → conversation → context → request details, then pop back.
        for depth in [1, 2, 3, 4, 5, 4, 2, 1, 0, 3, 0] {
            state.path = Array(1...max(1, depth)).prefix(depth).map { $0 }
            state.tick += 1
            let tick = state.tick
            host.layoutSubtreeIfNeeded()
            try await awaitNavigation("Navigation depth \(depth), update \(tick)") {
                evidence.ticks.contains(tick) && (depth == 0 || evidence.visited.contains(depth))
            }
            #expect(evidence.view === original)
            #expect(original.window === window)
            #expect(evidence.creations == 1 && evidence.detachments == 0)
            #expect(!evidence.taskEnded)
        }

        host.rootView = AnyView(EmptyView())
        try await awaitNavigation("Root destruction cancels home work") {
            evidence.taskEnded && original.window == nil
        }
        #expect(evidence.detachments == 1)
    }
#endif
