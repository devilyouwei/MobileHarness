import Foundation

@MainActor public final class VisionContainer {
    private let admission: PlatformAdmission
    #if os(iOS)
        private var nativeCamera: AppleCamera?
        public var camera: AppleCamera {
            if let nativeCamera { return nativeCamera }
            let value = AppleCamera(admission: admission)
            nativeCamera = value
            return value
        }
        private var photoImport: Task<Void, any Error>?
        public func saveJPEG(_ data: Data) async throws {
            try admission.check()
            guard photoImport == nil else { throw PlatformError.busy }
            let admission = admission
            let task = Task {
                try admission.check()
                try await ApplePhotoLibrary.saveJPEG(data)
            }
            photoImport = task
            defer { photoImport = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
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
