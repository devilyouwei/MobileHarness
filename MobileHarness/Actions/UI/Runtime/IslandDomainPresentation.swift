import Foundation
import Observation
import UI

/// Projects already-owned display facts; never samples devices or interprets execution-log Actions.
/// One newest wake-up slot, one observer worker and one joined expiration timer.
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
    private var running = false
    private var listeningStartedAt: Date?
    public init(service: any IslandDomainPresenting, home: UIHomeContainer, camera: CameraState) {
        self.service = service
        self.home = home
        self.camera = camera
    }
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        wake.continuation.yield(())
        for await _ in wake.stream {
            if Task.isCancelled { break }
            let signal = wake.continuation
            withObservationTracking {
                refresh()
            } onChange: {
                signal.yield(())
            }
            await armTimer()
        }
        clock?.cancel()
        await clock?.value
        clock = nil
    }
    public func stop() async {
        wake.continuation.finish()
        clock?.cancel()
        await clock?.value
        clock = nil
    }
    private func armTimer() async {
        let future = bluetoothUntil.flatMap { $0 > Date() ? $0 : nil }
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
    private func refresh() {
        guard service.islandAvailable else { return }
        if generation != service.islandGeneration {
            generation = service.islandGeneration
            bluetooth = home.conversation.bluetoothStatus
            bluetoothUntil = nil
            listeningStartedAt = nil
        }
        do {
            try bluetoothContent()
            try taskContent()
            try service.publishDomain("camera", content: Self.cameraContent(camera))
            let phase = home.conversation.voicePhase
            if phase == .listening {
                if listeningStartedAt == nil { listeningStartedAt = Date() }
            } else {
                listeningStartedAt = nil
            }
            try service.publishDomain(
                "voice", content: Self.voiceContent(phase, startedAt: listeningStartedAt ?? Date()))
            try service.publishSpectrum(home.conversation.playbackSpectrum, active: phase == .speaking)
        } catch { service.reportIslandFailure(error) }
    }
    private func bluetoothContent() throws {
        let value = home.conversation.bluetoothStatus
        if bluetooth != value {
            bluetooth = value
            bluetoothUntil = Date().addingTimeInterval(3)
        }
        let temporary = (bluetoothUntil ?? .distantPast) > Date()
        if value == .disconnected && !temporary {
            try service.publishDomain("bluetooth", content: nil)
            return
        }
        try service.publishDomain(
            "bluetooth",
            content: .init(
                title: "蓝牙", subtitle: value.title,
                primary: .symbol(
                    name: value.isConnecting ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"),
                tone: value == .disconnected ? .warning : .blue, rank: temporary ? 70 : 0,
                secondary: value.isConnecting ? .loading : nil))
    }
    private func taskContent() throws {
        let state = home.activity
        let active = state.tasks.filter { !$0.isTerminal }
        let current = state.currentTaskID.flatMap { id in
            state.tasks.first { $0.id == id }
        }
        let currentID = current?.isTerminal == true ? nil : state.currentTaskID
        guard let key = currentID ?? active.first?.id else {
            try service.publishDomain("task", content: nil)
            return
        }
        let item = active.first { $0.id == key }
        let title =
            currentID != nil && !state.currentTaskTitle.isEmpty
            ? state.currentTaskTitle : item?.title ?? "任务进行中"
        let rawStatus =
            currentID != nil && !state.currentTaskStatus.isEmpty
            ? state.currentTaskStatus : item?.phase.rawValue ?? "正在执行"
        let status = Self.taskStatus(rawStatus)
        let additional = active.filter { $0.id != key }.count
        try service.publishDomain(
            "task",
            content: .init(
                title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)).isEmpty
                    ? "任务进行中" : String(title.prefix(80)),
                subtitle: String((status + (additional > 0 ? " · 另有 \(additional) 个任务" : "")).prefix(160)),
                primary: .symbol(name: "scope"), tone: .blue, rank: 85,
                secondary: item?.phase == .waitingUser ? nil : .loading,
                liveActivity: true, expansionID: key,
                detail: .init(text: String(title.prefix(320)))))
    }

    static func taskStatus(_ value: String) -> String {
        switch value {
        case "waitingUser": "等待你的操作"
        case "running", "executing": "正在执行"
        case "pending", "queued": "等待执行"
        case "paused", "suspended": "已暂停"
        case "completed", "succeeded": "已完成"
        case "failed": "执行失败"
        case "cancelled", "canceled": "已取消"
        default: value
        }
    }

    public static func voiceContent(_ phase: VoicePhase, startedAt: Date = Date()) -> IslandContent? {
        switch phase {
        case .listening:
            .init(
                title: "正在聆听", primary: .symbol(name: "mic.fill", effect: .pulse), tone: .blue, rank: 60,
                secondary: .elapsed(startedAt: startedAt))
        case .speaking:
            .init(
                title: "正在说话", primary: .symbol(name: "speaker.wave.2.fill"), tone: .blue, rank: 65,
                secondary: .spectrum)
        case .processing:
            .init(title: "正在思考", primary: .symbol(name: "sparkles"), rank: 55, secondary: .loading)
        case .idle, .loading, .failed: nil
        }
    }
    public static func cameraContent(_ camera: CameraState) -> IslandContent? {
        if let remaining = camera.countdown {
            return .init(
                title: "拍照倒计时", subtitle: "\(remaining) 秒", primary: .symbol(name: "timer"), rank: 100,
                secondary: .progress(1 / Double(max(1, remaining))),
                liveActivity: true)
        }
        if camera.photoBusy {
            return .init(
                title: "正在处理照片", primary: .symbol(name: "camera.aperture"), rank: 100, secondary: .loading)
        }
        let recording = camera.recording
        if recording.active {
            let title = recording.phase == .starting ? "正在启动录像" : recording.phase == .finishing ? "录像正在收尾" : "正在录像"
            return .init(
                title: title, subtitle: "聆听已暂停", primary: .symbol(name: "video.fill"), tone: .recording, rank: 90,
                secondary: recording.phase == .recording
                    ? .symbol(name: "record.circle.fill", effect: .pulse) : .loading,
                startedAt: recording.phase == .recording ? recording.startedAt : nil,
                liveActivity: true)
        }
        if camera.recordedVideo != nil {
            return .init(
                title: "录像待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "video"), rank: 80)
        }
        #if os(iOS)
            if camera.capturedPhoto != nil {
                return .init(
                    title: "照片待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "photo"), rank: 80)
            }
        #endif
        return nil
    }
}
