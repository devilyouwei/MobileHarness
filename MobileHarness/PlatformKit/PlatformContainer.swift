import Foundation
import Synchronization

/// A synchronous fence shared by native owners; closing it never asserts physical completion.
public final class PlatformAdmission: Sendable {
    private let open = Mutex(false)
    private let failure: @Sendable (String, String, any Error) -> Void
    public init(onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }) {
        failure = onFailure
    }
    @discardableResult public func report(
        _ component: String, _ operation: String, _ error: any Error,
        fileID: String = #fileID, function: String = #function, line: UInt = #line
    ) -> PlatformFailure {
        let value = PlatformFailure(
            component: component, operation: operation, underlying: error,
            fileID: fileID, function: function, line: line)
        failure(value.component, value.operation, value)
        return value
    }
    public var isOpen: Bool { open.withLock { $0 } }
    public func check() throws { guard open.withLock({ $0 }) else { throw PlatformError.unavailable } }
    func setOpen(_ value: Bool) { open.withLock { $0 = value } }
}

/// App-owned native root. Construction/start have no permission or capture effects.
@MainActor
public final class PlatformContainer: PlatformStateReading {
    public let audio: AudioContainer
    public let vision: VisionContainer
    public let connectivity: ConnectivityContainer
    private let admission: PlatformAdmission
    private let systemState: NativeSystemState
    private let stateCollection = NativeStateCollection()
    private var rootFailure: PlatformFailure?
    private var started = false
    private var stopped = false
    private var cleanupJoined = false
    private var foregroundRevision = UUID()
    private var suspension: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    public init(
        makeConnectivity: @MainActor (PlatformAdmission) -> ConnectivityContainer = {
            ConnectivityContainer(admission: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }
    ) {
        let admission = PlatformAdmission(onFailure: onFailure)
        self.admission = admission
        systemState = NativeSystemState(now: now, timeZone: timeZone)
        audio = AudioContainer(admission: admission)
        vision = VisionContainer(admission: admission)
        connectivity = makeConnectivity(admission)
    }
    public func stateSnapshot() async throws -> PlatformStateSnapshot {
        try Task.checkCancellation()
        return PlatformStateSnapshot(
            path: "platform",
            runtime: [
                "started": .flag(started), "stopped": .flag(stopped), "cleanupJoined": .flag(cleanupJoined),
                "available": .flag(isAvailable),
            ], health: rootFailure == nil ? .unknown : .fault,
            issues: rootFailure.map { [.init(code: $0.code.rawValue, impact: "nativeCapabilityUnavailable")] } ?? [],
            children: ["platform.audio", "platform.vision", "platform.connectivity", "platform.system"].map {
                .init(path: $0)
            })
    }
    public func stateReaders() async throws -> [String: PlatformStateSnapshot.Reader] {
        var readers: [String: PlatformStateSnapshot.Reader] = [
            "platform": PlatformStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "platform.audio": PlatformStateSnapshot.reader(of: audio) { try await $0.stateSnapshot() },
            "platform.vision": PlatformStateSnapshot.reader(of: vision) { try await $0.stateSnapshot() },
            "platform.system": PlatformStateSnapshot.reader(of: self) { root in
                .init(
                    path: "platform.system",
                    children: PlatformStateSource.allCases.map { .init(path: "platform.system." + $0.rawValue) })
            },
        ]
        readers.merge(try await connectivity.stateReaders()) { _, new in new }
        for source in PlatformStateSource.allCases {
            readers["platform.system." + source.rawValue] = PlatformStateSnapshot.reader(of: self) {
                try await $0.systemStateSnapshot(source)
            }
        }
        return readers
    }
    private func systemStateSnapshot(_ source: PlatformStateSource) async throws -> PlatformStateSnapshot {
        let path = "platform.system." + source.rawValue
        guard isAvailable else { return .init(path: path, runtime: ["available": .flag(false)]) }
        let data = try snapshot(source)
        let facts = try JSONDecoder().decode([String: PlatformStateSnapshot.Value].self, from: data)
        let fields = source.stateFields
        guard Set(facts.keys) == fields.business.union(fields.runtime) else { throw PlatformStateError.invalidSnapshot }
        let thermal = source == .thermal ? facts["state"] : nil
        let limited = thermal == .text("serious") || thermal == .text("critical")
        let phase: NativeStateCollection.Phase =
            source == .network && facts["observedAt"] == .unknown ? .awaitingFirstObservation : .observing
        return .init(
            path: path, business: facts.filter { fields.business.contains($0.key) },
            runtime: facts.filter { fields.runtime.contains($0.key) }.merging([
                "collectionPhase": .text(phase.rawValue)
            ]) { current, _ in current }, health: limited ? .limited : .unknown,
            issues: limited ? [.init(code: "thermalPressure", impact: "systemPerformanceLimited")] : [],
            meanings: ["runtime.collectionPhase": "Observation readiness; not device connection or action readiness"],
            stateValues: ["runtime.collectionPhase": NativeStateCollection.Phase.allCases.map(\.rawValue)])
    }
    public var isAvailable: Bool { admission.isOpen }
    public func start() throws(PlatformFailure) {
        do {
            guard !stopped else { throw PlatformError.stopped }
            guard !started else { return }
            started = true
            startStateObservation()
            admission.setOpen(true)
        } catch {
            let failure = admission.report("root", "start", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
        }
    }
    public func invalidate() {
        foregroundRevision = UUID()
        admission.setOpen(false)
        let stateRefresh = stateCollection.invalidate()
        systemState.stop()
        audio.invalidateStateObservation()
        connectivity.invalidateStateObservation()
        guard suspension == nil else { return }
        suspension = Task { [audio, vision, connectivity] in
            await stateRefresh?.value
            var errors: [any Error] = []
            async let connections: Void = connectivity.stop()
            #if os(iOS)
                async let sound: Void = audio.stop()
                async let image: Void = vision.stop()
                do { try await sound } catch { errors.append(error) }
                await image
            #endif
            do { try await connections } catch { errors.append(error) }
            if let primary = errors.first {
                throw PlatformFailure(
                    component: "root", operation: "invalidate", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
    public func setForeground(_ active: Bool) async throws(PlatformFailure) {
        do {
            if !active { invalidate() }
            let revision = foregroundRevision
            try await suspension?.value
            if active {
                guard revision == foregroundRevision else { return }
                guard started, !stopped else { throw PlatformError.stopped }
                suspension = nil
                startStateObservation()
                admission.setOpen(true)
            }
        } catch {
            let failure = admission.report("root", "setForeground", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
        }
    }
    public func stop() async throws(PlatformFailure) {
        do {
            if let shutdown { return try await shutdown.value }
            stopped = true
            invalidate()
            let suspension = suspension
            let task = Task { if let suspension { try await suspension.value } }
            shutdown = task
            try await task.value
            cleanupJoined = true
        } catch {
            let failure = admission.report("root", "stop", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
        }
    }
    private func startStateObservation() {
        systemState.start()
        audio.startStateObservation()
        connectivity.startStateObservation()
        stateCollection.start { [weak self] source in
            guard let self else { throw PlatformError.stopped }
            return try self.sampleNativeState(source)
        }
        audio.readMicrophoneAuthorization = { [weak self] in
            try self?.permissions()["microphone"] ?? "unknown"
        }
        vision.readAuthorization = { [weak self] in
            let fields = try self?.permissions() ?? [:]
            return ["camera", "photosAddOnly", "photosReadWrite"].reduce(into: [:]) {
                $0[$1] = fields[$1] ?? "unknown"
            }
        }
        connectivity.readBluetoothAuthorization = { [weak self] in
            try self?.permissions()["bluetooth"] ?? "unknown"
        }
    }
    private func permissions() throws -> [String: String] {
        guard isAvailable else { return [:] }
        let data = try stateCollection.snapshot(.permissions)
        let facts = try JSONDecoder().decode([String: String].self, from: data)
        guard Set(facts.keys) == PlatformStateSource.permissions.stateFields.business else {
            throw PlatformStateError.invalidSnapshot
        }
        return facts
    }
    public func snapshot(_ source: PlatformStateSource) throws -> Data {
        try admission.check()
        if source == .network { return try connectivity.networkSnapshot() }
        return try stateCollection.snapshot(source)
    }
    private func sampleNativeState(_ source: PlatformStateSource) throws -> Data {
        switch source {
        case .time: return try systemState.time()
        case .power: return try systemState.power()
        case .thermal: return try systemState.thermal()
        case .network: return try connectivity.networkSnapshot()
        case .audio: return try audio.systemSnapshot()
        case .locale: return try systemState.locale()
        case .accessibility: return try systemState.accessibility()
        case .permissions:
            var fields = NativeVisionAuthorization.snapshot()
            fields["microphone"] = NativeAudioState.microphoneAuthorization
            fields["bluetooth"] = NativeNetworkState.bluetoothAuthorization
            return try NativeSystemState.encode(fields)
        }
    }
}

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct PlatformStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> PlatformStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> PlatformStateSnapshot
    ) -> Reader {
        { [weak owner] in
            try Task.checkCancellation()
            guard let owner else { throw ReadError.ownerReleased }
            return try await read(owner)
        }
    }
    public indirect enum Value: Codable, Sendable, Equatable {
        case text(String)
        case flag(Bool)
        case count(Int)
        case unsigned(UInt64)
        case number(Double)
        case integers([Int])
        case texts([String])
        case object([String: Value])
        case array([Value])
        case unknown
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .unknown
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let count = try? value.decode(Int.self) {
                self = .count(count)
            } else if let unsigned = try? value.decode(UInt64.self) {
                self = .unsigned(unsigned)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else if let integers = try? value.decode([Int].self) {
                self = .integers(integers)
            } else if let texts = try? value.decode([String].self) {
                self = .texts(texts)
            } else if let object = try? value.decode([String: Value].self) {
                self = .object(object)
            } else if let array = try? value.decode([Value].self) {
                self = .array(array)
            } else {
                self = .text(try value.decode(String.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let item): try value.encode(item)
            case .flag(let item): try value.encode(item)
            case .count(let item): try value.encode(item)
            case .unsigned(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .integers(let item): try value.encode(item)
            case .texts(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .unknown: try value.encodeNil()
            }
        }
    }
    public enum Health: String, Codable, Sendable { case healthy, limited, fault, unknown }
    public struct Issue: Codable, Sendable {
        public let code: String
        public let impact: String
        public init(code: String, impact: String) {
            self.code = code
            self.impact = impact
        }
    }
    public struct Descriptor: Codable, Sendable {
        public let path: String
        public let business: [String]
        public let runtime: [String]
        public let children: [Reference]
        public let meanings: [String: String]
        public let units: [String: String]
        public let stateValues: [String: [String]]
    }
    public let path: String
    public let business: [String: Value]
    public let runtime: [String: Value]
    public let health: Health
    public let issues: [Issue]
    public let children: [Reference]
    /// Collection time only; measurement age belongs to the owning business fact.
    public let collectedAt: Date
    public let meanings: [String: String]
    public let units: [String: String]
    public let stateValues: [String: [String]]
    public var stateDescriptor: Descriptor {
        Descriptor(
            path: path, business: business.keys.sorted(), runtime: runtime.keys.sorted(),
            children: children, meanings: meanings, units: units,
            stateValues: stateValues.merging(["health": ["healthy", "limited", "fault", "unknown"]]) { current, _ in
                current
            })
    }
    public init(
        path: String, business: [String: Value] = [:], runtime: [String: Value] = [:],
        health: Health = .unknown, issues: [Issue] = [], children: [Reference] = [],
        meanings: [String: String] = [:], units: [String: String] = [:], stateValues: [String: [String]] = [:]
    ) {
        self.path = path
        self.meanings = meanings
        self.units = units
        self.stateValues = stateValues
        self.business = business
        self.runtime = runtime
        self.health = health
        self.issues = issues
        self.children = children
        collectedAt = Date()
    }
}
