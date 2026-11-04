import Foundation
import Observation
import UI

/// Projects already-owned display facts; never samples devices or interprets execution-log Actions.
/// One newest wake-up slot, three latest Action commands, one observer and one joined expiration/retry timer.
@MainActor public final class IslandDomainPresentation {
    private let service: any IslandDomainPresenting
    private let home: UIHomeContainer
    private let camera: CameraState
    private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var clock: Task<Void, Never>?
    private var timerDeadline: Date?
    private var bluetooth: BluetoothConnectionStatus?
    private var bluetoothUntil: Date?
    private var generation: UUID?
    private var listeningStartedAt: Date?
    public init(service: any IslandDomainPresenting, home: UIHomeContainer, camera: CameraState) {
        self.service = service
        self.home = home
        self.camera = camera
    }
    private struct Snapshot {
        let generation: UUID
        let contents: [(IslandDomain, IslandContent?)]
        let spectrum: [Float]
        let speaking: Bool
    }
    private struct Publication {
        let id = UUID()
        let actions: any IslandActionCalling
        var revision: UInt64 = 0
        var desired: IslandContent?
        var pending: IslandCommand?
        mutating func prepare(_ content: IslandContent?) throws {
            guard content != desired else { return }
            revision += 1
            pending = try IslandCommand(
                operation: content == nil ? .end : .present, id: id, revision: revision, content: content)
            desired = content
        }
    }
    private var publications: [IslandDomain: Publication] = [:]
    private var retryAt: Date?
    private var worker: Task<Void, Never>?
    private var stopped = false
    public func run() async {
        guard !stopped, worker == nil else { return }
        let task = Task { await observe() }
        worker = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        worker = nil
    }
    private func observe() async {
        wake.continuation.yield(())
        for await _ in wake.stream {
            if Task.isCancelled { break }
            let signal = wake.continuation
            let snapshot = withObservationTracking {
                capture()
            } onChange: {
                signal.yield(())
            }
            if let snapshot { await publish(snapshot) }
            if Task.isCancelled { break }
            await armTimer()
        }
        clock?.cancel()
        await clock?.value
        clock = nil
    }
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        wake.continuation.finish()
        worker?.cancel()
        await worker?.value
        clock?.cancel()
        await clock?.value
        clock = nil
        // Root workers are joined before their bound Action endpoints are retired.
        if service.islandAvailable, generation == service.islandGeneration {
            for domain in IslandDomain.allCases {
                guard var entry = publications[domain], entry.revision > 0 else { continue }
                entry.revision += 1
                do {
                    let command = try IslandCommand(operation: .end, id: entry.id, revision: entry.revision)
                    _ = try await entry.actions.perform(command)
                } catch { service.reportIslandFailure(error) }
            }
        }
        publications.removeAll()
    }
    private func armTimer() async {
        let now = Date()
        let deadlines = service.islandAvailable ? [bluetoothUntil, retryAt].compactMap { $0 } : []
        if deadlines.contains(where: { $0 <= now }) { wake.continuation.yield(()) }
        let future = deadlines.filter { $0 > now }.min()
        guard future != timerDeadline else { return }
        timerDeadline = future
        clock?.cancel()
        await clock?.value
        clock = nil
        guard let future else { return }
        let signal = wake.continuation
        clock = Task {
            do { try await Task.sleep(for: .seconds(max(0, future.timeIntervalSinceNow))) } catch { return }
            if !Task.isCancelled { signal.yield(()) }
        }
    }
    /// Read all observable facts synchronously; Action side effects are outside observation tracking.
    private func capture() -> Snapshot? {
        guard service.islandAvailable else { return nil }
        let current = service.islandGeneration
        if generation != current {
            generation = current
            publications.removeAll()
            retryAt = nil
            bluetooth = home.conversation.bluetoothStatus
            bluetoothUntil = nil
            listeningStartedAt = nil
        }
        let phase = home.conversation.voicePhase
        if phase == .listening {
            if listeningStartedAt == nil { listeningStartedAt = Date() }
        } else {
            listeningStartedAt = nil
        }
        return Snapshot(
            generation: current,
            contents: [
                (.bluetooth, bluetoothContent()), (.camera, Self.cameraContent(camera)),
                (.voice, Self.voiceContent(phase, startedAt: listeningStartedAt ?? Date())),
            ], spectrum: home.conversation.playbackSpectrum, speaking: phase == .speaking)
    }
    private func publish(_ snapshot: Snapshot) async {
        retryAt = nil
        for (domain, content) in snapshot.contents {
            guard !Task.isCancelled, service.islandAvailable, service.islandGeneration == snapshot.generation else {
                return
            }
            var entry = publications[domain] ?? Publication(actions: service.islandActions(for: domain))
            do {
                try entry.prepare(content)
                publications[domain] = entry
                guard let command = entry.pending else { continue }
                _ = try await entry.actions.perform(command)
                publications[domain]?.pending = nil
            } catch {
                if Task.isCancelled { return }
                guard service.islandGeneration == snapshot.generation else { return }
                service.reportIslandFailure(error)
                retryAt = Date().addingTimeInterval(0.5)
            }
        }
        guard !Task.isCancelled, service.islandGeneration == snapshot.generation else { return }
        do { try service.publishSpectrum(snapshot.spectrum, active: snapshot.speaking) } catch {
            service.reportIslandFailure(error)
        }
    }
    private func bluetoothContent() -> IslandContent? {
        let value = home.conversation.bluetoothStatus
        if bluetooth != value {
            bluetooth = value
            bluetoothUntil = Date().addingTimeInterval(3)
        }
        let temporary = (bluetoothUntil ?? .distantPast) > Date()
        if !temporary { bluetoothUntil = nil }
        if value == .disconnected && !temporary { return nil }
        return .init(
            title: "蓝牙", subtitle: value.title,
            primary: .symbol(
                name: value.isConnecting ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"),
            tone: value == .disconnected ? .warning : .blue, priority: temporary ? .high : .background,
            secondary: value.isConnecting ? .loading : nil)
    }
    public static func voiceContent(_ phase: VoicePhase, startedAt: Date = Date()) -> IslandContent? {
        switch phase {
        case .listening:
            .init(
                title: "正在聆听", primary: .symbol(name: "mic.fill", effect: .pulse), tone: .blue, priority: .normal,
                secondary: .elapsed(startedAt: startedAt))
        case .speaking:
            .init(
                title: "正在说话", primary: .symbol(name: "speaker.wave.2.fill"), tone: .blue, priority: .high,
                secondary: .spectrum)
        case .processing:
            .init(title: "正在思考", primary: .symbol(name: "sparkles"), priority: .low, secondary: .loading)
        case .idle, .loading, .failed: nil
        }
    }
    public static func cameraContent(_ camera: CameraState) -> IslandContent? {
        if let remaining = camera.countdown {
            return .init(
                title: "拍照倒计时", subtitle: "\(remaining) 秒", primary: .symbol(name: "timer"), priority: .critical,
                secondary: .progress(1 / Double(max(1, remaining))),
                liveActivity: true)
        }
        if camera.photoBusy {
            return .init(
                title: "正在处理照片", primary: .symbol(name: "camera.aperture"), priority: .critical, secondary: .loading)
        }
        let recording = camera.recording
        if recording.active {
            let title = recording.phase == .starting ? "正在启动录像" : recording.phase == .finishing ? "录像正在收尾" : "正在录像"
            return .init(
                title: title, subtitle: "聆听已暂停", primary: .symbol(name: "video.fill"), tone: .recording,
                priority: .attention,
                secondary: recording.phase == .recording
                    ? .symbol(name: "record.circle.fill", effect: .pulse) : .loading,
                startedAt: recording.phase == .recording ? recording.startedAt : nil,
                liveActivity: true)
        }
        if camera.recordedVideo != nil {
            return .init(
                title: "录像待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "video"), priority: .high)
        }
        #if os(iOS)
            if camera.capturedPhoto != nil {
                return .init(
                    title: "照片待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "photo"), priority: .high)
            }
        #endif
        return nil
    }
}
