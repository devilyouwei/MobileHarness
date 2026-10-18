#if os(iOS)
    import SwiftUI

    /// Native feature list. Route selection crosses the injected Agent intent interface.
    @MainActor
    public struct SettingsView: View {
        let bluetooth: BluetoothSettingsState
        let navigate: (AppDestination) -> Void
        public init(bluetooth: BluetoothSettingsState, navigate: @escaping (AppDestination) -> Void) {
            self.bluetooth = bluetooth
            self.navigate = navigate
        }
        public var body: some View {
            List {
                Section("AI 模型") {
                    destination(.recognition, title: "音频识别", icon: "waveform", identifier: "settings.recognition.open")
                    destination(
                        .synthesis, title: "语音合成", icon: "speaker.wave.2", identifier: "settings.synthesis.open")
                    destination(.language, title: "大模型", icon: "brain", identifier: "settings.language.open")
                    destination(.vision, title: "视觉识别", icon: "viewfinder", identifier: "settings.vision.open")
                }
                Section("外接设备") {
                    destination(
                        .bluetooth, title: "蓝牙外设", icon: "antenna.radiowaves.left.and.right",
                        identifier: "settings.bluetooth.open")
                }
                Section("用户") {
                    destination(
                        .history, title: "Agent 记录", icon: "doc.text.magnifyingglass",
                        identifier: "settings.agent.records")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preferredColorScheme(.dark)
        }
        private func destination(_ page: AppDestination, title: String, icon: String, identifier: String) -> some View {
            Button {
                navigate(page)
            } label: {
                HStack {
                    Label(title, systemImage: icon)
                    Spacer()
                    if page == .bluetooth { Text(bluetooth.summary).foregroundStyle(.secondary).font(.subheadline) }
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier(identifier)
        }
    }

    @MainActor
    public struct LanguageModelSettingsView: View {
        @Bindable var settings: SettingsState
        let settingsControls: any SettingsControlling
        let modelResources: ModelResourcesState?
        let modelResourceControls: (any ModelResourcesControlling)?
        let save: () async -> Bool

        public init(
            settings: SettingsState, settingsControls: any SettingsControlling,
            modelResources: ModelResourcesState?, modelResourceControls: (any ModelResourcesControlling)?,
            save: @escaping () async -> Bool
        ) {
            self.settings = settings
            self.settingsControls = settingsControls
            self.modelResources = modelResources
            self.modelResourceControls = modelResourceControls
            self.save = save
        }
        public var body: some View {
            Form {
                Section {
                    Toggle(
                        "使用云端大模型",
                        isOn: Binding(
                            get: { settings.isEnabled },
                            set: { settings.isEnabled = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.cloud.enabled")
                } footer: {
                    Text("关闭后使用本地 Gemma 4 E2B，需先下载模型。")
                }
                Section {
                    HStack {
                        TextField(
                            "https://api.openai.com/v1",
                            text: Binding(
                                get: { settings.url },
                                set: {
                                    settings.url = $0
                                    settingsControls.credentialsChanged()
                                })
                        )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("云端模型 URL")
                        .accessibilityIdentifier("settings.cloud.url")
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first {
                                settings.url = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                settingsControls.credentialsChanged()
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("粘贴 URL")
                        .accessibilityIdentifier("settings.cloud.url.paste")
                    }
                    HStack {
                        SecureField(
                            "API Key（可选）",
                            text: Binding(
                                get: { settings.key },
                                set: {
                                    settings.key = $0
                                    settingsControls.credentialsChanged()
                                })
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("settings.cloud.key")
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first {
                                settings.key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                settingsControls.credentialsChanged()
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("粘贴 Key")
                        .accessibilityIdentifier("settings.cloud.key.paste")
                    }
                    Button(action: settingsControls.loadModels) {
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
                if let modelResources, let modelResourceControls {
                    ModelResourceSections(state: modelResources, controls: modelResourceControls, group: .language)
                }
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
            .onDisappear { settingsControls.cancelDiscovery() }
        }
    }

#endif
