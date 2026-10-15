import Foundation
import Storage

public protocol DeviceRepository: Sendable {
    func device(nativeID: String, name: String) async throws -> String
    func nativeDevice(_ id: String) async throws -> String
    func selectedDevice() async throws -> (id: String, name: String, reconnect: Bool)?
    func selectDevice(_ id: String?, reconnect: Bool) async throws
}
