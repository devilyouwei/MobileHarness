import AgentCore
import Foundation
import ModelKit

/// Default user interaction entry; the shared worker retains identity and durable ownership.
public typealias AssistantAgent = AgentChatWorker<AssistantContextState>
