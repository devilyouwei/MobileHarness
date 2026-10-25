@MainActor
public struct ActionUIFacades<Camera, History, Resources, Bluetooth, Settings, ResourceOperations, SettingsOperations> {
    public let camera: Camera
    public let history: History
    public let resources: Resources
    public let bluetooth: Bluetooth
    public let settings: Settings
    public let resourceOperations: ResourceOperations
    public let settingsOperations: SettingsOperations
    public let modelName: @MainActor () -> String
    public let resourcesPresented: @MainActor () -> Void
    public init(
        camera: Camera, history: History, resources: Resources, bluetooth: Bluetooth, settings: Settings,
        resourceOperations: ResourceOperations, settingsOperations: SettingsOperations,
        modelName: @escaping @MainActor () -> String, resourcesPresented: @escaping @MainActor () -> Void
    ) {
        self.camera = camera
        self.history = history
        self.resources = resources
        self.bluetooth = bluetooth
        self.settings = settings
        self.resourceOperations = resourceOperations
        self.settingsOperations = settingsOperations
        self.modelName = modelName
        self.resourcesPresented = resourcesPresented
    }
}
