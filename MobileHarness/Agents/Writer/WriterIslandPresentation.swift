import Foundation
import UI

/// Writer owns task facts; the Island component owns selection, layout and animation.
/// One immutable in-flight publication and one replaceable latest value, independent of reports.
actor WriterIslandPresentation {
    enum Phase: String, Sendable {
        case starting, running, waitingUser, paused, cancelling, completed, failed, cancelled, interrupted
        var title: String {
            switch self {
            case .starting: "准备创作"
            case .running: "正在创作"
            case .waitingUser: "等待补充"
            case .paused: "已暂停"
            case .cancelling: "正在取消"
            case .completed: "已完成"
            case .failed: "执行失败"
            case .cancelled: "已取消"
            case .interrupted: "已中断"
            }
        }
        var terminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    }
    typealias Sender = AgentIslandPublication.Sender
    private let publication = AgentIslandPublication()
    private var runID: String?
    private var goal = ""
    private var phase = Phase.starting
    private var step = ""
    var lastFailure: String? { get async { await publication.lastFailure } }
    func bind(_ sender: @escaping Sender) async { await publication.bind(sender) }
    func start() async { await publication.start() }
    func begin(runID: String, goal: String) async {
        self.runID = runID
        self.goal = goal
        phase = .starting
        step = "已接纳委托，正在准备作品窗口。"
        await enqueue()
    }
    func update(runID: String, phase: Phase, step: String? = nil) async {
        guard self.runID == runID, !self.phase.terminal else { return }
        self.phase = phase
        if let step { self.step = step }
        await enqueue()
    }
    private func enqueue() async {
        guard let runID else { return }
        await publication.submit(
            phase.terminal ? nil : Self.content(runID: runID, goal: goal, phase: phase, step: step))
    }
    static func content(runID: String, goal: String, phase: Phase, step: String) -> IslandContent {
        let stage = phase == .waitingUser ? phase.rawValue : "active"
        return IslandContent(
            title: String(("Writer · " + goal).prefix(80)),
            subtitle: phase.title, primary: .symbol(name: "pencil.and.outline"), tone: .purple,
            priority: phase == .waitingUser ? .attention : .high,
            secondary: phase == .waitingUser || phase == .paused ? nil : .loading,
            liveActivity: true, expansionID: runID + ":" + stage,
            detail: .init(
                text: String(
                    ("Writer · " + phase.title + " · " + String(goal.prefix(100)) + "\n" + String(step.prefix(180)))
                        .prefix(320))))
    }
    func stop() async { await publication.stop() }
}
