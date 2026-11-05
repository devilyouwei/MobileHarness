import Foundation
import FunctionContracts
import UI

@MainActor public protocol WindowContentLifecycle: AnyObject, Sendable {
    func beginWindowTransition() async throws
    func endWindowTransition()
    func pauseWindow(invocation: any FunctionInput) async throws
    func resumeWindow(invocation: any FunctionInput) async throws
    func closeWindow(invocation: any FunctionInput) async throws
}

extension WindowContentLifecycle {
    public func beginWindowTransition() async throws {}
    public func endWindowTransition() {}
}

/// Root-owned operations are bounded by the four admitted windows; replacement cancels and joins.
@MainActor public final class WindowExecutionService: WindowControlCapability {
    private struct Operation {
        let token: UUID
        let closing: Bool
        let task: Task<Void, any Error>
    }
    private let state: WindowState
    private let lifecycles: [String: any WindowContentLifecycle]
    private var stopped = false
    private var operations: [UUID: Operation] = [:]
    public init(state: WindowState, lifecycles: [String: any WindowContentLifecycle]) {
        self.state = state
        self.lifecycles = lifecycles
    }
    public func performWindow(
        _ operation: WindowOperation, id: String, x: Double?, y: Double?, invocation: any FunctionInput
    ) async throws {
        do {
            try await execute(operation, id: state.resolve(reference: id), x: x, y: y, invocation: invocation)
        } catch let error as WindowError {
            throw WindowExecutionFailure(error: error)
        }
    }
    private func execute(_ operation: WindowOperation, id: UUID, x: Double?, y: Double?, invocation: any FunctionInput)
        async throws
    {
        guard !stopped else { throw WindowError.unavailable }
        let item = try state.find(id)
        guard state.available else { throw WindowError.unavailable }
        if operation == .focus {
            try state.focus(id)
            return
        }
        if operation == .move {
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw WindowError.invalidPosition
            }
        }
        let previous = operations[id]
        if previous?.closing == true { throw WindowError.busy }
        previous?.task.cancel()
        let token = UUID()
        let task = Task { [self] in
            if let previous { _ = await previous.task.result }
            try Task.checkCancellation()
            let item = try state.find(id)
            let lifecycle = lifecycles[item.content]
            try await lifecycle?.beginWindowTransition()
            defer { lifecycle?.endWindowTransition() }
            state.report(id, message: nil)
            switch operation {
            case .minimize:
                try await lifecycle?.pauseWindow(invocation: invocation)
                try Task.checkCancellation()
                try await state.change(id, command: .minimize)
            case .restore, .maximize:
                try await state.change(id, command: operation == .restore ? .restore : .maximize)
                if item.mode == .minimized { try await lifecycle?.resumeWindow(invocation: invocation) }
            case .close:
                try await lifecycle?.closeWindow(invocation: invocation)
                try Task.checkCancellation()
                try await state.change(id, command: .close)
            case .move:
                guard let x, let y else { throw WindowError.invalidPosition }
                try await state.position(id, x: x * state.width, y: y * state.height)
            case .focus: break
            }
        }
        operations[id] = .init(token: token, closing: operation == .close, task: task)
        defer { if operations[id]?.token == token { operations[id] = nil } }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if !(error is CancellationError) { state.report(item.id, message: error.localizedDescription) }
            throw error
        }
    }
    public func stop() async {
        stopped = true
        let current = operations.values.map(\.task)
        for task in current { task.cancel() }
        for task in current { _ = await task.result }
    }
}

public struct WindowExecutionFailure: Error, LocalizedError, ActionExecutionFailureProviding {
    public let error: WindowError
    public var errorDescription: String? { error.localizedDescription }
    public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: "window." + error.rawValue) }
}
