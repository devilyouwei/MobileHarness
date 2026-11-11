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

    func text(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let ordered = messages.sorted { left, right in
            left.time == right.time ? left.seq < right.seq : left.time < right.time
        }
        var sections = ordered.map { message in
            let (source, content) = Self.presentation(message)
            return Self.bodyLines(content) + "\n\(source) ｜ \(formatter.string(from: message.time))"
        }
        if let interruptedIntentions, !interruptedIntentions.isEmpty {
            let entries = interruptedIntentions.map { "- " + Self.continuationLines($0) }
            sections.append("# Interrupted User Intent\n" + entries.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func presentation(_ message: AssistantInputMessage) -> (source: String, content: String) {
        switch message.senderRole {
        case .user:
            let source = message.channel == AgentID.speechPerception.rawValue ? "User (ASR)" : "User"
            return (source, message.content)
        case .agent:
            let name = String(message.channel.dropFirst("agent.".count))
            if name == AgentID.writer.rawValue { return ("Writer", message.content) }
            let validName = name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            return (validName ? "Agent (\(name))" : "Agent", message.content)
        case .action:
            guard message.channel.hasPrefix("action."), message.channel != "action.tools" else {
                return ("Action Result", message.content)
            }
            let name = message.channel.dropFirst("action.".count).components(separatedBy: .newlines).joined(
                separator: " ")
            return ("Action Result", name + " " + message.content)
        }
    }

    /// A source line is generated from runtime attribution. An identical line inside content stays indented.
    private static func bodyLines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { line in
            if isSourceLine(line) || line == "# Interrupted User Intent" || line == "# Attached Tool Results" {
                return "    " + line
            }
            return line
        }.joined(separator: "\n")
    }

    private static func isSourceLine(_ line: String) -> Bool {
        line.contains(" ｜ ")
            && line.range(
                of: #"^(?:User(?: \(ASR\))?|Writer|Action Result|Agent(?: \([^()]+\))?) ｜ [0-9]{2}:[0-9]{2}:[0-9]{2}$"#,
                options: .regularExpression) != nil
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
    static func historyText(_ original: String) -> String {
        let marker = #""schema":"assistant.input_batch.v1""#
        guard original.contains(marker) else { return original }
        let lines = original.components(separatedBy: "\n")
        guard !lines.contains(where: isSourceLine) else { return original }
        var sections: [String] = []
        var attached: [String] = []
        func appendAttachments() {
            let text = attached.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sections.append("# Attached Tool Results\n    " + continuationLines(text))
            }
            attached.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if line.first == "{", line.contains(marker) {
                appendAttachments()
                sections.append(renderLegacyLine(line))
            } else {
                attached.append(line)
            }
        }
        guard !sections.isEmpty else { return original }
        appendAttachments()
        return sections.joined(separator: "\n\n")
    }

    private static func renderLegacyLine(_ line: String) -> String {
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
        else { return "Earlier input could not be restored." }
        let entries = batch.messages.map { message in
            guard message.senderRole == .action else { return message }
            let content: String
            if message.channel == "action.tools", message.content.hasPrefix("Native tool results for round ") {
                content = "See the paired tool results."
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
        return AssistantInputBatch(messages: entries, interruptedIntentions: nil).text()
    }
}
