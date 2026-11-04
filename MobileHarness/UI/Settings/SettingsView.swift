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
                    destination(.language, title: "智能体大脑", icon: "brain", identifier: "settings.language.open")
                    destination(.vision, title: "视觉识别", icon: "viewfinder", identifier: "settings.vision.open")
                }
                Section("外接设备") {
                    destination(
                        .bluetooth, title: "蓝牙外设", icon: "antenna.radiowaves.left.and.right",
                        identifier: "settings.bluetooth.open")
                }
                Section("用户") {
                    Label("记忆", systemImage: "brain.head.profile")
                        .accessibilityIdentifier("settings.user.memory")
                    destination(.album, title: "相册", icon: "photo.on.rectangle", identifier: "settings.user.album")
                    destination(
                        .assistantHistory, title: "Assistant 聊天记录", icon: "bubble.left.and.bubble.right",
                        identifier: "settings.assistant.records")
                    destination(
                        .writerHistory, title: "Writer 任务记录", icon: "pencil.and.outline",
                        identifier: "settings.writer.records")
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
        @State private var deletingID: String?
        @State private var toast: SaveToast?

        private struct SaveToast: Identifiable {
            let id = UUID()
            let text: String
            let succeeded: Bool
        }
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
                Section("Provider") {
                    ForEach(settings.providers, id: \.id) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(provider.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deletingID = provider.id }
                            Button("编辑") {
                                providerEditor = ProviderEditorDraft(provider: provider, existing: settings.providers)
                            }.tint(.blue)
                        }
                    }
                    Button("添加 Provider", systemImage: "plus.circle") {
                        providerEditor = ProviderEditorDraft(provider: nil, existing: settings.providers)
                    }.disabled(settings.providers.count >= 32)
                }
                agentSection(writer: false)
                agentSection(writer: true)
                if let modelResources, let modelResourceControls {
                    ModelResourceSections(state: modelResources, controls: modelResourceControls, group: .language)
                }
            }
            .disabled(settings.isSaving)
            .navigationTitle("智能体大脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            // Keep native back navigation mounted; the App-owned save continues across navigation.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            toast = nil
                            let succeeded = await save()
                            toast = SaveToast(
                                text: succeeded ? "保存成功" : (settings.error ?? "保存失败，请重试"),
                                succeeded: succeeded
                            )
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
                    settings.upsertProvider(value)
                    if settings.assistantProviderID == value.id || settings.writerProviderID == value.id {
                        settingsControls.loadModels(providerID: value.id)
                    }
                }
            }
            .alert(
                "删除 Provider？",
                isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }),
                presenting: deletingID
            ) { id in
                Button("取消", role: .cancel) { deletingID = nil }
                Button("删除", role: .destructive) {
                    settings.removeProvider(id)
                    deletingID = nil
                }
            } message: { _ in
                Text("删除后，使用它的智能体将改为本地模型，保存后生效。")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(
                        toast.text,
                        systemImage: toast.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(toast.succeeded ? Color.primary : Color.red)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                    .accessibilityIdentifier("settings.saveToast")
                    .allowsHitTesting(false)
                }
            }
            .task(id: toast?.id) {
                guard let current = toast else { return }
                do { try await Task.sleep(for: .seconds(current.succeeded ? 3 : 6)) } catch { return }
                if toast?.id == current.id { toast = nil }
            }
            .task {
                do {
                    try await settingsControls.restore()
                    try Task.checkCancellation()
                    settingsControls.refreshModels()
                } catch {
                    if !Task.isCancelled {
                        settings.present(.error(error.localizedDescription))
                        toast = SaveToast(text: error.localizedDescription, succeeded: false)
                    }
                }
            }
            .onDisappear { settingsControls.cancelDiscovery() }
        }
        @ViewBuilder private func agentSection(writer: Bool) -> some View {
            let selected = writer ? settings.writerProviderID : settings.assistantProviderID
            let model = writer ? settings.writerModel : settings.selectedModel
            Section {
                Picker(
                    "Provider",
                    selection: Binding<String?>(
                        get: { writer ? settings.writerProviderID : settings.assistantProviderID },
                        set: { id in
                            if writer {
                                settings.selectWriterProvider(id)
                            } else {
                                settings.selectAssistantProvider(id)
                            }
                            if let id { settingsControls.loadModels(providerID: id) }
                        })
                ) {
                    Text("本地模型").tag(String?.none)
                    ForEach(settings.providers, id: \.id) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(writer ? "settings.writer.provider" : "settings.assistant.provider")
                if let id = selected {
                    let values = settings.modelCatalogs[id] ?? []
                    Picker(
                        "模型",
                        selection: Binding(
                            get: { writer ? settings.writerModel : settings.selectedModel },
                            set: { if writer { settings.writerModel = $0 } else { settings.selectedModel = $0 } })
                    ) {
                        Text("请选择模型").tag("")
                        if !model.isEmpty && !values.contains(model) { Text(model).tag(model) }
                        ForEach(values, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(writer ? "settings.writer.model" : "settings.assistant.model")
                    if writer {
                        Toggle(
                            "深度思考",
                            isOn: Binding(get: { settings.writerThinking }, set: { settings.writerThinking = $0 })
                        )
                        .accessibilityIdentifier("settings.writer.thinking")
                    }
                    if settings.loadingProviderIDs.contains(id) {
                        HStack {
                            ProgressView()
                            Text("正在加载模型…").foregroundStyle(.secondary)
                        }
                    } else if let error = settings.modelErrors[id] {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("重新加载模型") { settingsControls.loadModels(providerID: id) }
                    }
                }
            } header: {
                Text(writer ? "Writer Agent" : "Assistant Agent")
            } footer: {
                Text(
                    writer
                        ? (selected == nil
                            ? "本地 Gemma 当前不支持 Writer 所需的原生工具调用，请选择支持工具的 Provider。"
                            : "默认关闭或使用最低思考，优先响应速度；可开启深度思考。保存后用于新建或续作委托，当前执行保持原配置。")
                        : "对话协调模型，默认关闭思考；无法关闭时使用最低思考档位。")
            }
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
