import Foundation

@MainActor
public final class VisionContainer {
    public func stateSnapshot() async throws -> PlatformStateSnapshot {
        try Task.checkCancellation()
        let facts = try authorizationSnapshot().mapValues { PlatformStateSnapshot.Value.text($0) }
        var runtime: [String: PlatformStateSnapshot.Value] = ["available": .flag(admission.isOpen)]
        #if os(iOS)
            runtime["cameraCreated"] = .flag(nativeCamera != nil)
            runtime["photoImporting"] = .flag(photoImport != nil)
        #endif
        return PlatformStateSnapshot(
            path: "platform.vision", business: facts, runtime: runtime,
            children: [.init(path: "platform.vision.camera")])
    }
    public func cameraStateSnapshot() async throws -> PlatformStateSnapshot {
        try Task.checkCancellation()
        var value = CameraHardwareSnapshot()
        var created = false
        #if os(iOS)
            if let camera = nativeCamera {
                value = camera.hardwareSnapshot
                created = true
            }
        #endif
        return .init(
            path: "platform.vision.camera",
            business: [
                "running": .flag(value.running), "phase": .text(value.phase.rawValue),
                "facing": value.facing.map { .text($0 == .front ? "front" : "back") } ?? .unknown,
                "photoWidth": value.photoWidth.map { .number(Double($0)) } ?? .unknown,
                "photoHeight": value.photoHeight.map { .number(Double($0)) } ?? .unknown,
            ], runtime: ["created": .flag(created)])
    }
    private let admission: PlatformAdmission
    var readAuthorization: () throws -> [String: String] = {
        ["camera": "unknown", "photosAddOnly": "unknown", "photosReadWrite": "unknown"]
    }
    func authorizationSnapshot() throws -> [String: String] { try readAuthorization() }
    #if os(iOS)
        private var nativeCamera: AppleCamera?
        public var camera: any CameraCapturing {
            if let nativeCamera { return nativeCamera }
            let value = AppleCamera(admission: admission)
            nativeCamera = value
            return value
        }
        private var photoImport: Task<Void, any Error>?
        public func saveJPEG(_ data: Data) async throws {
            guard data.count <= 4 * 1024 * 1024 else { throw ApplePhotoLibrary.Failure.invalidImage }
            try await savePhoto(data)
        }
        public func savePhoto(_ data: Data) async throws {
            do {
                try admission.check()
                guard photoImport == nil else { throw PlatformError.busy }
                let admission = admission
                let task = Task {
                    try admission.check()
                    try await ApplePhotoLibrary.savePhoto(data)
                }
                photoImport = task
                defer { photoImport = nil }
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                admission.report("vision", "saveJPEG", error)
                throw error
            }
        }
        func stop() async {
            let photoImport = photoImport
            photoImport?.cancel()
            await nativeCamera?.stopAndWait()
            _ = await photoImport?.result
        }
    #endif
    public init(admission: PlatformAdmission) { self.admission = admission }
}
