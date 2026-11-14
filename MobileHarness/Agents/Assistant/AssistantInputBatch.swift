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
        var sections = try ordered.map { message in
            let (source, content) = try Self.presentation(message)
            return try Self.bodyLines(content)
                + (try AgentPrompts.inputMarker(
                    "sourceLine",
                    ["source": source, "time": formatter.string(from: message.time)]))
        }
        if let interruptedIntentions, !interruptedIntentions.isEmpty {
            let entries = interruptedIntentions.map { "- " + Self.continuationLines($0) }
            sections.append(
                (try AgentPrompts.inputMarker("interruptedHeading")) + "\n"
                    + entries.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func presentation(_ message: AssistantInputMessage) throws -> (source: String, content: String) {
        switch message.senderRole {
        case .user:
            let source =
                message.channel == AgentID.speechPerception.rawValue
                ? try AgentPrompts.inputMarker("asr")
                : try AgentPrompts.inputMarker("user")
            return (source, message.content)
        case .agent:
            let name = String(message.channel.dropFirst("agent.".count))
            if name == AgentID.writer.rawValue {
                return (try AgentPrompts.inputMarker("writer"), message.content)
            }
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
        let labels = try ["user", "asr", "writer", "agent", "action"].map {
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
            || line.range(
                of: try AgentPrompts.inputMarker("legacySourcePattern"), options: .regularExpression
            ) != nil

    }

    private static func continuationLines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .joined(separator: "\n    ")
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private struct LegacyBatch: Decodable {
        let schema: String
        let messages: [AssistantInputMessage]
    }

    /// Reproject old recorded batches when building a new prompt. Storage keeps the original request.
    static func historyText(_ original: String) throws -> String {
        let marker = #""schema":"assistant.input_batch.v1""#
        guard original.contains(marker) else { return original }
        let lines = original.components(separatedBy: "\n")
        guard try !lines.contains(where: isSourceLine) else { return original }
        var sections: [String] = []
        var attached: [String] = []
        func appendAttachments() throws {
            let text = attached.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sections.append(
                    (try AgentPrompts.inputMarker("toolsHeading")) + "\n    "
                        + continuationLines(text))
            }
            attached.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if line.first == "{", line.contains(marker) {
                try appendAttachments()
                sections.append(try renderLegacyLine(line))
            } else {
                attached.append(line)
            }
        }
        guard !sections.isEmpty else { return original }
        try appendAttachments()
        return sections.joined(separator: "\n\n")
    }

    private static func renderLegacyLine(_ line: String) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = timestampFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid batch timestamp")
            }
            return date
        }
        guard let batch = try? decoder.decode(LegacyBatch.self, from: Data(line.utf8)),
            batch.schema == "assistant.input_batch.v1"
        else { return try AgentPrompts.text("Assistant/InputProtocol", "unrestorable") }
        let entries = try batch.messages.map { message in
            guard message.senderRole == .action else { return message }
            let content: String
            if message.channel == "action.tools", message.content.hasPrefix("Native tool results for round ") {
                content = try AgentPrompts.text("Assistant/InputProtocol", "pairedResults")
            } else if var result = (try? JSONSerialization.jsonObject(with: Data(message.content.utf8)))
                as? [String: Any], result["action"] is String, result["call"] is Int
            {
                result.removeValue(forKey: "action")
                result.removeValue(forKey: "call")
                content =
                    (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? message.content
            } else {
                return message
            }
            return AssistantInputMessage(
                seq: message.seq, time: message.time, senderRole: .action, channel: message.channel,
                content: content)
        }
        return try AssistantInputBatch(messages: entries, interruptedIntentions: nil).text()
    }
}
