import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension ApplicationControlAgent {
    private enum UICommandFailure: Error {
        case admission(any Error)
        case dispatch(any Error)
        var phase: ModelResourceHostFailure.Phase {
            switch self {
            case .admission: .admission
            case .dispatch: .dispatch
            }
        }
        var underlying: any Error {
            switch self {
            case .admission(let error), .dispatch(let error): error
            }
        }
    }
    func executeUI(
        _ request: AgentInput, context: ProcessingContext, provider: Bool = false,
        diagnosticScope: ModelResourceHostFailure.Scope? = nil
    ) async throws -> String? {
        do { return try await executeUIBody(request, context: context, provider: provider) } catch let failure
            as UICommandFailure
        {
            try Task.checkCancellation()
            var bytes = Array(String(describing: failure.underlying).utf8.prefix(2048))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            let message = String(decoding: bytes, as: UTF8.self)
            if provider { throw ProviderIntentFailure(message: message, failureCode: nil) }
            guard let diagnosticScope else { throw ApplicationControlIntentFailure.execution(message) }
            let diagnostic = ModelResourceHostFailure(
                requestID: context.requestID, phase: failure.phase, scope: diagnosticScope, message: message)
            let followup = ProcessingContext(
                sessionID: context.sessionID, generation: context.generation, source: ModelResourceHostFailure.source,
                parentID: context.requestID, hops: 1)
            do {
                _ = try await executeUIBody(
                    diagnostic.input(sessionID: sessionID), context: followup, initialFailure: message)
            } catch ApplicationControlIntentFailure.presented {
                throw ApplicationControlIntentFailure.presented(message)
            } catch {
                throw NativeCleanupFailure(errors: [failure.underlying, error])
            }
            throw ApplicationControlIntentFailure.presented(message)
        }
    }
    private func executeUIBody(
        _ request: AgentInput, context: ProcessingContext, provider: Bool = false, initialFailure: String? = nil
    ) async throws -> String? {
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        do {
            do { try await receive(context.input(request.payload)) } catch { throw UICommandFailure.admission(error) }
            let maximumCalls: Int
            if case .observation(let message) = request.payload {
                if message.appInteraction != nil || message.resourceHostFailure != nil {
                    maximumCalls = 1
                } else if case .restoreSource? = message.resourceIntent {
                    maximumCalls = 3
                } else if case .saveSource? = message.resourceIntent {
                    maximumCalls = 3
                } else {
                    maximumCalls = 2
                }
            } else {
                maximumCalls = 2
            }
            var value: String?
            var failure = initialFailure
            var failureCode: String?
            var presented = false
            for _ in 0..<16 {
                try Task.checkCancellation()
                guard let envelope = try uiExecution.next(context.requestID, maximumCalls: maximumCalls) else {
                    throw CommunicationError.invalidPayload
                }
                let result: OutputExecutionResult
                do {
                    if case .toolCall = envelope.output {
                        result = try await executeTool(envelope, using: consumer)
                    } else {
                        result = try await consumer.execute(envelope)
                    }
                } catch { throw UICommandFailure.dispatch(error) }
                if let error = result.failure {
                    throw UICommandFailure.dispatch(ApplicationControlIntentFailure.execution(error))
                }
                if let tool = result.tool {
                    if tool.isError {
                        failure = failure.map { $0 + "; presentation: " + tool.value } ?? tool.value
                        if failureCode == nil { failureCode = tool.failureCode?.rawValue }
                    } else {
                        if case .toolCall(let call) = envelope.output {
                            if [
                                "System.ModelResources.restoreSource", "System.ModelResources.saveSource",
                                "System.ModelResources.snapshotResources", "UI.ResourcePresentation.showResources",
                                "System.Provider.discoverModels",
                            ].contains(call.toolPath) {
                                value = tool.value
                            }
                            if call.toolPath.hasPrefix("UI.ResourcePresentation.show") { presented = failure != nil }
                        }
                    }
                }
                if case .control(let state) = envelope.output {
                    if state == "application.control.finished" { return value }
                    if provider {
                        throw ProviderIntentFailure(
                            message: failure ?? state, failureCode: failureCode, presented: presented)
                    }
                    if presented { throw ApplicationControlIntentFailure.presented(failure ?? state) }
                    throw ApplicationControlIntentFailure.execution(failure ?? state)
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    try await self.receive(
                        ModelResourceIntent.retire(context.requestID).input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}
