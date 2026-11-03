#if os(iOS)
    import SwiftUI
    import WebKit

    public struct WebPageView: View {
        private let page: WebPageContainer
        public init(page: WebPageContainer) { self.page = page }
        public var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: page.address.hasPrefix("file:") ? "doc.richtext" : "globe")
                    Text(page.address.hasPrefix("file:") ? "本地作品" : page.address)
                        .font(.caption).lineLimit(1).textSelection(.enabled)
                    Spacer()
                    if page.loading { ProgressView().controlSize(.small) }
                }
                .padding(10).background(.thinMaterial)
                WebSurface(webView: page.webView).id(ObjectIdentifier(page.webView))
                if let failure = page.failure {
                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3).padding(8)
                }
            }
            .background(.white)
        }
    }
    private struct WebSurface: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
    }
#endif
