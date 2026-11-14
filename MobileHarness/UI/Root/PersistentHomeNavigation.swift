#if canImport(SwiftUI)
    import SwiftUI

    /// Navigation covers the home surface without making it a navigation destination.
    @MainActor
    struct PersistentHomeNavigation<Destination: Hashable, Home: View, Page: View>: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                        .navigationDestination(for: Destination.self) { page in
                            #if os(iOS)
                                destination(page)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.background)
                                    .containerBackground(.clear, for: .navigation)
                            #else
                                destination(page)
                            #endif
                        }
                }
                #if !os(iOS)
                    .opacity(covered ? 1 : 0)
                #endif
                .allowsHitTesting(covered)
                .accessibilityHidden(!covered)
            }
        }

        private var navigationRoot: some View {
            #if os(iOS)
                Color.clear
                    .containerBackground(.clear, for: .navigation)
                    .navigationTitle(appCopy.text("Home")).toolbar(.hidden, for: .navigationBar)
            #else
                Color.clear
            #endif
        }
    }
#endif
