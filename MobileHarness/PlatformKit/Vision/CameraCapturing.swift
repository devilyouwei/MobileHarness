import Foundation

public enum CameraFacing: Sendable, Equatable { case front, back }
public enum CameraEvent: String, Sendable { case interrupted, interruptionEnded, failed }
public enum CameraError: Error, Equatable, Sendable {
    case permissionDenied, unavailable, configurationFailed, startFailed, photoBusy, photoFailed, photoTimedOut
    case interrupted, runtimeFailed
}

/// Native capability only. Permission requests and capture require an explicit caller operation.
public protocol CameraCapturing: Sendable {
    var events: AsyncStream<CameraEvent> { get }
    var captureRotation: CGFloat { get async }
    func requestPermission() async -> Bool
    func start(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error>
    func switchCamera(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error>
    func subscribeFrames() async throws -> AsyncThrowingStream<CameraFrame, Error>
    func capturePhoto(rotation: CGFloat) async throws -> Data
    func isRunning() async -> Bool
    func stop() async
    func stopAndWait() async
}
