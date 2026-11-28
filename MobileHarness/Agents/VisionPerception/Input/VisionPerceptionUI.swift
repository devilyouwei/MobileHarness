import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension VisionPerceptionAgent {
    func startUIInputs() async throws {
        if let uiAlbum {
            let source = await uiAlbum.requests
            let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                try await agent.handleAlbum(value, context: context)
            }
            uiInputs.append(task)
        }
        guard let uiCamera else { return }
        try await startCameraFacts(uiCamera)
        let source = await uiCamera.requests
        let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
            try await agent.handleUI(value, context: context)
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async {
        cameraFacts?.cancel()
        await cameraFacts?.value
        cameraFacts = nil
        await island.submit(nil)
        await uiInputs.retire(for: descriptor.id)()
    }
    private func startCameraFacts(_ camera: UICameraContainer) async throws {
        guard cameraFacts == nil else { return }
        let stream = try await camera.listenFacts()
        cameraFacts = Task { [self] in
            do {
                for try await value in stream {
                    guard !Task.isCancelled else { break }
                    await island.submit(Self.cameraContent(value))
                    cameraFactSequence += 1
                    let sequence = cameraFactSequence
                    let fact = await MainActor.run {
                        let displayedID = value.previews.last?.id
                        return CameraStateObservation(
                            sequence: sequence,
                            enabled: value.isEnabled, visible: value.isVisible, busy: value.isBusy || value.photoBusy,
                            needsSettings: value.needsSettings, facing: value.facing == .front ? .front : .back,
                            displayedPreviewID: displayedID, savedMediaID: value.savedMediaID, failure: value.message)
                    }
                    do { try await receive(fact.input(sessionID: sessionID)) } catch { cameraObservationFailure(error) }
                }
            } catch { if !Task.isCancelled { cameraObservationFailure(error) } }
            await stream.cancel()
            await stream.join()
            if !Task.isCancelled { cameraObservationFailure(UIRequestError.consumerEnded) }
        }
    }
}
