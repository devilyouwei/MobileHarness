import AgentCore
import Foundation
import ModelKit

/// Default user interaction entry; the role-owned worker retains identity and durable ownership.
public typealias AssistantAgent = AssistantChatWorker<AssistantContextState>
