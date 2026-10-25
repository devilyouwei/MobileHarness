import Foundation

#if os(iOS)
    import UIKit
#endif

/// Native facts only. Source selection and model-context envelopes belong to the caller.
public enum PlatformStateSource: String, CaseIterable, Sendable {
    case time, power, thermal, network, permissions, audio, locale, accessibility
}

@MainActor public protocol PlatformStateReading: Sendable {
    /// One JSON object, without a transport or model-context envelope.
    func snapshot(_ source: PlatformStateSource) throws -> Data
}

public enum PlatformStateError: Error, Sendable { case invalidTime, invalidSnapshot }

@MainActor final class NativeSystemState {
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    #if os(iOS)
        private var previousBatteryMonitoring: Bool?
    #endif
    init(now: @escaping @Sendable () -> Date, timeZone: @escaping @Sendable () -> TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }
    func start() {
        #if os(iOS)
            guard previousBatteryMonitoring == nil else { return }
            previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }
    func stop() {
        #if os(iOS)
            if let previousBatteryMonitoring {
                UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
                self.previousBatteryMonitoring = nil
            }
        #endif
    }
    nonisolated static func encode(_ fields: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 8192 else { throw PlatformStateError.invalidSnapshot }
        return data
    }
    func time() throws -> Data { try Self.localTime(at: now(), zone: timeZone()) }
    nonisolated static func localTime(at date: Date, zone: TimeZone) throws -> Data {
        guard date.timeIntervalSince1970.isFinite else { throw PlatformStateError.invalidTime }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = calendar.component(.weekday, from: date)
        guard (1...7).contains(weekday) else { throw PlatformStateError.invalidTime }
        return try encode([
            "localDateTime": format.string(from: date), "weekday": weekdays[weekday - 1],
            "timeZone": zone.identifier,
        ])
    }
    func power() throws -> Data {
        var fields: [String: Any] = [
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "batteryLevel": NSNull(), "batteryState": "unknown",
        ]
        #if os(iOS)
            let device = UIDevice.current
            let level = device.batteryLevel
            if level.isFinite, (0...1).contains(level) { fields["batteryLevel"] = Double(level) }
            switch device.batteryState {
            case .unknown: break
            case .unplugged: fields["batteryState"] = "unplugged"
            case .charging: fields["batteryState"] = "charging"
            case .full: fields["batteryState"] = "full"
            @unknown default: break
            }
        #endif
        return try Self.encode(fields)
    }
    func thermal() throws -> Data {
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = "nominal"
        case .fair: state = "fair"
        case .serious: state = "serious"
        case .critical: state = "critical"
        @unknown default: state = "unknown"
        }
        return try Self.encode(["state": state])
    }
    func locale() throws -> Data {
        let locale = Locale.current
        return try Self.encode([
            "identifier": locale.identifier, "preferredLanguage": Locale.preferredLanguages.first as Any? ?? NSNull(),
            "region": locale.region?.identifier as Any? ?? NSNull(),
        ])
    }
    func accessibility() throws -> Data {
        #if os(iOS)
            return try Self.encode([
                "voiceOver": UIAccessibility.isVoiceOverRunning,
                "reduceMotion": UIAccessibility.isReduceMotionEnabled,
                "closedCaptions": UIAccessibility.isClosedCaptioningEnabled,
                "monoAudio": UIAccessibility.isMonoAudioEnabled,
            ])
        #else
            return try Self.encode([
                "voiceOver": NSNull(), "reduceMotion": NSNull(),
                "closedCaptions": NSNull(), "monoAudio": NSNull(),
            ])
        #endif
    }
}
