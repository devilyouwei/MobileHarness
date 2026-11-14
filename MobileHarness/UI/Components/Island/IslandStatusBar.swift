import Foundation
import Observation

/// Read-only native facts injected by the host; never part of IslandContent or Action JSON.
public struct IslandDeviceStatus: Equatable, Sendable {
    public enum Network: String, Sendable { case unknown, offline, wifi, cellular, wired, other }
    public var network: Network
    public var batteryLevel: Double?
    public var charging: Bool
    public var lowPower: Bool
    public init(
        network: Network = .unknown, batteryLevel: Double? = nil, charging: Bool = false, lowPower: Bool = false
    ) {
        self.network = network
        self.batteryLevel = batteryLevel
        self.charging = charging
        self.lowPower = lowPower
    }
    var batteryPercent: Int? {
        guard let batteryLevel, batteryLevel.isFinite, (0...1).contains(batteryLevel) else { return nil }
        return Int((batteryLevel * 100).rounded())
    }
}
public typealias IslandDeviceStatusReading = @MainActor @Sendable () throws -> IslandDeviceStatus

/// One visible-surface refresh owner. Reads cached facts only, with no hardware observation or business output.
@Observable @MainActor final class IslandStatusBarState {
    private(set) var value = IslandDeviceStatus()
    private(set) var date = Date()
    private(set) var active = false
    private(set) var failed = false
    @ObservationIgnored private let read: IslandDeviceStatusReading?
    @ObservationIgnored private let onFailure: UIFailureReporting
    @ObservationIgnored private var worker: Task<Void, Never>?
    init(read: IslandDeviceStatusReading?, onFailure: @escaping UIFailureReporting) {
        self.read = read
        self.onFailure = onFailure
    }
    isolated deinit { worker?.cancel() }
    func start() {
        guard !active else { return }
        active = true
        refresh()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                let toMinute = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                do { try await Task.sleep(for: .seconds(min(5, max(0.05, toMinute)))) } catch { return }
                guard !Task.isCancelled, let self, self.active else { return }
                self.refresh()
            }
        }
    }
    func stop() {
        active = false
        worker?.cancel()
        worker = nil
        value = .init()
        failed = false
    }
    func refresh() {
        guard active else { return }
        date = Date()
        guard let read else { return }
        do {
            value = try read()
            failed = false
        } catch {
            value = .init()
            if !failed { onFailure("island.systemStatus", "read", error) }
            failed = true
        }
    }
}

/// One shell owns both system and business regions. Insets compress together before hiding statuses.
struct IslandStatusBarLayout: Equatable {
    static let padding: CGFloat = 16
    static let minimumPadding: CGFloat = 10
    static let networkWidth: CGFloat = 18
    static let batterySize = CGSize(width: 28, height: 14)
    let time: CGRect?
    let network: CGRect?
    let battery: CGRect?
    static func resolve(shell: CGRect, occupied: CGRect, row: CGRect, timeWidth: CGFloat = 48) -> Self {
        let gap: CGFloat = 6
        let businessGap: CGFloat = 4
        let rightWidth = networkWidth + gap + batterySize.width
        let leftRoom = occupied.minX - businessGap - timeWidth - shell.minX
        let rightRoom = shell.maxX - occupied.maxX - businessGap - rightWidth
        let inset = max(minimumPadding, min(padding, leftRoom, rightRoom))
        let left = shell.minX + inset
        let right = shell.maxX - inset
        let time =
            left + timeWidth <= occupied.minX - businessGap
            ? CGRect(x: left, y: row.minY, width: timeWidth, height: row.height) : nil
        let battery =
            right - batterySize.width >= occupied.maxX + businessGap
            ? CGRect(
                x: right - batterySize.width, y: row.midY - batterySize.height / 2,
                width: batterySize.width, height: batterySize.height) : nil
        let network =
            battery != nil && right - rightWidth >= occupied.maxX + businessGap
            ? CGRect(
                x: right - rightWidth, y: row.midY - networkWidth / 2,
                width: networkWidth, height: networkWidth) : nil
        return .init(time: time, network: network, battery: battery)
    }
    /// Full viewport coordinates inside the animated shell: clipping and motion belong to the same surface.
    static func contentFrame(viewport: CGSize, shell: CGRect) -> CGRect {
        CGRect(x: -shell.minX, y: -shell.minY, width: viewport.width, height: viewport.height)
    }
}

struct IslandBatteryGeometry {
    let body: CGRect
    let terminal: CGRect
    let fill: CGRect
    static func resolve(size: CGSize, level: Double?) -> Self {
        let body = CGRect(x: 0.5, y: 0.5, width: max(0, size.width - 3.5), height: max(0, size.height - 1))
        let inside = body.insetBy(dx: 1, dy: 1)
        let fraction = level.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } ?? 0
        return .init(
            body: body,
            terminal: CGRect(x: size.width - 2, y: size.height / 2 - 2, width: 1.5, height: 4),
            fill: CGRect(x: inside.minX, y: inside.minY, width: inside.width * fraction, height: inside.height))
    }
}

