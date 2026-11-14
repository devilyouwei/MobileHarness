import Foundation

/// Shared content sizing; housing placement is an App calibration, never a system frame API.
public enum IslandCompactMetrics {
    public static let height: CGFloat = 110.0 / 3
    public static let housingWidth: CGFloat = 376.0 / 3
    public static let slotWidth: CGFloat = 22
    public static let timerWidth: CGFloat = 44
    public static let timerFontSize: CGFloat = 16
    public static let symbolSize: CGFloat = 18
    public static let outerPadding: CGFloat = 8
    public static let safeAreaBottomGap: CGFloat = 34.0 / 3
}

extension IslandIndicator {
    public var compactWidth: CGFloat {
        if case .elapsed = self { return IslandCompactMetrics.timerWidth }
        return IslandCompactMetrics.slotWidth
    }
}

/// Measured audio only: no timer-driven fake waveform and no publication/ActivityKit update per frame.
enum IslandSpectrum {
    static func levels(_ bands: [Float], active: Bool, reduced: Bool) -> [Double] {
        guard active else { return Array(repeating: 0, count: 5) }
        if reduced { return Array(repeating: 0.25, count: 5) }
        return (0..<5).map { column in
            let start = column * 32 / 5
            let end = (column + 1) * 32 / 5
            return Double(
                bands.dropFirst(start).prefix(end - start).filter { $0.isFinite }.map { min(1, max(0, $0)) }.max() ?? 0)
        }
    }
}

#if canImport(SwiftUI)
    import SwiftUI

    struct IslandIndicatorView: View {
        let value: IslandIndicator
        var size: CGFloat? = nil
        var bands: [Float] = []
        var spectrumActive: Bool = false
        var animated = true
        var measuredSpectrum = true
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.font) private var inheritedFont
        var body: some View {
            Group {
                switch value {
                case .symbol(let name, let effect):
                    Image(systemName: name)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(
                            .pulse, options: .repeating, isActive: animated && !reduceMotion && effect == .pulse
                        )
                        .symbolEffect(
                            .variableColor, options: .repeating,
                            isActive: animated && !reduceMotion && effect == .variableColor
                        )
                        .symbolEffect(.bounce, value: animated && !reduceMotion && effect == .bounce ? name : "")
                case .elapsed(let start): IslandElapsedView(startedAt: start)
                case .loading:
                    if reduceMotion {
                        Image(systemName: "ellipsis")
                    } else {
                        ProgressView().tint(.cyan).controlSize(.small).scaleEffect((size ?? 18) / 18)
                    }
                case .progress(let progress):
                    ZStack {
                        Circle().stroke(.primary.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(
                            .primary, style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    }.frame(width: size ?? 18, height: size ?? 18)
                case .spectrum:
                    if !measuredSpectrum {
                        Image(systemName: "waveform")
                    } else {
                        let levels = IslandSpectrum.levels(bands, active: spectrumActive, reduced: reduceMotion)
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { index in
                                Capsule().frame(width: 2, height: 3 + levels[index] * Double((size ?? 18) - 3))
                            }
                        }.animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: levels)
                    }
                }
            }.font(size.map { .system(size: $0, weight: .medium) } ?? inheritedFont)
        }
    }

    /// Both renderers use the system clock text; no per-second model or activity publications.
    struct IslandElapsedView: View {
        let startedAt: Date
        var body: some View {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false, showsHours: false)
                .font(.system(size: IslandCompactMetrics.timerFontSize, weight: .medium, design: .rounded))
                .monospacedDigit().multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: IslandCompactMetrics.timerWidth)
                .accessibilityLabel(elapsedLabel)
        }
        #if SWIFT_PACKAGE
            @Environment(\.locale) private var locale
            private var elapsedLabel: String { AppLanguage(preferredLanguage: locale.identifier).text("Elapsed time") }
        #else
            @Environment(\.locale) private var locale
            private var elapsedLabel: String {
                Bundle.main.url(forResource: locale.identifier, withExtension: "lproj").flatMap(Bundle.init(url:))?
                    .localizedString(forKey: "Elapsed time", value: nil, table: "IslandStatus") ?? "Elapsed time"
            }
        #endif
    }
#endif
