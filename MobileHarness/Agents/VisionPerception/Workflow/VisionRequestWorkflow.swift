import AgentCore
import Foundation
import Gateway
import StorageCore
import UI

extension VisionPerceptionAgent {
    func processInput(_ input: AgentInput) async throws {
        if case .observation(let message) = input.payload, message.contract == CameraStateObservation.contract {
            try await receiveCameraState(input, message: message)
            return
        }

        var input = input
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            if signal.kind == .cancel,
                let original = fixedTaskInputs.values.first(where: { $0.taskScope?.id == signal.scope.id })
            {
                try await taskCoordinator.admitFixedTask(signal, input: input)
                try await contextRepository.update { $0.state.cameraRequestID = nil }
                camera.retire(original.id)
                fixedTaskInputs[original.id] = nil
                try emit(.control("agent.error: task cancelled"), input: original, sequence: 0)
                try await taskCoordinator.reportFixedTask(
                    signal.scope, input: original,
                    result: ToolResult(callID: original.id, value: "Task cancelled", isError: true), status: .cancelled)
                return
            }
            if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination"
                || signal.businessContract == AgentTaskContent.contract
            {
                try await taskCoordinator.receive(input)
                return
            }
            let fixed = try AgentFixedTaskInput.unwrap(
                signal, input: input, executor: descriptor.id, decode: CameraCaptureIntent.taskMessage)
            guard fixedTaskInputs.count < 32 else { throw CommunicationError.capacityExceeded }
            try await taskCoordinator.admitFixedTask(signal, input: input)
            fixedTaskInputs[fixed.id] = fixed
            input = fixed
        }

        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        input = decision.input
        if input.payload.kind == .toolResult
            || {
                if case .observation(let message) = input.payload { return message.cameraCaptureIntent != nil }
                return false
            }()
        {
            let cleanup: Bool
            if case .observation(let message) = input.payload, message.cameraCaptureIntent?.operation == .cancel {
                cleanup = input.metadata.origin == .local && input.metadata.source == "runtime"
            } else {
                cleanup = false
            }
            guard lifecycle == .running || (lifecycle == .paused && cleanup) else { throw HarnessError.notRunning }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            var next = camera
            let (result, original) = try next.receive(input, rootSessionID: sessionID)
            try await prepareSignal(input, cameraRequestID: next.requestID)
            guard lifecycle == .running else { throw HarnessError.notRunning }
            camera = next
            do { try emit(result, input: original, sequence: input.metadata.sequence) } catch {
                if case .toolCall(let call) = result { camera.retire(call.id) }
                throw error
            }
            processed += 1
            return
        }
        throw HarnessError.unsupportedInput
    }

    func track(_ pose: PoseObservation, input: AgentInput) async throws {
        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == trackingSessionID else { throw CommunicationError.scopeClosed }
        do { try pose.validate() } catch { throw CommunicationError.invalidPayload }
        guard lastSequence.map({ pose.sequence > $0 }) ?? true,
            lastTimestamp.map({ pose.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if let lastPoseReceivedAt, ContinuousClock.now - lastPoseReceivedAt >= .seconds(1) {
            tracking.reset()
        }
        if let person = pose.people.first,
            PoseTrackingPolicy.aimPoint(person, width: pose.width, height: pose.height) != nil
        {
            lastPoseReceivedAt = .now
        }
        lastSequence = pose.sequence
        lastTimestamp = pose.timestamp
        processed += 1
        guard lifecycle == .running else { return }
        let available = await controlAvailable()
        guard lifecycle == .running, trackingSessionID == input.sessionID, lastSequence == pose.sequence else { return }
        guard available else {
            tracking.reset()
            return
        }
        guard controlsArm, let aim = tracking.nextAim(pose) else { return }
        let call = try Self.aimPermission.call(["base": String(aim.base), "pitch": String(aim.pitch)])
        try emit(.toolCall(call), input: input, sequence: pose.sequence)
        tracking.commit(base: aim.base, pitch: aim.pitch, timestamp: pose.timestamp)
    }

    private func receiveCameraState(_ input: AgentInput, message: AgentMessage) async throws {
        guard input.metadata.origin == .local, input.metadata.source == CameraStateObservation.source,
            input.sessionID == sessionID, input.metadata.contract == CameraStateObservation.contract,
            input.metadata.version == 1
        else { throw CommunicationError.unauthorized }
        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard let value = message.content(as: CameraStateObservation.self),
            value.sequence == input.metadata.sequence
        else { throw CommunicationError.invalidPayload }
        try input.validate(message)
        try await contextRepository.update {
            guard value.sequence > ($0.state.cameraState?.sequence ?? 0) else { throw CommunicationError.outOfOrder }
            $0.state.cameraState = value
        }
        processed += 1
    }
}
