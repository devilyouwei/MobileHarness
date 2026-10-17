#if canImport(SwiftUI)
    import SwiftUI

    /// Navigation covers the home surface without making it a navigation destination.
    @MainActor
    struct PersistentHomeNavigation<Destination: Hashable, Home: View, Page: View>: View {
        @Binding var path: [Destination]
        private let home: Home
        private let destination: (Destination) -> Page

        init(
            path: Binding<[Destination]>, @ViewBuilder home: () -> Home,
            @ViewBuilder destination: @escaping (Destination) -> Page
        ) {
            _path = path
            self.home = home()
            self.destination = destination
        }

        var body: some View {
            let covered = !path.isEmpty
            ZStack {
                home
                    .allowsHitTesting(!covered)
                    .accessibilityHidden(covered)
                NavigationStack(path: $path) {
                    navigationRoot
                        .navigationDestination(for: Destination.self, destination: destination)
                }
                .opacity(covered ? 1 : 0)
                .allowsHitTesting(covered)
                .accessibilityHidden(!covered)
            }
        }

        private var navigationRoot: some View {
            #if os(iOS)
                Color.clear.navigationTitle("首页").toolbar(.hidden, for: .navigationBar)
            #else
                Color.clear
            #endif
        }
    }
#endif
