#if os(iOS)
    import Foundation
    import FunctionContracts
    import UI

    @available(iOS 27, *)
    extension ActionsBusinessAssembly {
        func makeUIFacades() -> ActionsUIFacades {
            let cameraUI = ui.camera
            let historyUI = ui.history
            let resourcesUI = ui.modelResources
            let settingsUI = ui.settings
            let devicesUI = ui.devices
            let camera = CameraInteractionWorkflow(
                presentation: cameraUI,
                perform: { input in
                    _ = try await cameraUI.requests.submit(input)
                })
            let history = ConversationHistoryWorkflow(
                state: historyUI.presentation, prepare: {},
                refresh: { _ = try await historyUI.requests.submit(.refresh) },
                deleteArchive: { _ = try await historyUI.requests.submit(.delete($0)) },
                startNew: { _ = try await historyUI.requests.submit(.startNew) },
                summarize: { _ = try await historyUI.requests.submit(.summarize($0)) }, previewOutput: previewHistory,
                readConversation: { id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.conversation(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPhoto: { id, input in
                    guard case .photo(let value) = try await historyUI.requests.submit(.photo(id, input)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readMessage: { id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.message(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPage: { id, after, task in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.page(id, after, task))
                    else { throw UIRequestError.stale }
                    return value
                },
                readArchives: { cursor in
                    guard case .archives(let value) = try await historyUI.requests.submit(.archives(cursor)) else {
                        throw UIRequestError.stale
                    }
                    return value
                })
            let resourceOperations = ModelResourcesClient(
                read: { generation in
                    guard case .snapshot(let value) = try await resourcesUI.requests.submit(.refresh(generation)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                restore: {
                    guard case .source(let value) = try await resourcesUI.requests.submit(.restore) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                save: { draft in
                    guard case .source(let value) = try await resourcesUI.requests.submit(.save(draft)) else {
                        throw UIRequestError.stale
                    }
                    return value
                }, download: { id, draft in _ = try await resourcesUI.requests.submit(.download(id, draft)) },
                cancel: { _ = try await resourcesUI.requests.submitControl(.cancel($0)) },
                remove: { _ = try await resourcesUI.requests.submit(.remove($0)) })
            let resources = ModelResourceInteractionWorkflow(
                state: resourcesUI.presentation, operations: resourceOperations)
            let settingsOperations = ProviderSettingsClient(
                provider: SettingsProviderOperations(
                    initial: SettingsProviderAdapter.initial,
                    restore: {
                        guard case .draft(let value) = try await settingsUI.requests.submit(.restore) else {
                            throw UIRequestError.stale
                        }
                        return value
                    },
                    discover: { draft in
                        guard case .models(let value) = try await settingsUI.requests.submit(.discover(draft)) else {
                            throw UIRequestError.stale
                        }
                        return value
                    }, save: { _ = try await settingsUI.requests.submit(.save($0)) },
                    errorMessage: SettingsProviderAdapter.errorMessage), presentsResults: true)
            let settings = SettingsFormController(
                state: settingsUI.presentation, operations: settingsOperations,
                defaultModel: SettingsProviderAdapter.initial.model)
            let bluetoothControls = BluetoothInteractionWorkflow(
                state: devicesUI.presentation, initialFence: device.fence,
                fenceStop: { [device] in device.stopFence() },
                pageVisibility: { [bluetooth] visible in
                    if visible { bluetooth.openPage() } else { bluetooth.closePage() }
                }, openSettings: { [bluetooth] in bluetooth.openSystemSettings() },
                perform: { parameters in
                    if ["stopScan", "disconnect", "forget"].contains(parameters["operation"] ?? "") {
                        try await devicesUI.requests.submitControl(DeviceInput(parameters))
                    } else {
                        try await devicesUI.requests.submit(DeviceInput(parameters))
                    }
                })
            stopInteractions = {
                await camera.shutdown()
                await history.shutdown()
                await settings.shutdown()
                await resources.stopAndWait()
                await resourceOperations.shutdown()
                await settingsOperations.shutdown()
                await bluetoothControls.shutdown()
            }
            return ActionsUIFacades(
                camera: camera, history: history, resources: resources, bluetooth: bluetoothControls,
                settings: settings, resourceOperations: resourceOperations, settingsOperations: settingsOperations,
                modelName: { settingsOperations.modelName },
                resourcesPresented: { resources.acceptPresentedSnapshot() })
        }
    }
#endif
