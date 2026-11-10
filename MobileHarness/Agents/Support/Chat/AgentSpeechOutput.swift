import AgentCore
import Foundation

/// A role-owned text-to-audio boundary. Admission reserves a handle, not audible completion.
public protocol AgentSpeechOutput: Sendable {
    func prepare(text: String, input: AgentInput) async throws -> String
    func cancel(audioID: String, input: AgentInput) async throws
    func cancel(input: AgentInput) async
    func stop() async
}
