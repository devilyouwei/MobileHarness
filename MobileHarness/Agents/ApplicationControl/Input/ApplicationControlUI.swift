import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension ApplicationControlAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) async {
        uiExecution.consumer = consumer
        await island.bind(consumer: consumer, source: descriptor.id)
        await island.start()
    }
    func startUIInputs() async throws {
        do {
            if let uiWindows {
                let source = await uiWindows.requests
                uiInputs.append(
                    try await consumeUI(source, sessionID: sessionID, maximumConcurrent: 4) { agent, value, context in
                        try await agent.handleWindow(value, context: context)
                    })
            }
            if let connectionFacts {
                let stream = try await connectionFacts()
                let task = Task { [self] in
                    do {
                        for try await fact in stream {
                            try Task.checkCancellation()
                            try await observeConnection(fact)
                        }
                    } catch { if !Task.isCancelled { observationFailure(error) } }
                }
                uiInputs.append(
                    AgentUISubscription(
                        task: task,
                        close: {
                            await stream.cancel()
                            await stream.join()
                        }))
            }
            await setResourceObservationForeground(true)
            if let uiDiagnostics {
                let source = await uiDiagnostics.detectionRequests
                uiInputs.append(
                    try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                        switch value {
                        case .start: try await agent.startDetection(context: context)
                        case .startKeywordTest: try await agent.startDetection(context: context, keywordTest: true)
                        case .stop: await agent.stopDetection()
                        }
                    })
            }
            if let uiSettings {
                let source = await uiSettings.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    try await agent.handleSettings(value, context: context)
                }
                uiInputs.append(task)
            }
            if let uiResources {
                let source = await uiResources.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    try await agent.handleResources(value, context: context)
                }
                uiInputs.append(task)
            }
            if let uiDevices {
                let source = await uiDevices.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    _ = try await agent.executeUI(
                        AppInteractionIntent(kind: .device, parameters: value.parameters).input(
                            sessionID: context.sessionID),
                        context: context)
                }
                uiInputs.append(task)
            }
        } catch {
            await stopUIInputs()
            throw error
        }
    }
    func stopUIInputs() async {
        await stopDetection()
        await resourceObservation?.shutdown()
        resourceObservation = nil
        await uiInputs.retire(for: descriptor.id)()
    }
    public func setResourceObservationForeground(_ active: Bool) async {
        guard let resourceChanges, lifecycleIsActive else { return }
        if resourceObservation == nil {
            resourceObservation = await ResourceObservationSession(
                source: resourceChanges,
                changed: { [weak self] in try await self?.resourceDidChange() },
                failed: observationFailure)
        }
        await resourceObservation?.setForeground(active)
    }
    private func resourceDidChange() async throws {
        guard let uiResources else { return }
        let generation = await uiResources.presentation.beginRefresh()
        guard observationSequence < UInt64.max else { throw CommunicationError.capacityExceeded }
        let sequence = observationSequence + 1
        _ = try await executeUI(
            ModelResourceObservation.changed(generation: generation).input(sessionID: sessionID, sequence: sequence),
            context: ProcessingContext(
                sessionID: sessionID,
                source: ModelResourceObservation.source, sequence: sequence),
            diagnosticScope: .refresh(generation: generation))
    }
}
