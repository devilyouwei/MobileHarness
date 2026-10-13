#if os(iOS)
    import SwiftUI

    /// Preserve the unchanged prefix, fade in only the revised suffix. No invented typewriter text.
    @MainActor
    struct FadingCaption: View {
        let text: String
        let reduceMotion: Bool
        var color: Color = .white
        @State private var displayed = ""
        @State private var prefix = ""
        @State private var suffix = ""
        @State private var suffixOpacity = 1.0

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    (Text(prefix).foregroundColor(color)
                        + Text(suffix).foregroundColor(color.opacity(suffixOpacity)))
                        .font(.system(.title3, design: .default, weight: .medium))
                        .multilineTextAlignment(.center).lineSpacing(7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    Color.clear.frame(height: 1).id("captionEnd")
                }
                .scrollIndicators(.hidden)
                .mask {
                    GeometryReader { geometry in
                        let fade = min(18 / max(geometry.size.height, 1), 0.25)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: fade),
                                .init(color: .black, location: 1 - fade),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .onChange(of: text, initial: true) { _, new in
                    let next = Array(new.suffix(320))
                    let stable = zip(Array(displayed), next).prefix { $0 == $1 }.count
                    prefix = String(next.prefix(stable))
                    suffix = String(next.dropFirst(stable))
                    displayed = String(next)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { suffixOpacity = reduceMotion ? 1 : 0.15 }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        proxy.scrollTo("captionEnd", anchor: .bottom)
                    }
                }
                .task(id: text) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { suffixOpacity = 1 }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }

#endif
