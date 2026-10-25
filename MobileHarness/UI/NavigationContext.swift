import Foundation

public enum NavigationPage: String, Encodable, Sendable {
    case home, settings, language, recognition, synthesis, vision, bluetooth, history, album
    case albumPhoto, agentRecords, conversation, turn
}
public enum PageContent: String, Encodable, Sendable { case idle, loading, ready, empty, failed }
public enum PageOverlay: String, Encodable, Sendable { case photoPicker, deleteConfirmation }
public enum PageOperation: String, Encodable, Sendable { case importing, exporting, deleting }
public struct NavigationLocation: Encodable, Sendable, Equatable {
    public let page: NavigationPage
    public let itemID: String?
    public init(_ page: NavigationPage, itemID: String? = nil) {
        self.page = page
        self.itemID = itemID
    }
    private enum CodingKeys: String, CodingKey { case page, itemID }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(page, forKey: .page)
        try fields.encode(itemID, forKey: .itemID)
    }
}

#if os(iOS)
    import SwiftUI

    extension EnvironmentValues {
        @Entry var navigationContext: NavigationState? = nil
        @Entry var recordContextID: String? = nil
    }
    private struct NavigationContextModifier: ViewModifier {
        @Environment(\.navigationContext) private var navigation
        let location: NavigationLocation
        let content: PageContent
        let overlay: PageOverlay?
        @State private var generation: UUID?
        func body(content view: Content) -> some View {
            view.onAppear {
                generation = navigation?.generation
                report(appearing: true)
            }
            .onChange(of: navigation?.generation) { _, value in
                if location.page == .home, navigation?.path.isEmpty == true {
                    generation = value
                    report(appearing: true)
                }
            }
            .onChange(of: content) { _, _ in report() }
            .onChange(of: overlay) { _, _ in report() }
        }
        private func report(appearing: Bool = false) {
            guard let generation else { return }
            if appearing {
                navigation?.confirm(location, content: content, overlay: overlay, generation: generation)
            } else {
                navigation?.updateContext(location, content: content, overlay: overlay, generation: generation)
            }
        }
    }
    extension View {
        func navigationContext(
            _ page: NavigationPage, itemID: String? = nil,
            content: PageContent = .idle, overlay: PageOverlay? = nil
        ) -> some View {
            modifier(
                NavigationContextModifier(
                    location: NavigationLocation(page, itemID: itemID), content: content, overlay: overlay))
        }
    }
#endif

extension AppDestination {
    var contextPage: NavigationPage {
        switch self {
        case .settings: .settings
        case .language: .language
        case .recognition: .recognition
        case .synthesis: .synthesis
        case .vision: .vision
        case .bluetooth: .bluetooth
        case .history: .history
        case .album: .album
        }
    }
}
