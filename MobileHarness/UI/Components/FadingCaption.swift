import Foundation

/// Complete display text is independent of animation completion; offsets use UILabel's UTF-16 indices.
public struct CaptionPresentation: Equatable, Sendable {
    public let text: String
    public let stableUTF16Count: Int
    public let animatesSuffix: Bool
    public var revisedRange: NSRange {
        NSRange(location: stableUTF16Count, length: text.utf16.count - stableUTF16Count)
    }
    public init(previous: String, text: String, finalized: Bool = false, reduceMotion: Bool = false) {
        let next = Array(text.suffix(320))
        self.text = String(next)
        let count = zip(previous.suffix(320), next).prefix { $0 == $1 }.count
        stableUTF16Count = finalized || reduceMotion ? self.text.utf16.count : String(next.prefix(count)).utf16.count
        animatesSuffix = !finalized && !reduceMotion && stableUTF16Count < self.text.utf16.count
    }
}

#if os(iOS)
    import SwiftUI
    import UIKit

    @MainActor
    struct FadingCaption: View {
        let text: String
        let reduceMotion: Bool
        var color: Color = .white
        var finalized = false
        var body: some View {
            CaptionSurface(text: text, reduceMotion: reduceMotion, color: color, finalized: finalized)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        }
    }

    @MainActor
    private struct CaptionSurface: UIViewRepresentable {
        let text: String
        let reduceMotion: Bool
        let color: Color
        let finalized: Bool
        func makeUIView(context: Context) -> NativeCaptionSurface { NativeCaptionSurface() }
        func updateUIView(_ view: NativeCaptionSurface, context: Context) {
            _ = context.environment.dynamicTypeSize
            view.apply(text: text, finalized: finalized, reduceMotion: reduceMotion, color: UIColor(color))
        }
    }

    /// Two identical layouts, differing only in color ranges. Only layer opacity animates.
    @MainActor
    private final class NativeCaptionSurface: UIView {
        private let scroll = UIScrollView()
        private let stable = UILabel()
        private let incoming = UILabel()
        private let edgeFade = CAGradientLayer()
        private var presentation: CaptionPresentation?
        private var finalized = false
        private var reduceMotion = false
        private var color: UIColor?
        private var font: UIFont?
        private var textLayoutNeeded = true
        private var previousSize: CGSize = .zero

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            scroll.showsVerticalScrollIndicator = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.bounces = false
            scroll.clipsToBounds = true
            addSubview(scroll)
            for label in [stable, incoming] {
                label.backgroundColor = .clear
                label.isOpaque = false
                label.numberOfLines = 0
                label.textAlignment = .center
                label.lineBreakMode = .byWordWrapping
                label.isAccessibilityElement = false
                scroll.addSubview(label)
            }
            edgeFade.colors = [
                UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor,
            ]
            edgeFade.startPoint = CGPoint(x: 0.5, y: 0)
            edgeFade.endPoint = CGPoint(x: 0.5, y: 1)
            layer.mask = edgeFade
        }
        required init?(coder: NSCoder) { nil }

        func apply(text: String, finalized: Bool, reduceMotion: Bool, color: UIColor) {
            let preferred = UIFont.preferredFont(forTextStyle: .title3)
            let font = UIFont.systemFont(ofSize: preferred.pointSize, weight: .medium)
            guard
                presentation == nil || presentation?.text != String(text.suffix(320)) || self.finalized != finalized
                    || self.reduceMotion != reduceMotion || self.color != color || self.font != font
            else { return }
            let value = CaptionPresentation(
                previous: presentation?.text ?? "", text: text, finalized: finalized,
                reduceMotion: reduceMotion)
            presentation = value
            self.finalized = finalized
            self.reduceMotion = reduceMotion
            self.color = color
            self.font = font
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 7
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            let base = NSMutableAttributedString(string: value.text, attributes: attributes)
            let addition = NSMutableAttributedString(string: value.text, attributes: attributes)
            base.addAttribute(.foregroundColor, value: UIColor.clear, range: value.revisedRange)
            addition.addAttribute(
                .foregroundColor, value: UIColor.clear, range: NSRange(location: 0, length: value.stableUTF16Count))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.layer.removeAnimation(forKey: "captionSuffix")
            // The target is always readable, including when the animation is interrupted or removed.
            incoming.layer.opacity = 1
            stable.attributedText = base
            incoming.attributedText = addition
            CATransaction.commit()
            if value.animatesSuffix, let screen = window?.screen {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.15
                fade.toValue = 1
                fade.duration = 0.25
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let rate = Float(screen.maximumFramesPerSecond)
                fade.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
                incoming.layer.add(fade, forKey: "captionSuffix")
            }
            textLayoutNeeded = true
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != previousSize || textLayoutNeeded else { return }
            previousSize = bounds.size
            textLayoutNeeded = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scroll.frame = bounds
            let height = ceil(
                stable.sizeThatFits(CGSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)).height)
            let frame = CGRect(x: 0, y: 18, width: bounds.width, height: height)
            stable.frame = frame
            incoming.frame = frame
            scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, height + 36))
            scroll.setContentOffset(
                CGPoint(x: 0, y: max(0, scroll.contentSize.height - bounds.height)), animated: false)
            edgeFade.frame = bounds
            let fade = min(18 / max(bounds.height, 1), 0.25)
            edgeFade.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
            CATransaction.commit()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { incoming.layer.removeAnimation(forKey: "captionSuffix") }
        }
    }
#endif
