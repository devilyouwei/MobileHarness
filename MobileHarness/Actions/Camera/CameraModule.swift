import FunctionContracts

@ActionCatalog
public struct CameraModule: CapabilityModule {
    private let camera: any CameraControlCapability
    private let album: (any PhotoAlbumCapability)?
    public init(camera: any CameraControlCapability, album: (any PhotoAlbumCapability)? = nil) {
        self.camera = camera
        self.album = album
    }
    public var definitions: [ActionFunction] {
        [
            PhotoAlbumActions.function(using: album),
            CameraActions.startRecordingDefinition(completing: { [camera] in
                .value(try await CameraActions.startRecording(invocation: $0, using: camera))
            }),
            CameraActions.stopRecordingDefinition(completing: { [camera] in
                .value(try await CameraActions.stopRecording(invocation: $0, using: camera))
            }),
            CameraActions.saveVideoDefinition(completing: { [camera] in
                .value(try await CameraActions.saveVideo(invocation: $0, using: camera))
            }),
            CameraActions.ignoreVideoDefinition(completing: { [camera] in
                .value(try await CameraActions.ignoreVideo(invocation: $0, using: camera))
            }),
            CameraActions.configureDefinition(completing: { [camera] in
                .value(try await CameraActions.configure(invocation: $0, using: camera))
            }),
            CameraActions.cancelCaptureDefinition(completing: { [camera] in
                .value(try await CameraActions.cancelCapture(invocation: $0, using: camera))
            }),
            CameraActions.openVisionDefinition(handler: { [camera] in
                try await CameraActions.openVision(invocation: $0, using: camera)
            }),
            CameraActions.closeVisionDefinition(handler: { [camera] in
                try await CameraActions.closeVision(invocation: $0, using: camera)
            }),
            CameraActions.retryVisionDefinition(handler: { [camera] in
                try await CameraActions.retryVision(invocation: $0, using: camera)
            }),
            CameraActions.flipVisionDefinition(handler: { [camera] in
                try await CameraActions.flipVision(invocation: $0, using: camera)
            }),
            CameraActions.savePhotoDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.savePhoto(invocation: invocation, using: camera))
            }),
            CameraActions.ignorePhotoDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.ignorePhoto(invocation: invocation, using: camera))
            }),
            CameraActions.takePhotoDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.takePhoto(invocation: invocation, using: camera))
            }),
            CameraActions.retryDefinition(handler: { [camera] invocation in
                try await CameraActions.retry(invocation: invocation, using: camera)
            }),
            CameraActions.openDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.open(invocation: invocation, using: camera))
            }),
            CameraActions.closeDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.close(invocation: invocation, using: camera))
            }),
            CameraActions.flipDefinition(completing: { [camera] invocation in
                .value(try await CameraActions.flip(invocation: invocation, using: camera))
            }),
        ]
    }
}
