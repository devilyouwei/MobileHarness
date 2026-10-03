#if os(iOS)
    import SwiftUI

    /// First-level settings list; feature-specific forms live in their own destination.
    @MainActor
    public struct SettingsView: View {
        @Bindable var settings: SettingsState
        let bluetooth: BluetoothSettingsState
        let bluetoothControls: any BluetoothControlling
        let history: ConversationHistoryState
        let historyControls: any ConversationHistoryControlling
        let modelResources: ModelResourcesState?
        let save: () async -> Bool

        public init(
            settings: SettingsState, bluetooth: BluetoothSettingsState, bluetoothControls: any BluetoothControlling,
            history: ConversationHistoryState,
            historyControls: any ConversationHistoryControlling, modelResources: ModelResourcesState? = nil,
            save: @escaping () async -> Bool
        ) {
            self.settings = settings
            self.bluetooth = bluetooth
            self.bluetoothControls = bluetoothControls
            self.history = history
            self.historyControls = historyControls
            self.modelResources = modelResources
            self.save = save
        }

        public var body: some View {
            List {
                Section("AI 模型") {
                    if let modelResources {
                        NavigationLink {
                            ModelResourcesView(state: modelResources, group: .recognition)
                        } label: {
                            Label("音频识别", systemImage: "waveform")
                        }
                        .accessibilityIdentifier("settings.recognition.open")
                        NavigationLink {
                            ModelResourcesView(state: modelResources, group: .synthesis)
                        } label: {
                            Label("语音合成", systemImage: "speaker.wave.2")
                        }
                        .accessibilityIdentifier("settings.synthesis.open")
                    }
                    NavigationLink {
                        LanguageModelSettingsView(settings: settings, modelResources: modelResources, save: save)
                    } label: {
                        Label("大模型", systemImage: "brain")
                    }
                    .accessibilityIdentifier("settings.language.open")
                    if let modelResources {
                        NavigationLink {
                            ModelResourcesView(state: modelResources, group: .vision)
                        } label: {
                            Label("视觉识别", systemImage: "viewfinder")
                        }
                        .accessibilityIdentifier("settings.vision.open")
                    }
                }
                Section("外接设备") {
                    NavigationLink {
                        BluetoothSettingsView(state: bluetooth, controls: bluetoothControls)
                    } label: {
                        HStack {
                            Label("蓝牙外设", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            Text(bluetooth.summary).foregroundStyle(.secondary).font(.subheadline)
                        }
                    }
                    .accessibilityIdentifier("settings.bluetooth.open")
                }
                Section("用户") {
                    NavigationLink {
                        ConversationHistoryView(state: history, controls: historyControls)
                    } label: {
                        Label("对话历史", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("settings.conversation.history")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private struct LanguageModelSettingsView: View {
        @Bindable var settings: SettingsState
        let modelResources: ModelResourcesState?
        let save: () async -> Bool
        @State private var missingLocalModel = false

        var body: some View {
            Form {
                Section {
                    Toggle(
                        "使用云端大模型",
                        isOn: Binding(
                            get: { settings.isEnabled },
                            set: { value in
                                if !value, let modelResources,
                                    !ModelResourceGroup.language.isInstalled(in: modelResources.items)
                                {
                                    missingLocalModel = true
                                } else {
                                    settings.isEnabled = value
                                }
                            })
                    )
                    .accessibilityIdentifier("settings.cloud.enabled")
                } footer: {
                    Text("关闭后使用本地 Qwen，需先下载模型。")
                }
                Section {
                    HStack {
                        TextField("https://api.openai.com/v1", text: $settings.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("云端模型 URL")
                            .accessibilityIdentifier("settings.cloud.url")
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first {
                                settings.url = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("粘贴 URL")
                        .accessibilityIdentifier("settings.cloud.url.paste")
                    }
                    HStack {
                        SecureField("API Key（可选）", text: $settings.key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("settings.cloud.key")
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first {
                                settings.key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("粘贴 Key")
                        .accessibilityIdentifier("settings.cloud.key.paste")
                    }
                    Button(action: settings.loadModels) {
                        HStack {
                            Text(settings.isLoading ? "正在加载模型…" : "加载模型")
                            Spacer()
                            if settings.isLoading { ProgressView() }
                        }
                    }
                    .disabled(!settings.canLoad)
                    .accessibilityIdentifier("settings.cloud.load")
                    if !settings.models.isEmpty {
                        Picker("对话模型", selection: $settings.selectedModel) {
                            Text("请选择模型").tag("")
                            ForEach(settings.models, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("settings.cloud.model")
                    } else {
                        LabeledContent("默认对话模型", value: settings.selectedModel)
                    }
                } header: {
                    Text("云端服务")
                } footer: {
                    Text("URL 留空时使用 OpenAI 官方服务。")
                }
                if settings.isSaving || settings.error != nil || settings.notice != nil {
                    Section {
                        Text(settings.isSaving ? "正在保存…" : (settings.error ?? settings.notice ?? ""))
                            .foregroundStyle(settings.error == nil ? Color.secondary : .red)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .accessibilityIdentifier("settings.status")
                    }
                    .transaction { $0.animation = nil }
                }
                if let modelResources { ModelResourceSections(state: modelResources, group: .language) }
            }
            .disabled(settings.isSaving)
            .navigationTitle("大模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            // Keep native back navigation mounted; the App-owned save continues across navigation.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if !settings.isEnabled, let modelResources {
                                await modelResources.refresh()
                                guard ModelResourceGroup.language.isInstalled(in: modelResources.items) else {
                                    missingLocalModel = true
                                    return
                                }
                            }
                            _ = await save()
                        }
                    } label: {
                        Text("保存")
                            .opacity(settings.isSaving ? 0 : 1)
                            .overlay {
                                ProgressView().opacity(settings.isSaving ? 1 : 0)
                            }
                            .accessibilityLabel(settings.isSaving ? "正在保存" : "保存")
                    }
                    .disabled(!settings.canSave)
                    .accessibilityIdentifier("settings.save")
                }
            }
            .alert("请先安装本地大模型", isPresented: $missingLocalModel) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(ModelResourceGroup.language.installationMessage)
            }
            .onDisappear { settings.cancelDiscovery() }
        }
    }

#endif
