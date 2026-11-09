import Foundation
import UI

/// Writer owns task facts; the Island component owns selection, layout and animation.
/// One immutable in-flight publication and one replaceable latest value, independent of reports.
actor WriterIslandPresentation {
    enum Phase: String, Sendable {
        case starting, running, waitingUser, paused, cancelling, completed, declined, failed, cancelled, interrupted
        var title: String {
            switch self {
            case .starting: "准备创作"
            case .running: "正在创作"
            case .waitingUser: "等待补充"
            case .paused: "已暂停"
            case .cancelling: "正在取消"
            case .completed: "已完成"
            case .declined: "已拒绝"
            case .failed: "执行失败"
            case .cancelled: "已取消"
            case .interrupted: "已中断"
            }
        }
        var terminal: Bool { [.completed, .declined, .failed, .cancelled, .interrupted].contains(self) }
    }
    typealias Sender = AgentIslandPublication.Sender
    private let publication = AgentIslandPublication()
    private var delegateID: String?
    private var goal = ""
    private var phase = Phase.starting
    private var step = ""
    private var dismissal: Task<Void, Never>?
    private let terminalDuration: Duration

    init(terminalDuration: Duration = .seconds(15)) { self.terminalDuration = terminalDuration }
    var lastFailure: String? { get async { await publication.lastFailure } }
    func bind(_ sender: @escaping Sender) async { await publication.bind(sender) }
    func start() async { await publication.start() }
    func begin(delegateID: String, goal: String) async {
        dismissal?.cancel()
        dismissal = nil
        self.delegateID = delegateID
        self.goal = goal
        phase = .starting
        step = "已接纳委托，正在准备。"
        await enqueue()
    }
    func update(delegateID: String, phase: Phase, step: String? = nil) async {
        guard self.delegateID == delegateID, !self.phase.terminal else { return }
        self.phase = phase
        if let step { self.step = step }
        if phase.terminal {
            dismissal = Task {
                do { try await Task.sleep(for: terminalDuration) } catch { return }
                guard self.delegateID == delegateID else { return }
                self.delegateID = nil
                dismissal = nil
                await publication.submit(nil)
            }
        }
        await enqueue()
    }
    private func enqueue() async {
        guard let delegateID else { return }
        await publication.submit(
            Self.content(delegateID: delegateID, goal: goal, phase: phase, step: step))
    }
    static func content(delegateID: String, goal: String, phase: Phase, step: String) -> IslandContent {
        let stage = phase == .waitingUser || phase.terminal ? phase.rawValue : "active"
        return IslandContent(
            title: String(("Writer · " + goal).prefix(80)),
            subtitle: phase.terminal || phase == .waitingUser ? String(step.prefix(160)) : phase.title,
            primary: .symbol(name: "pencil.and.outline"), tone: .purple,
            priority: phase == .waitingUser || phase.terminal ? .attention : .high,
            secondary: phase == .waitingUser || phase == .paused || phase.terminal ? nil : .loading,
            liveActivity: true, expansionID: delegateID + ":" + stage,
            detail: .init(
                text: String(
                    ("Writer · " + phase.title + " · " + String(goal.prefix(100)) + "\n" + String(step.prefix(180)))
                        .prefix(320))))
    }
    func stop() async {
        dismissal?.cancel()
        await dismissal?.value
        dismissal = nil
        await publication.stop()
    }
}
