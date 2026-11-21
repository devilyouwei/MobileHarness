import AgentCore
import Foundation

/// Trusted ingress attribution, independent of the provider's outer user role.
struct AssistantInputMessage: Decodable, Sendable {
    enum Role: String, Decodable, Sendable {
        case user, agent, action
    }

    let seq: UInt64
    let time: Date
    let senderRole: Role
    let channel: String
    let content: String

    private enum CodingKeys: String, CodingKey {
        case seq, time, channel, content
        case senderRole = "sender_role"
    }

    static func isUser(_ input: AgentInput) -> Bool {
        if case .text = input.payload { return input.metadata.origin == .local }
        if case .transcript(_, final: true)? = input.payload.perception {
            return input.metadata.source == AgentID.speechPerception.rawValue && input.metadata.origin == .agent
        }
        return false
    }
}

struct AssistantInputBatch {
    let messages: [AssistantInputMessage]
    let interruptedIntentions: [String]?

    func text(timeZone: TimeZone = .current) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let ordered = messages.sorted { left, right in
            left.time == right.time ? left.seq < right.seq : left.time < right.time
        }
        var sections: [String] = []
        var speechLines: [String] = []
        for (index, message) in ordered.enumerated() {
            let (source, content) = try Self.presentation(message)
            let body = try Self.bodyLines(content)
            if Self.isASR(message) {
                speechLines.append(body)
                if index + 1 < ordered.count, Self.isASR(ordered[index + 1]) { continue }
            }
            let sourceLine = try AgentPrompts.inputMarker(
                "sourceLine", ["source": source, "time": formatter.string(from: message.time)])
            sections.append((speechLines.isEmpty ? body : speechLines.joined(separator: "\n")) + sourceLine)
            speechLines.removeAll(keepingCapacity: true)
        }
        if let interruptedIntentions, !interruptedIntentions.isEmpty {
            let entries = interruptedIntentions.map { "- " + Self.continuationLines($0) }
            sections.append(
                (try AgentPrompts.inputMarker("interruptedHeading")) + "\n"
                    + entries.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func isASR(_ message: AssistantInputMessage) -> Bool {
        message.senderRole == .user && message.channel == AgentID.speechPerception.rawValue
    }

    private static func presentation(_ message: AssistantInputMessage) throws -> (source: String, content: String) {
        switch message.senderRole {
        case .user:
            let source =
                isASR(message)
                ? try AgentPrompts.inputMarker("asr")
                : try AgentPrompts.inputMarker("user")
            return (source, message.content)
        case .agent:
            let name = String(message.channel.dropFirst("agent.".count))
            let validName = name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            return (
                validName
                    ? try AgentPrompts.inputMarker("namedAgent", ["name": name])
                    : try AgentPrompts.inputMarker("agent"), message.content
            )
        case .action:
            guard message.channel.hasPrefix("action."), message.channel != "action.tools" else {
                return (try AgentPrompts.inputMarker("action"), message.content)
            }
            let name = message.channel.dropFirst("action.".count).components(separatedBy: .newlines).joined(
                separator: " ")
            return (try AgentPrompts.inputMarker("action"), name + " " + message.content)
        }
    }

    /// A source line is generated from runtime attribution. An identical line inside content stays indented.
    private static func bodyLines(_ value: String) throws -> String {
        try value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { line in
            if try isSourceLine(line)
                || line == (try AgentPrompts.inputMarker("interruptedHeading"))
                || line == (try AgentPrompts.inputMarker("toolsHeading"))
            {
                return "    " + line
            }
            return line
        }.joined(separator: "\n")
    }

    private static func isSourceLine(_ line: String) throws -> Bool {
        let labels = try ["user", "asr", "agent", "action"].map {
            NSRegularExpression.escapedPattern(for: try AgentPrompts.inputMarker($0))
        }
        let named = NSRegularExpression.escapedPattern(
            for: try AgentPrompts.inputMarker("namedAgent", ["name": "__NAME__"])
        )
        .replacingOccurrences(of: "__NAME__", with: "[^()]+")
        let lineTemplate = try AgentPrompts.inputMarker("sourceLine", ["source": "__SOURCE__", "time": "__TIME__"])
        let pattern =
            "^"
            + NSRegularExpression.escapedPattern(for: lineTemplate.trimmingCharacters(in: .newlines))
            .replacingOccurrences(of: "__SOURCE__", with: "(?:" + (labels + [named]).joined(separator: "|") + ")")
            .replacingOccurrences(of: "__TIME__", with: "[0-9]{2}:[0-9]{2}:[0-9]{2}") + "$"
        return try line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func continuationLines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .joined(separator: "\n    ")
    }
}

extension AgentPrompts {
    static func assistantInput() throws -> String {
        try text("Assistant/Input/InputProtocol", "instructions")
    }

    /// These strings also parse recorded input envelopes and must retain their canonical spelling.
    static func inputMarker(_ key: String, _ variables: [String: String] = [:]) throws -> String {
        try shared.load("Agents/Assistant/Input/InputProtocol.json", language: "en").render(key, variables: variables)
    }
}
