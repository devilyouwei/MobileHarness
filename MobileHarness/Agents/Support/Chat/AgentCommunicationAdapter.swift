import AgentCore
import Foundation
import StorageCore

/// Model-only declarations. These paths are intercepted before function execution or validation.
public enum AgentCommunicationAdapter {
    public static func catalog(
        _ functions: CapabilityRegistry, policy: CommunicationDeclaration
    ) throws -> CapabilityRegistry {
        guard !functions.tools.contains(where: { isCommunication($0.path) || $0.alias == "Agent.send" }) else {
            throw CommunicationError.invalidPayload
        }
        guard let registration = functions.actions.first(where: { $0.path.description == "Agent.Communication.send" })
        else { return functions }
        guard registration.alias == "send", registration.defaultChannel == "Communication" else {
            throw CommunicationError.invalidPayload
        }
        var actions = functions.actions.filter { $0.path.description != "Agent.Communication.send" }
        let taskSends = policy.sends.filter { $0.contract.hasPrefix("task.") }
        if !taskSends.isEmpty {
            let required: Set<String> = ["target", "kind", "content"]
            let optional: Set<String> = ["taskID", "artifactID"]
            let grants = Set(taskSends.map { "\($0.target): \($0.contract.dropFirst("task.".count))" }).sorted()
            actions.append(
                ActionRegistration(
                    alias: "send", path: ActionPath(domain: "Agent", module: "Communication", function: "send"),
                    defaultChannel: "Communication", requiredParameters: required, optionalParameters: optional,
                    documentation: try JSONDecoder().decode(
                        CapabilityDocumentation.self,
                        from: JSONSerialization.data(withJSONObject: [
                            "doc": (registration.documentation?.doc ?? "") + "\nAllowed target/kind pairs: "
                                + grants.joined(separator: ", ") + ".",
                            "parameters": (registration.documentation?.parameters ?? []).map {
                                [
                                    "name": $0.name, "valueType": $0.valueType.rawValue,
                                    "required": $0.required, "description": $0.description,
                                    "constraints": $0.constraints,
                                ] as [String: Any]
                            },
                        ]))))
        }
        return try CapabilityRegistry(
            actions: actions, tools: functions.tools, channels: functions.channels,
            internalActions: functions.internalActions, internalTools: functions.internalTools)
    }

    public static func isCommunication(_ path: String) -> Bool {
        ["Agent.Communication.send", "Agent.Communication.publish"].contains(path)
    }

    public static func action(
        path: String, arguments: [String: String], sender: AgentID, input: AgentInput,
        policy: CommunicationDeclaration, existing: AgentTaskScope? = nil
    ) throws -> (CommunicationAction, AgentTaskSignal) {
        guard isCommunication(path),
            Set(arguments.keys).isSubset(of: ["target", "kind", "content", "taskID", "artifactID"]),
            let kindText = arguments["kind"],
            let kind = AgentTaskSignal.Kind(rawValue: kindText), let text = arguments["content"]
        else { throw CommunicationError.invalidPayload }
        let target = arguments["target"].map { AgentID(rawValue: $0) }
        let contract = "task." + kind.rawValue
        if path.hasSuffix(".send") {
            guard let target, policy.sends.contains(where: { $0.target == target.rawValue && $0.contract == contract })
            else { throw CommunicationError.unauthorized }
        } else {
            guard target == nil, policy.publications.contains(contract) else { throw CommunicationError.unauthorized }
            // Task ownership is directed; broadcasting a task would create ambiguous execution ownership.
            throw CommunicationError.unauthorized
        }
        let scope: AgentTaskScope
        if kind == .request {
            guard arguments["taskID"] == nil, let target else { throw CommunicationError.invalidPayload }
            scope = AgentTaskScope(
                id: UUID().uuidString,
                parentID: input.taskScope?.id ?? input.id, requester: sender,
                executor: target, sessionID: input.sessionID)
        } else {
            guard let existing, arguments["taskID"] == existing.id,
                existing.sessionID == input.sessionID,
                target == (kind == .input || kind == .cancel ? existing.executor : existing.requester)
            else { throw CommunicationError.scopeClosed }
            scope = existing
        }
        if kind == .input, scope.execution == .background { throw CommunicationError.invalidPayload }
        let content = try AgentTaskContent(
            text: text,
            stage: kind == .progress ? .waitingUser : (kind == .result ? .completed : .running),
            interactionID: kind == .progress ? UUID().uuidString : nil,
            artifactID: arguments["artifactID"].flatMap(BusinessRecordID.parse))
        let signal = try content.signal(kind, scope: scope, status: kind == .result ? .succeeded : nil)
        return (try CommunicationAction(message: signal.message(), target: target), signal)
    }
}
