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
                    "IslandContent JSON: title, primary/secondary {kind:symbol|loading|spectrum|progress|elapsed,startedAt (seconds since 2001-01-01 UTC),symbol,effect:none|pulse|bounce|variableColor,value}; detail {text,thumbnail UUID} enables expansion. New detail auto-opens; ordinary updates preserve manual collapse."
            ),
        ], timeout: .seconds(5))
    public static func present(invocation: any FunctionInput, using island: any IslandControlCapability) async throws
        -> String
    {
        let command = try IslandCommand(operation: .present, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await island.performIsland(command, invocation: invocation)
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
                    "IslandContent JSON: title, primary/secondary {kind:symbol|loading|spectrum|progress|elapsed,startedAt (seconds since 2001-01-01 UTC),symbol,effect:none|pulse|bounce|variableColor,value}; detail {text,thumbnail UUID} enables expansion. New detail auto-opens; ordinary updates preserve manual collapse."
            ),
        ], timeout: .seconds(5))
    public static func update(invocation: any FunctionInput, using island: any IslandControlCapability) async throws
        -> String
    {
        let command = try IslandCommand(operation: .update, parameters: invocation.call.parameters)
        try Task.checkCancellation()
        return try await island.performIsland(command, invocation: invocation)
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
        return try await island.performIsland(command, invocation: invocation)
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
        return try await island.performIsland(command, invocation: invocation)
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
        self.id = id
        self.operation = operation
        if operation == .setPresentation {
            size = try args.requiredEnum("size", as: IslandSize.self)
            revision = 0
            content = nil
        } else {
            guard let revision = UInt64(try args.requiredString("revision", maximumUTF8Bytes: 20)), revision > 0 else {
                throw IslandError.invalid
            }
            self.revision = revision
            size = nil
            if operation == .end {
                content = nil
            } else {
                let raw = try args.requiredString("content", maximumUTF8Bytes: 4096)
                let value = try JSONDecoder().decode(IslandContent.self, from: Data(raw.utf8))
                try value.validate()
                content = value
            }
        }
    }
}
public protocol IslandControlCapability: Sendable {
    func performIsland(_ command: IslandCommand, invocation: any FunctionInput) async throws -> String
}
/// Producer-facing port: no layout, selection, transition counters or renderer access.
@MainActor public protocol IslandDomainPresenting: AnyObject {
    var islandAvailable: Bool { get }
    var islandGeneration: UUID { get }
    func publishDomain(_ owner: String, content: IslandContent?) throws
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
    public func performIsland(_ command: IslandCommand, invocation: any FunctionInput) async throws -> String {
        try Task.checkCancellation()
        guard !stopped else { throw IslandError.unavailable }
        let owner = invocation.context.source + ":" + invocation.context.sessionID
        let generation = state.generation
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
            if size == .expanded {
                try await state.requestAttention(id: command.id)
            } else {
                guard state.activities.contains(where: { $0.id == command.id }) else { throw IslandError.missing }
                try state.setExpanded(false, id: command.id)
            }
        }
        if command.operation == .present || command.operation == .update {
            try await state.flushSystem(expectedGeneration: generation)
        }
        let value: [String: Any] = [
            "activityID": command.id.uuidString,
            "state": "submitted", "presentation": "localAndSystem", "localStatus": state.localStatus,
            "systemStatus": state.systemStatus.rawValue,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    public func registerThumbnail(_ data: Data, owner: String, generation: UUID) async throws -> IslandThumbnailID {
        guard !stopped else { throw IslandError.unavailable }
        return try await state.registerThumbnail(data, owner: owner, generation: generation)
    }
    public func releaseThumbnail(_ id: IslandThumbnailID, owner: String, generation: UUID) throws {
        guard !stopped else { throw IslandError.unavailable }
        try state.releaseThumbnail(id, owner: owner, generation: generation)
    }
    public func publishDomain(_ owner: String, content: IslandContent?) throws {
        guard !stopped else { throw IslandError.unavailable }
        try state.publishSlot(owner: "domain." + owner, content: content)
    }
    public func publishSpectrum(_ values: [Float], active: Bool) throws {
        guard !stopped else { throw IslandError.unavailable }
        try state.spectrum(values, active: active, generation: state.generation)
    }
    public func reportIslandFailure(_ error: any Error) { state.report(error) }
    public func stop() { stopped = true }
}
