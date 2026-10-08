#if os(iOS)
    import SwiftUI

    /// Preserve the unchanged prefix, fade in only the revised suffix. No invented typewriter text.
    @MainActor
    struct FadingCaption: View {
        let text: String
        let reduceMotion: Bool
        var color: Color = .white
        @State private var characters: [Character] = []
        @State private var arrivals: [Date] = []
        @State private var animating = false

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating || reduceMotion)) {
                        timeline in
                        characters.indices.reduce(Text("")) { result, index in
                            let age = timeline.date.timeIntervalSince(arrivals[index])
                            let opacity = reduceMotion ? 1 : min(1, max(0.1, age / 0.4))
                            return result + Text(String(characters[index])).foregroundColor(color.opacity(opacity))
                        }
                        .font(.system(.title3, design: .default, weight: .medium))
                        .multilineTextAlignment(.center).lineSpacing(7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }
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
                    let prefix = zip(characters, next).prefix { $0 == $1 }.count
                    arrivals = Array(arrivals.prefix(prefix)) + Array(repeating: Date(), count: next.count - prefix)
                    characters = next
                    animating = true
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        proxy.scrollTo("captionEnd", anchor: .bottom)
                    }
                }
                .task(id: text) {
                    do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                    animating = false
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }

#endif
