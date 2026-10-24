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
        @State private var providerEditor: ProviderEditorDraft?
        @State private var deletingURL: String?
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
                    ForEach(settings.providers, id: \.url) { provider in
                        HStack {
                            Button {
                                if let index = settings.providers.firstIndex(where: { $0.url == settings.url }) {
                                    settings.providers[index].model = settings.selectedModel
                                }
                                settingsControls.cancelDiscovery()
                                settings.url = provider.url
                                settings.key = provider.key
                                settings.selectedModel = provider.model
                                settings.models = provider.model.isEmpty ? [] : [provider.model]
                                settings.isEnabled = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: settings.url == provider.url ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(provider.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            .lineLimit(1).truncationMode(.tail)
                                        Text(provider.url).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                }
                                .contentShape(Rectangle())
                            }
                            Spacer()
                            Button {
                                var value = provider
                                if settings.url == value.url { value.model = settings.selectedModel }
                                providerEditor = ProviderEditorDraft(provider: value, existing: settings.providers)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("编辑 \(provider.name)")
                            Button(role: .destructive) {
                                deletingURL = provider.url
                            } label: {
                                Image(systemName: "trash")
                            }.accessibilityLabel("删除 \(provider.name)")
                        }.buttonStyle(.borderless)
                    }
                    Button("添加 Provider", systemImage: "plus.circle") {
                        providerEditor = ProviderEditorDraft(provider: nil, existing: settings.providers)
                    }.disabled(settings.providers.count >= 32)
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
                    Text("一个 URL 对应一个 Provider。选择和编辑后，点击保存应用配置。")
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
            .sheet(item: $providerEditor) { draft in
                ProviderEditorView(initial: draft, existing: settings.providers) { value in
                    if let index = settings.providers.firstIndex(where: { $0.url == settings.url }) {
                        settings.providers[index].model = settings.selectedModel
                    }
                    if let index = settings.providers.firstIndex(where: { $0.url == draft.originalURL }) {
                        settings.providers[index] = value
                    } else {
                        settings.providers.append(value)
                    }
                    if draft.originalURL == nil || settings.url == draft.originalURL {
                        settingsControls.cancelDiscovery()
                        settings.url = value.url
                        settings.key = value.key
                        settings.selectedModel = value.model
                        settings.models = value.model.isEmpty ? [] : [value.model]
                    }
                }
            }
            .confirmationDialog(
                "删除此 Provider？删除当前项将关闭云端，保存后生效。",
                isPresented: Binding(get: { deletingURL != nil }, set: { if !$0 { deletingURL = nil } })
            ) {
                Button("删除", role: .destructive) {
                    guard let url = deletingURL else { return }
                    settings.providers.removeAll { $0.url == url }
                    if settings.url == url {
                        settingsControls.cancelDiscovery()
                        settings.url = ""
                        settings.key = ""
                        settings.isEnabled = false
                        settings.selectedModel = ""
                        settings.models = []
                    }
                    deletingURL = nil
                }
            }
            .onDisappear { settingsControls.cancelDiscovery() }
        }
    }

    @MainActor
    private struct ProviderEditorView: View {
        @Environment(\.dismiss) private var dismiss
        @State var draft: ProviderEditorDraft
        @State private var error: String?
        let existing: [CloudSettingsDraft]
        let confirm: (CloudSettingsDraft) -> Void
        init(
            initial: ProviderEditorDraft, existing: [CloudSettingsDraft],
            confirm: @escaping (CloudSettingsDraft) -> Void
        ) {
            _draft = State(initialValue: initial)
            self.existing = existing
            self.confirm = confirm
        }
        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        HStack {
                            TextField("名称", text: $draft.name)
                                .accessibilityIdentifier("settings.cloud.name")
                            pasteButton("名称", text: $draft.name)
                        }
                        HStack {
                            TextField("URL（可选，默认 OpenAI）", text: $draft.url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("服务 URL，可选，留空使用 OpenAI")
                                .accessibilityIdentifier("settings.cloud.url")
                            pasteButton("URL", text: $draft.url)
                        }
                        HStack {
                            SecureField("API Key（可选）", text: $draft.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .accessibilityIdentifier("settings.cloud.key")
                            pasteButton("Key", text: $draft.key)
                        }
                    } footer: {
                        Text("URL 留空时使用 OpenAI 官方服务。确认后返回列表，点击页面上的保存应用配置。")
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                .navigationTitle(draft.originalURL == nil ? "添加 Provider" : "编辑 Provider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            do {
                                let value = try draft.validated(existing: existing)
                                confirm(value)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        private func pasteButton(_ title: String, text: Binding<String>) -> some View {
            PasteButton(payloadType: String.self) { values in
                if let value = values.first {
                    text.wrappedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("粘贴 \(title)")
        }
    }

#endif
