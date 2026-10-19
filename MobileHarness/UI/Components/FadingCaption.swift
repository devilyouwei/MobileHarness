import Foundation

/// Latest bounded text and grapheme-safe stable/revised boundaries.
public struct CaptionPresentation: Equatable, Sendable {
    public let text: String
    public let stableCharacterCount: Int
    public let stableUTF16Count: Int
    public let animatesSuffix: Bool
    public var revisedRange: NSRange {
        NSRange(location: stableUTF16Count, length: text.utf16.count - stableUTF16Count)
    }
    public init(previous: String, text: String, finalized: Bool = false, reduceMotion: Bool = false) {
        let next = Array(text.suffix(320))
        self.text = String(next)
        let count = zip(previous.suffix(320), next).prefix { $0 == $1 }.count
        stableCharacterCount = finalized || reduceMotion ? next.count : count
        stableUTF16Count = String(next.prefix(stableCharacterCount)).utf16.count
        animatesSuffix = !finalized && !reduceMotion && stableCharacterCount < next.count
    }
}

struct CaptionRenderRun: Equatable, Sendable {
    var text: String
    let appearedAt: ContinuousClock.Instant?
    static let duration = Duration.milliseconds(250)
    static func opacity(appearedAt: ContinuousClock.Instant?, at time: ContinuousClock.Instant) -> Double {
        guard let appearedAt else { return 1 }
        let elapsed = appearedAt.duration(to: time).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let progress = min(1, max(0, seconds / 0.25))
        return 0.15 + 0.85 * (1 - pow(1 - progress, 3))
    }
}

/// Bounded glyph history preserves ongoing fades across appends, corrections and window shifts.
struct CaptionRenderState: Equatable, Sendable {
    private struct Glyph: Equatable, Sendable {
        let character: Character
        var appearedAt: ContinuousClock.Instant?
    }
    private var glyphs: [Glyph] = []
    private var inputByteCount = 0
    private(set) var text = ""
    var runs: [CaptionRenderRun] {
        glyphs.reduce(into: []) { runs, glyph in
            if let last = runs.last, last.appearedAt == glyph.appearedAt {
                runs[runs.count - 1].text.append(glyph.character)
            } else {
                runs.append(CaptionRenderRun(text: String(glyph.character), appearedAt: glyph.appearedAt))
            }
        }
    }
    mutating func update(
        _ input: String, finalized: Bool = false, animated: Bool = true,
        at time: ContinuousClock.Instant = .now
    ) {
        let value = CaptionPresentation(previous: text, text: input, finalized: finalized, reduceMotion: !animated)
        let next = Array(value.text)
        let bytes = input.utf8
        let added = bytes.count - inputByteCount
        var retained = value.stableCharacterCount
        var characters = next
        // Verify the old visible suffix at its old byte position before treating a window shift as an append.
        if animated, !finalized, glyphs.count == 320, added > 0,
            bytes.dropLast(added).suffix(text.utf8.count).elementsEqual(text.utf8)
        {
            if added >= input.suffix(321).utf8.count {
                retained = 0
            } else {
                characters = Array(text + String(decoding: bytes.suffix(added), as: UTF8.self))
                retained = zip(glyphs, characters).prefix { $0.character == $1 }.count
            }
        }
        let old = glyphs
        glyphs = characters.enumerated().map { index, character in
            if !animated || finalized { return Glyph(character: character, appearedAt: nil) }
            if index < retained, index < old.count {
                let appeared = old[index].appearedAt
                return Glyph(
                    character: character,
                    appearedAt: appeared.map { $0.advanced(by: CaptionRenderRun.duration) > time } == true
                        ? appeared : nil)
            }
            return Glyph(character: character, appearedAt: time)
        }
        glyphs = Array(glyphs.suffix(320))
        text = value.text
        inputByteCount = bytes.count
    }
    func isAnimating(at time: ContinuousClock.Instant) -> Bool {
        glyphs.contains { $0.appearedAt.map { $0.advanced(by: CaptionRenderRun.duration) > time } == true }
    }
    mutating func settle() {
        for index in glyphs.indices { glyphs[index].appearedAt = nil }
    }
}

#if os(iOS) || os(macOS)
    import SwiftUI

    private struct CaptionFadeAttribute: TextAttribute {
        let appearedAt: ContinuousClock.Instant
    }

    struct CaptionTextRenderer: TextRenderer {
        let time: ContinuousClock.Instant
        var forceVisible = false
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout {
                for run in line {
                    if !forceVisible, let fade = run[CaptionFadeAttribute.self] {
                        var copy = context
                        copy.opacity *= CaptionRenderRun.opacity(appearedAt: fade.appearedAt, at: time)
                        copy.draw(run)
                    } else {
                        context.draw(run)
                    }
                }
            }
        }
    }

    func captionText(_ runs: [CaptionRenderRun]) -> Text {
        runs.reduce(Text(verbatim: "")) { result, run in
            var part = Text(verbatim: run.text)
            if let appearedAt = run.appearedAt {
                part = part.customAttribute(CaptionFadeAttribute(appearedAt: appearedAt))
            }
            return Text("\(result)\(part)")
        }
    }

    private struct CaptionInput: Equatable {
        let text: String
        let finalized: Bool
        let reduceMotion: Bool
        let generation: UIPresentationToken?
    }

    @MainActor
    struct FadingCaption: View {
        let text: String
        let reduceMotion: Bool
        var color: Color = .white
        var finalized = false
        var generation: UIPresentationToken?
        @Environment(\.scenePhase) private var scenePhase
        @State private var state = CaptionRenderState()
        @State private var renderedGeneration: UIPresentationToken?
        @State private var mounted = false
        @State private var ticking = false
        @State private var position = ScrollPosition(edge: .top)

        var body: some View {
            let input = CaptionInput(
                text: text, finalized: finalized, reduceMotion: reduceMotion, generation: generation)
            // Construct runs only on input/state changes, outside the animation timeline's tick closure.
            let content = captionText(state.runs)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !ticking || !mounted || scenePhase != .active)) {
                context in
                let _ = context.date
                let now = ContinuousClock.now
                ScrollView(.vertical) {
                    content
                        .font(.system(.title3, weight: .medium))
                        .foregroundStyle(color)
                        .multilineTextAlignment(.center)
                        .lineSpacing(7)
                        .textRenderer(CaptionTextRenderer(time: now, forceVisible: reduceMotion || finalized))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .onGeometryChange(for: CGSize.self) {
                            $0.size
                        } action: { _ in
                            position.scrollTo(edge: .bottom)
                        }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .mask {
                    GeometryReader { geometry in
                        let fade = min(18 / max(geometry.size.height, 1), 0.25)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0), .init(color: .black, location: fade),
                                .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                    }
                }
                .onChange(of: state.isAnimating(at: now), initial: true) { _, animating in
                    if !animating, ticking {
                        state.settle()
                        ticking = false
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: input, initial: true) { _, value in submit(value, animated: mounted && scenePhase == .active)
            }
            .onAppear {
                mounted = true
                submit(input, animated: false)
            }
            .onDisappear {
                mounted = false
                ticking = false
                state.settle()
            }
            .onChange(of: scenePhase) { _, _ in
                ticking = false
                state.settle()
            }
        }
        private func submit(_ input: CaptionInput, animated: Bool) {
            if input.generation != renderedGeneration {
                state = CaptionRenderState()
                renderedGeneration = input.generation
            }
            state.update(input.text, finalized: input.finalized, animated: animated && !input.reduceMotion)
            ticking = state.isAnimating(at: .now)
            position.scrollTo(edge: .bottom)
        }
    }
#endif
