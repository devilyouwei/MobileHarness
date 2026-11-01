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
