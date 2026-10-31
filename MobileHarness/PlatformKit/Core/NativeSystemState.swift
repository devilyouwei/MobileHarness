import Foundation

#if os(iOS)
    import UIKit
    import AVFAudio
#endif

/// Native facts only. Source selection and model-context envelopes belong to the caller.
public enum PlatformStateSource: String, CaseIterable, Sendable {
    case time, power, thermal, network, permissions, audio, locale, accessibility

    /// Producer-owned schema classification, independent of any consumer's disclosure policy.
    var stateFields: (business: Set<String>, runtime: Set<String>) {
        switch self {
        case .time: (["localDateTime", "weekday", "timeZone"], [])
        case .power: (["lowPowerMode", "batteryLevel", "batteryState"], [])
        case .thermal: (["state"], [])
        case .network: (["status", "interfaces", "expensive", "constrained"], ["observedAt"])
        case .permissions: (["camera", "photosAddOnly", "photosReadWrite", "microphone", "bluetooth"], [])
        case .audio: (["inputs", "outputs", "inputMuted", "interrupted"], [])
        case .locale: (["identifier", "preferredLanguage", "region"], [])
        case .accessibility: (["voiceOver", "reduceMotion", "closedCaptions", "monoAudio"], [])
        }
    }
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

/// One owner, one value per source. Reads never invoke the native sampler.
@MainActor final class NativeStateCollection {
    enum Phase: String, CaseIterable { case awaitingFirstObservation, observing }
    static let permissionsDidChange = Notification.Name("MobileHarness.Platform.permissionsDidChange")
    private let notificationCenter: NotificationCenter
    private let clockInterval: TimeInterval?
    init(notificationCenter: NotificationCenter = .default, clockInterval: TimeInterval? = 1) {
        self.notificationCenter = notificationCenter
        self.clockInterval = clockInterval
    }
    private var values: [PlatformStateSource: Result<Data, any Error>] = [:]
    private var sample: ((PlatformStateSource) throws -> Data)?
    private var generation: UUID?
    private var observers: [NSObjectProtocol] = []
    private var clock: Timer?
    private var pending: Set<PlatformStateSource> = []
    private var refreshTask: Task<Void, Never>?

    isolated deinit {
        clock?.invalidate()
        for observer in observers { notificationCenter.removeObserver(observer) }
        refreshTask?.cancel()
    }

    func start(sample: @escaping (PlatformStateSource) throws -> Data) {
        guard generation == nil else { return }
        let generation = UUID()
        self.generation = generation
        self.sample = sample
        // Register before the synchronous baseline. All mutation is serialized on MainActor.
        for (name, sources) in Self.notifications {
            observers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.enqueue(sources, generation: generation) }
                })
        }
        if let clockInterval {
            let clock = Timer(timeInterval: clockInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh([.time], generation: generation) }
            }
            self.clock = clock
            RunLoop.main.add(clock, forMode: .common)
        }
        refresh(Set(PlatformStateSource.allCases).subtracting([.network]), generation: generation)
    }

    func snapshot(_ source: PlatformStateSource) throws -> Data {
        guard generation != nil, let value = values[source] else { throw PlatformError.unavailable }
        return try value.get()
    }

    /// Fence first; the caller joins the returned coalesced worker during native cleanup.
    func invalidate() -> Task<Void, Never>? {
        generation = nil
        clock?.invalidate()
        clock = nil
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        let task = refreshTask
        task?.cancel()
        refreshTask = nil
        pending.removeAll()
        values.removeAll()
        sample = nil
        return task
    }

    private func enqueue(_ sources: Set<PlatformStateSource>, generation: UUID) {
        guard self.generation == generation else { return }
        pending.formUnion(sources)
        guard refreshTask == nil else { return }
        // Coalesce notifications; no unbounded queue or task per event.
        refreshTask = Task { [weak self] in
            await Task.yield()
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            let sources = self.pending
            self.pending.removeAll()
            self.refreshTask = nil
            self.refresh(sources, generation: generation)
        }
    }

    private func refresh(_ sources: Set<PlatformStateSource>, generation: UUID) {
        guard self.generation == generation, let sample else { return }
        for source in sources {
            values[source] = Result {
                let data = try sample(source)
                guard data.count <= 8192 else { throw PlatformStateError.invalidSnapshot }
                return data
            }
        }
    }

    private static var notifications: [(Notification.Name, Set<PlatformStateSource>)] {
        var notifications: [(Notification.Name, Set<PlatformStateSource>)] = [
            (permissionsDidChange, [.permissions]),
            (.NSProcessInfoPowerStateDidChange, [.power]),
            (ProcessInfo.thermalStateDidChangeNotification, [.thermal]),
            (NSLocale.currentLocaleDidChangeNotification, [.locale]),
            (.NSSystemTimeZoneDidChange, [.time]),
        ]
        #if os(iOS)
            let nativeNotifications: [(Notification.Name, Set<PlatformStateSource>)] = [
                (UIDevice.batteryLevelDidChangeNotification, [.power]),
                (UIDevice.batteryStateDidChangeNotification, [.power]),
                (UIApplication.significantTimeChangeNotification, [.time]),
                (UIAccessibility.voiceOverStatusDidChangeNotification, [.accessibility]),
                (UIAccessibility.reduceMotionStatusDidChangeNotification, [.accessibility]),
                (UIAccessibility.closedCaptioningStatusDidChangeNotification, [.accessibility]),
                (UIAccessibility.monoAudioStatusDidChangeNotification, [.accessibility]),
                (AVAudioSession.routeChangeNotification, [.audio]),
                (AVAudioSession.interruptionNotification, [.audio]),
                (AVAudioSession.mediaServicesWereResetNotification, [.audio]),
                (AVAudioSession.mediaServicesWereLostNotification, [.audio]),
                (AVAudioApplication.inputMuteStateChangeNotification, [.audio]),
            ]
            notifications.append(contentsOf: nativeNotifications)
        #endif
        return notifications
    }
}
