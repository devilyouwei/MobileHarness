import AgentCore
import Foundation

/// Latest-only sound-source publication, independent of the speech recognition chain.
extension SpeechPerceptionAgent {
    func enqueueSound(
        _ value: SoundSourceObservation, parent: AgentInput, capturedAt: ContinuousClock.Instant
    ) {
        guard lifecycle == .running else { return }
        if pendingSound != nil { soundPublicationReplacements += 1 }
        let metadata = parent.metadata
        let scopedParent = AgentInput(
            id: parent.id, sessionID: parent.sessionID, payload: parent.payload,
            metadata: InputMetadata(
                payload: parent.payload, source: metadata.source, incarnation: metadata.incarnation,
                origin: metadata.origin,
                capturedAt: metadata.capturedAt, sequence: metadata.sequence, rootID: metadata.rootID,
                parentID: metadata.parentID, hops: metadata.hops,
                deadline: min(
                    metadata.deadline ?? capturedAt.advanced(by: .milliseconds(500)),
                    capturedAt.advanced(by: .milliseconds(500))), generation: metadata.generation),
            turn: parent.turn)
        pendingSound = (value, scopedParent, capturedAt)
        if soundPublisher == nil { soundPublisher = Task { await self.publishSound() } }
    }

    private func publishSound() async {
        defer {
            soundPublisher = nil
            if lifecycle == .running, pendingSound != nil {
                soundPublisher = Task { await self.publishSound() }
            }
        }
        while lifecycle == .running, let publication = pendingSound {
            pendingSound = nil
            guard !publication.parent.metadata.expired,
                publication.capturedAt.duration(to: .now) <= .milliseconds(500)
            else { continue }
            do {
                try Task.checkCancellation()
                try await communicate(
                    .soundSource(publication.value), parent: publication.parent, evidence: .beforePublication)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                soundPublicationRejections += 1
                reportError(error, input: publication.parent)
            }
        }
    }
}
