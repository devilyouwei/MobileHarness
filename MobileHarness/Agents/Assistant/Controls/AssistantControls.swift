import AgentCore
import Foundation
import FunctionContracts

/// Operations of the Assistant's built-in control functions.
public enum AgentControlOperation: String, Codable, Sendable, Equatable {
    case stateSet = "state.set"
    case stateClear = "state.clear"
    case stateGet = "state.get"
    case loadSkills = "skill.load"
    case releaseSkills = "skill.unload"
    case sendMessage = "send"
}

/// One built-in control function, run by the Assistant: `own` changes its variables, Skill and round state; `peer`
/// reaches another Agent. Controls never reach Actions and are not configured by Skills.
public struct AssistantControl: Codable, Sendable, Equatable {
    public let alias: String
    public let operation: AgentControlOperation
    public let destination: ControlDestination
    public let declaration: ActionDeclaration
}

/// The Assistant's control library. Aliases, declarations, the usage guide and prompt text live in per-language
/// resources.
public enum AssistantControls {
    private struct Library: Decodable {
        let version: Int
        let controls: [AssistantControl]
    }

    /// Canonical English library; the prompt language selects its translated sibling.
    public static var all: [AssistantControl] {
        get throws { try library(language: "en") }
    }

    static func library(language: String) throws -> [AssistantControl] {
        let path =
            language == "en"
            ? "Agents/Assistant/Controls/Controls.json" : "Agents/Assistant/Controls/Controls.\(language).json"
        let library = try JSONDecoder().decode(Library.self, from: AgentConfigurations.data(path))
        guard library.version == 1, !library.controls.isEmpty, library.controls.count <= 16,
            Set(library.controls.map(\.alias)).count == library.controls.count,
            Set(library.controls.map(\.operation)).count == library.controls.count
        else { throw AgentConfigurationError.invalidFormat }
        for control in library.controls { try control.declaration.validate() }
        return library.controls
    }

    public static func control(path: String) throws -> AssistantControl? {
        try all.first { $0.declaration.path.description == path }
    }

    /// Usage guide (`Controls.md`), re-read for each prompt language; missing translations use the English guide.
    static var guidance: ControlGuidance {
        get throws {
            ControlGuidance(text: try guidanceText(language: "en"), localized: { try guidanceText(language: $0) })
        }
    }

    private static func guidanceText(language: String) throws -> String {
        var data: Data?
        if AgentPrompts.normalizedLanguage(language) == "zh-Hans" {
            do { data = try AgentConfigurations.data("Agents/Assistant/Controls/Controls.zh-Hans.md") } catch let error
                as CocoaError where error.code == .fileReadNoSuchFile
            {}
        }
        if data == nil { data = try AgentConfigurations.data("Agents/Assistant/Controls/Controls.md") }
        guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentConfigurationError.invalidFormat
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Registrations added to the Assistant's fixed capabilities, re-read for each prompt language.
    static var registrations: [ControlRegistration] {
        get throws {
            try all.map { control in
                ControlRegistration(
                    alias: control.alias, declaration: control.declaration, destination: control.destination,
                    localized: { language in
                        guard let match = try library(language: language).first(where: { $0.alias == control.alias })
                        else { throw AgentConfigurationError.resourceMissing(control.alias) }
                        return match.declaration
                    })
            }
        }
    }
}
