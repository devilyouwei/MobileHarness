import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func validateFeedback(_ input: AgentInput) throws {
        guard let activeInput, roundID != nil, input.metadata.origin == .runtime,
            input.metadata.source == "runtime", input.sessionID == activeInput.sessionID,
            input.metadata.parentID == activeInput.id, input.metadata.rootID == activeInput.metadata.rootID,
            input.turn == activeInput.turn
        else { throw CommunicationError.unauthorized }
    }
}
