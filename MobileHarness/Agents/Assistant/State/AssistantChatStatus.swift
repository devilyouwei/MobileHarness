import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func hasReplyWork(sessionID: String) -> Bool {
        activeInput?.sessionID == sessionID
            || pendingRounds.values.contains { $0.input.sessionID == sessionID && !$0.cancelled }
    }

    func hasActiveReply(sessionID: String) async -> Bool {
        guard lifecycle == .running else { return false }
        if hasReplyWork(sessionID: sessionID) { return true }
        let playing = await speechOutput?.isPlaying(sessionID: sessionID)
        return lifecycle == .running && (hasReplyWork(sessionID: sessionID) || playing == true)
    }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }

    /// Passive State reflection, independent of persistence initialization.
    public func residentContext() async -> AgentContext<State>? {
        await contextRepository.residentSnapshot()
    }

    /// The variables currently loaded into the prompt: the Agent's own, plus the container paths of loaded Skills.
    public func stateVariables() async -> [StateVariableItem] {
        guard let context = await contextRepository.residentSnapshot() else { return [] }
        let schema = try? AgentConfigurations.stateSchema(named: State.configurationName)
        let visible = context.state.visibleVariables(session: nil)
        let prefix = "agents." + descriptor.id.rawValue + "."
        var items: [StateVariableItem] = []
        for declaration in schema?.declarations.values ?? [:].values {
            let entry = visible.entries[declaration.name]
            var value = entry?.value
            if declaration.name == "listening", let listening = value {
                let fields: [String: Any] = [
                    "listening": listening == "true",
                    "wakeCondition": context.state.listeningWakeCondition as Any? ?? NSNull(),
                ]
                value = (try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            items.append(
                .init(
                    path: prefix + declaration.name, category: declaration.access == .readOnly ? .readOnly : .readWrite,
                    value: value, writtenAt: entry?.writtenAt))
        }
        for (name, entry) in visible.entries where schema?.declarations[name] == nil {
            items.append(
                .init(path: prefix + name, category: .semantic, value: entry.value, writtenAt: entry.writtenAt))
        }
        guard usesSkills, let stateContext,
            let names = try? AgentSkillLoader.useStates(context.state.skillState?.loaded ?? [])
        else { return items }
        let session = "state-display"
        guard (try? stateContext.open(session: session)) != nil else { return items }
        defer { stateContext.close(session: session) }
        for name in names {
            if stateContext.isMedia(name) {
                items.append(.init(path: name, category: .image, value: nil))
                continue
            }
            let text = try? await stateContext.snapshot(session: session, names: [name])
            let fields =
                (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])?[name]
            let rendered = fields.flatMap {
                try? JSONSerialization.data(
                    withJSONObject: $0, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
            }
            items.append(
                .init(
                    path: name, category: .container,
                    value: rendered.map { String(decoding: $0, as: UTF8.self) }))
        }
        return items
    }

    public func contextSnapshot() async throws -> AgentContext<State> {
        try await contextRepository.snapshot()
    }
    public func effectiveCapabilities(for id: String) throws -> CapabilityRegistry? {
        guard usesSkills else { return nil }
        if let parked = pendingRounds[id] {
            guard !parked.cancelled, let catalog = parked.catalog else { throw CommunicationError.scopeClosed }
            return catalog
        }
        guard id == roundID, let requestCatalog else { throw CommunicationError.scopeClosed }
        return requestCatalog
    }

    public func actionResults() -> [ActionResult] { resultInbox.results }
}
