@_exported import AudioTypes
import Foundation

// Preserve the ModelKit constructor API and error contract while sharing the actual PCM values.
extension AudioFormat {
    public init(sampleRate: Int, channels: Int, encoding: Encoding) throws {
        do {
            try self.init(validatingSampleRate: sampleRate, channels: channels, encoding: encoding)
        } catch AudioValidationError.invalidRequest(let message) { throw CapabilityError.invalidRequest(message) }
    }
}
extension AudioFrame {
    public init(data: Data, format: AudioFormat, sequence: UInt64, timestamp: TimeInterval) throws {
        do {
            try self.init(validatingData: data, format: format, sequence: sequence, timestamp: timestamp)
        } catch AudioValidationError.invalidRequest(let message) { throw CapabilityError.invalidRequest(message) }
    }
}
