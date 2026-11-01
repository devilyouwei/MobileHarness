import Foundation

public enum CameraFacing: Sendable, Equatable { case front, back }
public enum CameraFlash: String, Sendable, Codable { case off, on, auto }
public struct CameraPhotoConfiguration: Sendable, Equatable {
    public let flash: CameraFlash
    public let zoom: Double
    public let maximumZoom: Double
    public let supportedFlash: [CameraFlash]
    public init(
        flash: CameraFlash = .off, zoom: Double = 1, maximumZoom: Double = 1, supportedFlash: [CameraFlash] = [.off]
    ) {
        self.flash = flash
        self.zoom = zoom
        self.maximumZoom = maximumZoom
        self.supportedFlash = supportedFlash
    }
}
public enum CameraEvent: String, Sendable { case interrupted, interruptionEnded, failed }
public enum CameraError: Error, Equatable, Sendable {
    case permissionDenied, unavailable, configurationFailed, startFailed, photoBusy, photoFailed, photoTimedOut
    case interrupted, runtimeFailed
}

/// Validate native-selected preview geometry before admitting capture; never resize the sensor output by guesswork.
struct CameraOutputDimensions: Equatable, Sendable {
    let width: Int32
    let height: Int32
    private var pixels: Int64 { Int64(width) * Int64(height) }
    private var bounded: Bool { width > 0 && height > 0 && width <= 4096 && height <= 4096 }
    private func matches(_ other: Self) -> Bool {
        Int64(width) * Int64(other.height) == Int64(height) * Int64(other.width)
    }
    static func photo(preview: Self, source: Self, supported: [Self]) throws -> Self {
        guard preview.bounded, preview.pixels <= 4_194_304,
            source.width > 0, source.height > 0,
            preview.matches(source) || preview.matches(.init(width: source.height, height: source.width)),
            let photo = supported.filter({ $0.bounded && $0.matches(source) }).min(by: { $0.pixels < $1.pixels })
        else { throw CameraError.configurationFailed }
        return photo
    }
}

/// Native capability only. Permission requests and capture require an explicit caller operation.
public protocol CameraFrameObserving: Sendable {
    func subscribeFrames() async throws -> AsyncThrowingStream<CameraFrame, Error>
}
public protocol CameraCapturing: CameraFrameObserving {
    var events: AsyncStream<CameraEvent> { get }
    var captureRotation: CGFloat { get async }
    func requestPermission() async -> Bool
    func start(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error>
    func switchCamera(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error>
    func capturePhoto(rotation: CGFloat) async throws -> Data
    func setVideoMode(_ enabled: Bool) async throws
    func beginRecording(durationSeconds: Int, rotation: CGFloat) async throws -> String
    func stopRecording(_ id: String) async throws -> CameraMovie
    func waitForRecording(_ id: String) async throws -> CameraMovie
    func photoConfiguration() async throws -> CameraPhotoConfiguration
    func configurePhoto(flash: CameraFlash, zoom: Double) async throws -> CameraPhotoConfiguration
    func isRunning() async -> Bool
    func stop() async
    func stopAndWait() async
}

public struct CameraMovie: Sendable {
    public let file: URL
    public let stopReason: String
    public init(file: URL, stopReason: String) {
        self.file = file
        self.stopReason = stopReason
    }
}

extension CameraCapturing {
    public func setVideoMode(_ enabled: Bool) async throws { if enabled { throw CameraError.unavailable } }
    public func beginRecording(durationSeconds: Int, rotation: CGFloat) async throws -> String {
        throw CameraError.unavailable
    }
    public func stopRecording(_ id: String) async throws -> CameraMovie { throw CameraError.unavailable }
    public func waitForRecording(_ id: String) async throws -> CameraMovie { throw CameraError.unavailable }

    public func photoConfiguration() async throws -> CameraPhotoConfiguration { .init() }
    public func configurePhoto(flash: CameraFlash, zoom: Double) async throws -> CameraPhotoConfiguration {
        throw CameraError.configurationFailed
    }
}

/// Resident facts owned by the native capability; observation never activates the device.
public struct CameraHardwareSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable { case stopped, starting, running, switching, stopping, interrupted, failed }
    public var phase: Phase = .stopped
    public var running = false
    public var facing: CameraFacing?
    public var photoWidth: Int?
    public var photoHeight: Int?
    public var zoom: Double?
    public var recording = false
    public init() {}
}
