import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import UI

/// Tool-name groups shared by the control loop, presentation and diagnostics.
enum WriterToolGroup {
    static let fileMutations: Set<String> = ["replace", "move", "remove", "removeTree", "restore"]
    /// Calls after which late user revisions must be applied before acting.
    static let boundaries: Set<String> = ["finish", "workspace.enter", "workspace.create"]
    /// Calls that must be the only call in their model round.
    static let exclusive: Set<String> = boundaries.union(["ask"])
}

/// Host ports bind authenticated request identity. Writer may select its work, never its execution owner.
public struct WriterTools: Sendable {
    public let definitions: [ChatToolDefinition]
    let library: [ChatToolDefinition]?
    public let execute: @Sendable (ChatToolCall) async throws -> WriterToolOutcome
    public let append: @Sendable (String, String) async throws -> Void
    public let complete: @Sendable (String) async throws -> String
    public let refresh: @Sendable () async -> Void
    public let abort: @Sendable (String) async throws -> Void
    public init(
        definitions: [ChatToolDefinition],
        execute: @escaping @Sendable (ChatToolCall) async throws -> WriterToolOutcome,
        append: @escaping @Sendable (String, String) async throws -> Void,
        complete: @escaping @Sendable (String) async throws -> String,
        abort: @escaping @Sendable (String) async throws -> Void,
        refresh: @escaping @Sendable () async -> Void = {},
        library: [ChatToolDefinition]? = nil
    ) {
        self.definitions = definitions
        self.execute = execute
        self.append = append
        self.complete = complete
        self.abort = abort
        self.refresh = refresh
        self.library = library
    }
}
public struct WriterWorkspaceContext: Sendable, Encodable {
    let workspaceID: String
    let title: String
    let entry: String
    let entryExists: Bool
    let entryEmpty: Bool
    let presentationStatus: String

    var domain: String { "workspace:" + workspaceID }
}

enum WriterMilestone: Sendable {
    case draftUpdated, recovering, renderIssue
}

enum WriterControlDomain: String {
    case library
    case editing = "workspace"

    func skillIDs() throws -> [String] {
        let roots: [String]
        switch self {
        case .library: roots = try AgentConfigurations.baseSkills(named: "Writer")
        case .editing: roots = ["writer-file-editing"]
        }
        return try AgentSkillLoader.expand(roots, owner: .writer)
    }

    func registry() throws -> CapabilityRegistry {
        try AgentConfigurations.registry(AgentSkillLoader.bindings(skillIDs(), owner: .writer), owner: .writer)
    }

    func definitions(_ registry: CapabilityRegistry) throws -> [ChatToolDefinition] {
        try registry.tools.map { tool in
            guard let definition = tool.definition else { throw WriterFailure.invalidOutput }
            return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
        }
    }

    func toolDefinitions(_ tools: WriterTools) -> [ChatToolDefinition] {
        switch self {
        case .library: tools.library ?? []
        case .editing: tools.definitions
        }
    }
}
enum WriterLocalTools {
    static let declarations: [ActionDeclaration] = [
        tool(
            "ask", "Pause for essential user information.",
            [.init("question", description: "Nonempty question for the user, up to 2048 UTF-8 bytes.")]),
        tool(
            "finish", "End the delegation in a separate tool round. Report actual results.",
            [
                .init("summary", description: "Brief factual completion summary."),
                .init(
                    "outcome", required: false,
                    description:
                        "Use artifact for publishing or library operations, explanation for a completed answer, declined for infeasible work, or cancelled when the user asks you to stop. Cancelled preserves the draft without publishing.",
                    values: ["artifact", "explanation", "declined", "cancelled"]),
            ]),
        tool(
            "enter", "Enter a saved workspace for editing or switch to another saved workspace. Call alone.",
            [
                .init(
                    "workspaceID",
                    description: "Exact workspace_N known from the user, current context, or workspace.search.")
            ]),
        tool(
            "create", "Create a new workspace, initialize an empty entry file and enter it for editing. Call alone.",
            [
                .init("title", description: "Nonempty display title in the user’s language."),
                .init(
                    "entry",
                    description:
                        "Workspace-relative file path ending in .html, .md or .txt, such as flowchart.html or docs/flowchart.md. Pass the path only. Write source content with edit."
                ),
            ]),
    ]

    static func contains(_ path: String) -> Bool {
        declarations.contains { $0.path.description == path }
    }

    private static func tool(_ name: String, _ doc: String, _ parameters: [ActionParameter]) -> ActionDeclaration {
        .init(path: .init(domain: "Agent", module: "Writer", function: name), doc: doc, parameters: parameters)
    }
}

public struct WriterNeedsInput: Error, Sendable { public let question: String }
public enum WriterToolOutcome: Sendable {
    case waiting(String)
    case observation(String)
    case entered(WriterWorkspaceContext, evidence: String)
    case visual(String, ChatImage)
    case write(ArtifactEditPreparation)
    case finished(String)
}
