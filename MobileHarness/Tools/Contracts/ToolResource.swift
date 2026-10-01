public struct ToolResource: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let cameraCapture = Self(rawValue: "camera.capture")
}