#if os(iOS)
    import UIKit

    @MainActor final class IslandStatusBarView: UIView {
        private let clock = UILabel()
        private let network = UIImageView()
        private let battery = IslandBatteryView()
        private let formatter = DateFormatter()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            clock.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            clock.textColor = .white
            clock.textAlignment = .center
            network.contentMode = .scaleAspectFit
            network.tintColor = .white
            network.isAccessibilityElement = true
            for view in [clock, network, battery] { addSubview(view) }
        }
        required init?(coder: NSCoder) { nil }
        func update(state: IslandStatusBarState, language: AppLanguage) {
            formatter.locale = language.locale
            formatter.timeZone = .current
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
            clock.text = formatter.string(from: state.date)
            let value = state.value
            let symbol: String
            let label: String
            switch value.network {
            case .unknown:
                symbol = "questionmark"
                label = "Network status unknown"
            case .offline:
                symbol = "wifi.slash"
                label = "No network connection"
            case .wifi:
                symbol = "wifi"
                label = "Wi-Fi network"
            case .cellular:
                symbol = "antenna.radiowaves.left.and.right"
                label = "Cellular network"
            case .wired:
                symbol = "network"
                label = "Wired network"
            case .other:
                symbol = "network"
                label = "Other network"
            }
            network.image = UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            network.accessibilityLabel = language.text(label)
            battery.update(value, language: language)
        }
        var visualState: [(CGRect, CGFloat)] {
            [clock, network, battery].map {
                (
                    $0.layer.presentation()?.frame ?? $0.frame,
                    CGFloat($0.layer.presentation()?.opacity ?? Float($0.alpha))
                )
            }
        }
        func restore(_ values: [(CGRect, CGFloat)]) {
            for (view, value) in zip([clock, network, battery], values) {
                view.frame = value.0
                view.alpha = value.1
            }
        }
        func arrange(placement: IslandPlacement) {
            let layout = IslandStatusBarLayout.resolve(
                shell: placement.frame, occupied: placement.header, row: placement.header,
                timeWidth: max(46, ceil(clock.sizeThatFits(CGSize(width: 140, height: 40)).width)))
            place(clock, in: layout.time)
            place(network, in: layout.network)
            place(battery, in: layout.battery)
        }
        private func place(_ view: UIView, in frame: CGRect?) {
            view.alpha = frame == nil ? 0 : 1
            view.accessibilityElementsHidden = frame == nil
            if let frame { view.frame = frame }
        }
    }

    /// Battery body and terminal keep a fixed footprint; charge changes fill, never the icon size.
    @MainActor private final class IslandBatteryView: UIView {
        private var value = IslandDeviceStatus()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            isAccessibilityElement = true
            contentMode = .redraw
        }
        required init?(coder: NSCoder) { nil }
        func update(_ value: IslandDeviceStatus, language: AppLanguage) {
            self.value = value
            accessibilityLabel =
                value.batteryPercent.map {
                    language.format("Battery %@%%", String($0)) + (value.charging ? language.text(", charging") : "")
                        + (value.lowPower ? language.text(", Low Power Mode") : "")
                } ?? language.text("Battery level unknown")
            setNeedsDisplay()
        }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            let geometry = IslandBatteryGeometry.resolve(size: bounds.size, level: value.batteryLevel)
            let body = UIBezierPath(roundedRect: geometry.body, cornerRadius: 3)
            UIColor.white.withAlphaComponent(0.35).setFill()
            body.fill()
            UIColor.white.withAlphaComponent(0.6).setStroke()
            body.lineWidth = 1
            body.stroke()
            UIBezierPath(roundedRect: geometry.terminal, cornerRadius: 0.7).fill()
            context.saveGState()
            UIBezierPath(roundedRect: geometry.body.insetBy(dx: 1, dy: 1), cornerRadius: 2).addClip()
            let color: UIColor =
                value.lowPower
                ? .systemYellow
                : value.charging
                    ? .systemGreen
                    : (value.batteryPercent ?? 100) <= 20 ? .systemRed : .white
            color.setFill()
            context.fill(geometry.fill)
            context.restoreGState()
            let label = value.batteryPercent.map(String.init) ?? "—"
            let font = UIFont.monospacedDigitSystemFont(ofSize: value.charging ? 8.5 : 10, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let size = (label as NSString).size(withAttributes: attributes)
            let center = geometry.body.midX + (value.charging ? 2 : 0)
            (label as NSString).draw(
                at: CGPoint(x: center - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            if value.charging {
                UIImage(systemName: "bolt.fill")?.withTintColor(.black, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 2, y: bounds.midY - 4, width: 5, height: 8))
            }
        }
    }
#endif
