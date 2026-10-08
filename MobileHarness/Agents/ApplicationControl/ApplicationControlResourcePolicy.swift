import AgentCore
import Foundation

/// Pure resource-result validation and error projection; no runtime or native effects.
enum ApplicationControlResourcePolicy {
    static func preferenceFailureReason(_ code: String?) -> String {
        switch code {
        case "resource.selection.recognition": "recognitionRequired"
        case "resource.selection.synthesis": "synthesisRequired"
        case "resource.source.invalid": "invalidSource"
        default: "execution"
        }
    }
    static func isResourceCommand(_ intent: ModelResourceIntent) -> Bool {
        switch intent {
        case .download, .cancel, .remove: true
        default: false
        }
    }
    static func failureMessage(_ raw: String) -> String {
        var bytes = Array(raw.utf8.prefix(2048))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    struct PreferenceValue: Decodable {
        let endpoint: String
        let allowsCellular: Bool
        let useCustomRecognition: Bool
        let useCustomSynthesis: Bool
    }
    static func preferenceValue(_ raw: String) throws -> PreferenceValue {
        guard raw.utf8.count <= 2048,
            let keys = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            Set(keys.keys) == ["endpoint", "allowsCellular", "useCustomRecognition", "useCustomSynthesis"]
        else { throw CommunicationError.invalidPayload }
        let value = try JSONDecoder().decode(PreferenceValue.self, from: Data(raw.utf8))
        guard !value.endpoint.isEmpty, value.endpoint.utf8.count <= 1024 else {
            throw CommunicationError.invalidPayload
        }
        return value
    }
}
