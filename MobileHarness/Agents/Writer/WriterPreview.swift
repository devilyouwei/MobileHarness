import Foundation

/// Writer-owned presentation work: one in flight plus one replaceable pending update.
actor WriterPreview {
    private let present: @Sendable () async throws -> String
    private let observed: @Sendable (String) async -> Void
    private var worker: Task<Void, Never>?
    private var pending = false
    private var stopped = false
    private var unavailable = false
    private var sceneActive = true
    private var epoch = UUID()
    private var reported = false
    private(set) var failure: String?
    init(present: @escaping @Sendable () async throws -> String, observed: @escaping @Sendable (String) async -> Void) {
        self.present = present
        self.observed = observed
    }
    func changed() {
        guard !stopped, !unavailable else { return }
        pending = true
        guard sceneActive, worker == nil else { return }
        let token = epoch
        worker = Task { await pump(token) }
    }
    func setSceneActive(_ active: Bool) async {
        guard sceneActive != active else { return }
        sceneActive = active
        if !active {
            let refresh = pending || worker != nil
            await settle()
            pending = pending || refresh
            if sceneActive, pending { changed() }
        } else if pending {
            changed()
        }
    }
    private func pump(_ token: UUID) async {
        defer { if epoch == token { worker = nil } }
        do {
            try await Task.sleep(for: .milliseconds(750))
            while pending, !stopped, epoch == token {
                pending = false
                do {
                    let value = try await present()
                    try Task.checkCancellation()
                    guard epoch == token else { return }
                    let fields = try? JSONDecoder().decode([String: String].self, from: Data(value.utf8))
                    if fields?["status"] == "unavailable", fields?["reason"] != "minimized" {
                        unavailable = true
                        pending = false
                        return
                    }
                    failure = nil
                    if fields?["status"] == "preview", !(fields?["text"] ?? "").isEmpty, !reported {
                        reported = true
                        await observed("初稿已显示，正在继续生成。")
                    }
                } catch {
                    if Task.isCancelled { return }
                    failure = String(describing: error)
                    await observed("预览暂不可用，文件生成继续。")
                    // No presentation retry loop. A later source change may retry.
                }
                if pending { try await Task.sleep(for: .milliseconds(750)) }
            }
        } catch {}
    }
    /// At a completed step, join the latest already scheduled source checkpoint.
    /// No mutation means no reload; streaming intake never calls this barrier.
    func flush() async {
        let active = worker
        await active?.value
    }
    func settle() async {
        pending = false
        let old = worker
        epoch = UUID()
        worker = nil
        old?.cancel()
        await old?.value
    }
    func resetForWorkspace() async {
        await settle()
        unavailable = false
        reported = false
        failure = nil
    }
    func stop() async {
        stopped = true
        await settle()
    }
}
