import Foundation

/// The single place that turns an Agent's own variables into model-visible text. Roles and Skills never format them.
public enum AgentStatePrompt {
    /// Natural-language absolute time such as "November 21, 2026 at 10:29 PM"; never a timestamp or a relative time.
    static func time(_ date: Date, language: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: AgentPrompts.normalizedLanguage(language) == "zh-Hans" ? "zh_Hans_CN" : "en_US")
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The dynamic block placed before the latest user input: values in write order, each with its write time.
    /// Empty when nothing is set.
    static func block(_ variables: AgentStateVariables, timeZone: TimeZone = .current) throws -> String {
        guard !variables.entries.isEmpty else { return "" }
        let templates = try AgentPrompts.requestContext()
        let lines = try variables.ordered.map { item in
            try templates.render(
                "stateLine",
                variables: [
                    "name": item.name,
                    "time": time(item.entry.writtenAt, language: AgentPrompts.language, timeZone: timeZone),
                    "value": String(decoding: try JSONEncoder().encode(item.entry.value), as: UTF8.self),
                ])
        }
        return try templates.render("state", variables: ["variables": lines.joined(separator: "\n")])
    }

    /// The stable system-prompt section: declared variables, their meaning and allowed values.
    /// Access is deliberately not stated; a write to a read-only variable is rejected instead.
    static func declarations(_ schema: AgentStateSchema) throws -> String {
        guard !schema.declarations.isEmpty else { return "" }
        let templates = try AgentPrompts.requestContext()
        let lines = try schema.declarations.values.sorted { $0.name < $1.name }.map { declaration in
            try templates.render(
                "stateDeclaration",
                variables: [
                    "name": declaration.name, "meaning": meaning(declaration),
                    "values": declaration.type == .enum
                        ? declaration.values.joined(separator: ", ") : declaration.type == .bool ? "true, false" : "",
                ])
        }
        return try templates.render("stateDeclarations", variables: ["declarations": lines.joined(separator: "\n")])
    }

    private static func meaning(_ declaration: AgentStateDeclaration) -> String {
        guard AgentPrompts.language == "zh-Hans" else { return declaration.meaning }
        do { return try AgentPrompts.text("Shared/Descriptions", "state." + declaration.name) } catch {
            return declaration.meaning
        }
    }
}
