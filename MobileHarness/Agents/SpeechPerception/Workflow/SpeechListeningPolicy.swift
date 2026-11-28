import AgentCore
import Foundation
import StorageCore

enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }

/// Capture consent and the current native route capability.
struct SpeechListeningPolicy {
    var enabled = false
    var revision: UInt64 = 0
    var fullDuplex = false
}
