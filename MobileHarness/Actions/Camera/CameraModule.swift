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
