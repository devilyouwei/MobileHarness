import Foundation

public struct ActionControl: Codable, Equatable, Sendable {
    public enum Command: String, Codable, CaseIterable, Sendable {
        case pause
        case resume
        case cancel
    }

    public let executionID: String
    public let controlID: UUID
    public let controlSequence: UInt64
    public let command: Command

    public init(executionID: String, controlID: UUID = UUID(), controlSequence: UInt64, command: Command) {
        self.executionID = executionID
        self.controlID = controlID
        self.controlSequence = controlSequence
        self.command = command
    }
}

public struct ActionExecutionStateChange: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, pausing, paused, resuming }
    public let executionID: String
    public let stateVersion: UInt64
    public let state: State

    public init(executionID: String, stateVersion: UInt64, state: State) {
        self.executionID = executionID
        self.stateVersion = stateVersion
        self.state = state
    }
}

public struct ActionControlReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case accepted, applied, alreadyInState, superseded, unsupported, invalidState, alreadyFinished, unavailable,
            busy, failed
    }
    public let executionID: String
    public let controlID: UUID
    public let status: Status
    public let stateVersion: UInt64?
    public let failure: String?

    public init(
        _ control: ActionControl, status: Status, stateVersion: UInt64? = nil, failure: String? = nil
    ) {
        executionID = control.executionID
        controlID = control.controlID
        self.status = status
        self.stateVersion = stateVersion
        self.failure = failure.map { String($0.prefix(512)) }
    }
}

public protocol ActionExecutable: Sendable {
    func execute(_ invocation: any FunctionInput) async throws -> ActionCompletion
}

public protocol ActionPauseControl: Sendable {
    func pause() async throws
    func resume() async throws
}

/// Registration is scoped to a single scheduled execution and inherited by its handler.
public enum ActionControlRegistration {
    @TaskLocal public static var register: (@Sendable (any ActionPauseControl) async throws -> Void)?
}

public struct ActionControlFeedback: Sendable {
    public enum Event: Sendable {
        case stateChanged(ActionExecutionStateChange)
        case receipt(ActionControlReceipt)
    }
    public let event: Event
    public let owner: ExecutionOwner
    public let envelope: ExecutionEnvelope

    public init(event: Event, owner: ExecutionOwner, envelope: ExecutionEnvelope) {
        self.event = event
        self.owner = owner
        self.envelope = envelope
    }
}
