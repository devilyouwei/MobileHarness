public enum DeviceCapability: String, CaseIterable, Sendable {
    case camera, microphone, speechRecognition, photoLibrary, location, bluetooth, localNetwork
}
public enum AuthorizationStatus: Sendable {
    case notDetermined, authorized, denied, restricted, unavailable
}

/// Implement each adapter with public Apple APIs and just-in-time user authorization.
public protocol PermissionProvider: Sendable {
    func status(for capability: DeviceCapability) async -> AuthorizationStatus
    func request(_ capability: DeviceCapability) async -> AuthorizationStatus
}
