import Foundation
import FunctionContracts
import UI

public enum IslandActions {
    @Action(
        domain: "UI", module: "Island", title: "present",
        doc: "Submit shared local and system content; the component owns presentation and animations.",
        parameters: [
            .init(
                "activityID", type: .string, required: true,
                description: "New stable activity UUID for this activity."),
            .init("revision", type: .string, required: true, description: "Positive increasing owner revision."),
            .init(
                "content", type: .string, required: true,
                description:
                    "IslandContent JSON: title, priority:background|low|normal|high|attention|critical, primary/secondary {kind:symbol|loading|spectrum|progress|elapsed,startedAt (seconds since 2001-01-01 UTC),symbol,effect:none|pulse|bounce|variableColor,value}; detail {text,thumbnail UUID} enables expansion. New detail auto-opens; ordinary updates preserve manual collapse."
            ),
        ], timeout: .seconds(5))
    public static func present(invocation: any FunctionInput, using island: any IslandControlCapability) async throws
        -> String
    {
        let command = try IslandCommand(operation: .present, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await execute(command, context: IslandActionContext(invocation: invocation), using: island).json()
    }
    @Action(
        domain: "UI", module: "Island", title: "update",
        doc: "Submit shared local and system content; the component owns presentation and animations.",
        parameters: [
            .init(
                "activityID", type: .string, required: true,
                description: "Stable activity UUID from ui.island."),
            .init("revision", type: .string, required: true, description: "Positive increasing owner revision."),
            .init(
                "content", type: .string, required: true,
                description:
                    "IslandContent JSON: title, priority:background|low|normal|high|attention|critical, primary/secondary {kind:symbol|loading|spectrum|progress|elapsed,startedAt (seconds since 2001-01-01 UTC),symbol,effect:none|pulse|bounce|variableColor,value}; detail {text,thumbnail UUID} enables expansion. New detail auto-opens; ordinary updates preserve manual collapse."
            ),
        ], timeout: .seconds(5))
    public static func update(invocation: any FunctionInput, using island: any IslandControlCapability) async throws
        -> String
    {
        let command = try IslandCommand(operation: .update, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await execute(command, context: IslandActionContext(invocation: invocation), using: island).json()
    }
    @Action(
        domain: "UI", module: "Island", title: "end",
        doc: "Submit shared local and system content; the component owns presentation and animations.",
        parameters: [
            .init(
                "activityID", type: .string, required: true,
                description: "Stable activity UUID from ui.island."),
            .init("revision", type: .string, required: true, description: "Positive increasing owner revision."),
        ], timeout: .seconds(5))
    public static func end(invocation: any FunctionInput, using island: any IslandControlCapability) async throws
        -> String
    {
        let command = try IslandCommand(operation: .end, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await execute(command, context: IslandActionContext(invocation: invocation), using: island).json()
    }
    @Action(
        domain: "UI", module: "Island", title: "setPresentation",
        doc:
            "Set local compact/expanded presentation. Expanded requires detail content. System visibility remains iOS-controlled.",
        parameters: [
            .init(
                "activityID", type: .string, required: true,
                description: "Stable activity UUID from ui.island."),
            .init(
                "size", type: .string, required: true,
                description: "compact or expanded. Expanded requires an existing detail."),
        ], timeout: .seconds(5))
    public static func setPresentation(invocation: any FunctionInput, using island: any IslandControlCapability)
        async throws -> String
    {
        let command = try IslandCommand(operation: .setPresentation, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await execute(command, context: IslandActionContext(invocation: invocation), using: island).json()
    }
    /// Both registered invocations and container-local calls share this typed execution boundary.
    public static func execute(
        _ command: IslandCommand, context: IslandActionContext, using island: any IslandControlCapability
    ) async throws -> IslandReceipt {
        try Task.checkCancellation()
        return try await island.performIsland(command, context: context)
    }

}

@ActionCatalog
public struct IslandModule: CapabilityModule {
    private let island: any IslandControlCapability
    public init(island: any IslandControlCapability) { self.island = island }
    public var definitions: [ActionFunction] {
        [
            IslandActions.presentDefinition(completing: { [island] in
                .value(try await IslandActions.present(invocation: $0, using: island))
            }),
            IslandActions.updateDefinition(completing: { [island] in
                .value(try await IslandActions.update(invocation: $0, using: island))
            }),
            IslandActions.endDefinition(completing: { [island] in
                .value(try await IslandActions.end(invocation: $0, using: island))
            }),
            IslandActions.setPresentationDefinition(completing: { [island] in
                .value(try await IslandActions.setPresentation(invocation: $0, using: island))
            }),
        ]
    }
}

public enum IslandSize: String, Sendable { case compact, expanded }

public struct IslandCommand: Sendable {
    public enum Operation: String, Sendable { case present, update, end, setPresentation }
    public let operation: Operation
    public let id: UUID
    public let revision: UInt64
    public let content: IslandContent?
    public let size: IslandSize?
    public init(operation: Operation, parameters: [String: String]) throws {
        let args = ActionArguments(parameters)
        let allowed: Set<String> =
            operation == .setPresentation
            ? ["activityID", "size"]
            : operation == .end ? ["activityID", "revision"] : ["activityID", "revision", "content"]
        if operation == .setPresentation,
            parameters["animation"] != nil || parameters["width"] != nil || parameters["height"] != nil
                || parameters["size"] == "large" || parameters["size"] == "custom"
        {
            throw IslandError.systemControlled
        }
        try args.validateAllowedKeys(allowed)
        guard let id = UUID(uuidString: try args.requiredString("activityID", maximumUTF8Bytes: 36)) else {
            throw IslandError.invalid
        }
        if operation == .setPresentation {
            try self.init(operation: operation, id: id, size: args.requiredEnum("size", as: IslandSize.self))
        } else {
            guard let revision = UInt64(try args.requiredString("revision", maximumUTF8Bytes: 20)) else {
                throw IslandError.invalid
            }
            let content: IslandContent?
            if operation == .end {
                content = nil
            } else {
                let raw = try args.requiredString("content", maximumUTF8Bytes: 4096)
                content = try JSONDecoder().decode(IslandContent.self, from: Data(raw.utf8))
            }
            try self.init(operation: operation, id: id, revision: revision, content: content)
        }
    }
    public init(
        operation: Operation, id: UUID, revision: UInt64 = 0, content: IslandContent? = nil, size: IslandSize? = nil
    ) throws {
        switch operation {
        case .present, .update:
            guard revision > 0, let content, size == nil else { throw IslandError.invalid }
            try content.validate()
            guard try JSONEncoder().encode(content).count <= 4096 else { throw IslandError.invalid }
        case .end:
            guard revision > 0, content == nil, size == nil else { throw IslandError.invalid }
        case .setPresentation:
            guard revision == 0, content == nil, size != nil else { throw IslandError.invalid }
        }
        self.operation = operation
        self.id = id
        self.revision = revision
        self.content = content
        self.size = size
    }

}
/// Constructed only by the registered adapter or the container's domain binding.
public struct IslandActionContext: Sendable {
    public let owner: String
    fileprivate let generation: UUID?
    fileprivate let sharedPresentation: Bool
    fileprivate init(invocation: any FunctionInput) {
        owner = invocation.context.source + ":" + invocation.context.sessionID
        generation = nil
        sharedPresentation = true
    }
    fileprivate init(domain: IslandDomain, generation: UUID) {
        owner = "domain." + domain.rawValue
        self.generation = generation
        sharedPresentation = false
    }
}
public struct IslandReceipt: Codable, Sendable {
    public let activityID: String
    public let state: String
    public let presentation: String
    public let localStatus: String
    public let systemStatus: String
    public init(activityID: String, state: String, presentation: String, localStatus: String, systemStatus: String) {
        self.activityID = activityID
        self.state = state
        self.presentation = presentation
        self.localStatus = localStatus
        self.systemStatus = systemStatus
    }
    fileprivate func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
public protocol IslandControlCapability: Sendable {
    func performIsland(_ command: IslandCommand, context: IslandActionContext) async throws -> IslandReceipt
}
public enum IslandDomain: String, CaseIterable, Sendable { case camera, voice, bluetooth }
/// Trusted, producer-bound Action calls inside the Actions container; no invocation or transport.
public protocol IslandActionCalling: Sendable {
    func perform(_ command: IslandCommand) async throws -> IslandReceipt
}
private struct IslandBoundActions: IslandActionCalling {
    let service: any IslandControlCapability
    let context: IslandActionContext
    func perform(_ command: IslandCommand) async throws -> IslandReceipt {
        try await IslandActions.execute(command, context: context, using: service)
    }
}
/// Observation environment and high-frequency data, separate from business Action execution.
@MainActor public protocol IslandDomainPresenting: AnyObject {
    var islandAvailable: Bool { get }
    var islandGeneration: UUID { get }
    func islandActions(for domain: IslandDomain) -> any IslandActionCalling
    func publishSpectrum(_ values: [Float], active: Bool) throws
    func reportIslandFailure(_ error: any Error)
}
/// Display image ownership uses the same owner identifier as its published activity.
@MainActor public protocol IslandThumbnailPresenting: AnyObject {
    func registerThumbnail(_ data: Data, owner: String, generation: UUID) async throws -> IslandThumbnailID
    func releaseThumbnail(_ id: IslandThumbnailID, owner: String, generation: UUID) throws
}
/// Shared execution implementation for domain adapters and declared Actions; UI owns only presentation.
@MainActor
public final class IslandPresentationService: IslandControlCapability, IslandDomainPresenting, IslandThumbnailPresenting
{
    private let state: IslandState
    private var stopped = false
    public var islandAvailable: Bool { !stopped && state.available }
    public var islandGeneration: UUID { state.generation }
    public init(state: IslandState) { self.state = state }
    public func performIsland(_ command: IslandCommand, context: IslandActionContext) async throws -> IslandReceipt {
        try Task.checkCancellation()
        guard !stopped else { throw IslandError.unavailable }
        let owner = context.owner
        let generation = state.generation
        if let expected = context.generation, expected != generation { throw IslandError.stale }
        switch command.operation {
        case .present, .update:
            guard let content = command.content else { throw IslandError.invalid }
            try state.publish(
                id: command.id, owner: owner, revision: command.revision, content: content,
                generation: generation, creating: command.operation == .present)
        case .end:
            try await state.end(id: command.id, owner: owner, revision: command.revision)
        case .setPresentation:
            guard let size = command.size else { throw IslandError.invalid }
            guard let activity = state.activities.first(where: { $0.id == command.id }) else {
                throw IslandError.missing
            }
            guard context.sharedPresentation || activity.owner == owner else { throw IslandError.owner }
            if size == .expanded {
                try await state.requestAttention(id: command.id)
            } else {
                try state.setExpanded(false, id: command.id)
            }
        }
        if command.operation == .present || command.operation == .update {
            try await state.flushSystem(expectedGeneration: generation)
        }
        return IslandReceipt(
            activityID: command.id.uuidString, state: "submitted", presentation: "localAndSystem",
            localStatus: state.localStatus, systemStatus: state.systemStatus.rawValue)
    }
    public func islandActions(for domain: IslandDomain) -> any IslandActionCalling {
        IslandBoundActions(service: self, context: .init(domain: domain, generation: state.generation))
    }

    public func registerThumbnail(_ data: Data, owner: String, generation: UUID) async throws -> IslandThumbnailID {
        guard !stopped else { throw IslandError.unavailable }
        return try await state.registerThumbnail(data, owner: owner, generation: generation)
    }
    public func releaseThumbnail(_ id: IslandThumbnailID, owner: String, generation: UUID) throws {
        guard !stopped else { throw IslandError.unavailable }
        try state.releaseThumbnail(id, owner: owner, generation: generation)
    }
    public func publishSpectrum(_ values: [Float], active: Bool) throws {
        guard !stopped else { throw IslandError.unavailable }
        try state.spectrum(values, active: active, generation: state.generation)
    }
    public func reportIslandFailure(_ error: any Error) { state.report(error) }
    public func stop() { stopped = true }
}
