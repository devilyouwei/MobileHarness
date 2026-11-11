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
                Section("AI Models") {
                    destination(
                        .recognition, title: "Speech Recognition", icon: "waveform",
                        identifier: "settings.recognition.open")
                    destination(
                        .synthesis, title: "Speech Synthesis", icon: "speaker.wave.2",
                        identifier: "settings.synthesis.open")
                    destination(.language, title: "Agent Brains", icon: "brain", identifier: "settings.language.open")
                    destination(
                        .vision, title: "Vision Recognition", icon: "viewfinder", identifier: "settings.vision.open")
                }
                Section("External Devices") {
                    destination(
                        .bluetooth, title: "Bluetooth", icon: "bluetooth",
                        identifier: "settings.bluetooth.open")
                }
                Section("User") {
                    destination(.album, title: "Album", icon: "photo.on.rectangle", identifier: "settings.user.album")
                    destination(
                        .assistantHistory, title: "My Assistant", icon: "bubble.left.and.bubble.right",
                        identifier: "settings.assistant.records")
                    destination(
                        .writerHistory, title: "My Writer", icon: "pencil.and.outline",
                        identifier: "settings.writer.records")
                    Label("Memory", systemImage: "brain.head.profile")
                        .accessibilityIdentifier("settings.user.memory")
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preferredColorScheme(.dark)
        }
        private func destination(_ page: AppDestination, title: String, icon: String, identifier: String) -> some View {
            Button {
                navigate(page)
            } label: {
                HStack {
                    if page == .bluetooth {
                        Label {
                            Text(title)
                        } icon: {
                            BluetoothSymbol()
                                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                .frame(width: 18, height: 22)
                        }
                    } else {
                        Label(title, systemImage: icon)
                    }
                    Spacer()
                    if page == .bluetooth { Text(bluetooth.summary).foregroundStyle(.secondary).font(.subheadline) }
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier(identifier)
        }
    }

    private struct BluetoothSymbol: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.width * 0.4, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.width * 0.85, y: rect.height * 0.72))
            path.addLine(to: CGPoint(x: rect.width * 0.1, y: rect.height * 0.25))
            path.move(to: CGPoint(x: rect.width * 0.1, y: rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.width * 0.85, y: rect.height * 0.28))
            path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.minY))
            return path
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
        let modelResources: ModelResourcesState
        let modelResourceControls: any ModelResourcesControlling
        @Binding var providerDraft: [CloudSettingsDraft]?
        let save: (BrainSettingsChange) async -> Bool
        let navigate: (AgentBrain) -> Void
        @State private var restored = false

        private var providers: [CloudSettingsDraft] { providerDraft ?? settings.providers }

        public init(
            settings: SettingsState, settingsControls: any SettingsControlling,
            modelResources: ModelResourcesState, modelResourceControls: any ModelResourcesControlling,
            providerDraft: Binding<[CloudSettingsDraft]?>, save: @escaping (BrainSettingsChange) async -> Bool,
            navigate: @escaping (AgentBrain) -> Void
        ) {
            self.settings = settings
            self.settingsControls = settingsControls
            self.modelResources = modelResources
            self.modelResourceControls = modelResourceControls
            self._providerDraft = providerDraft
            self.save = save
            self.navigate = navigate
        }
        public var body: some View {
            Form {
                Section("Cloud Providers") {
                    ForEach(providers, id: \.id) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(provider.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deletingID = provider.id }
                            Button("编辑") {
                                providerEditor = ProviderEditorDraft(provider: provider, existing: providers)
                            }.tint(.blue)
                        }
                    }
                    Button("添加 Provider", systemImage: "plus.circle") {
                        providerEditor = ProviderEditorDraft(provider: nil, existing: providers)
                    }.disabled(!restored || providers.count >= 32)
                }
                Section("Agents") {
                    ForEach(AgentBrain.allCases) { brain in
                        Button {
                            navigate(brain)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(brain.title)
                                    if restored {
                                        Text(summary(brain)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.\(brain.rawValue).open")
                    }
                }
                ModelResourceSections(
                    state: modelResources, controls: modelResourceControls, group: .language, includesDecision: true)
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
                            let succeeded = await save(.providers(providers))
                            if succeeded { providerDraft = nil }
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
                    .disabled(!restored || settings.isSaving || providerDraft == nil)
                    .accessibilityIdentifier("settings.save")
                }
            }
            .sheet(item: $providerEditor) { draft in
                ProviderEditorView(initial: draft, existing: providers) { value in
                    var updated = providers
                    if let index = updated.firstIndex(where: { $0.id == value.id }) {
                        updated[index] = value
                    } else {
                        updated.append(value)
                    }
                    providerDraft = updated
                }
            }
            .alert(
                "删除 Provider？",
                isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }),
                presenting: deletingID
            ) { id in
                Button("取消", role: .cancel) { deletingID = nil }
                Button("删除", role: .destructive) {
                    providerDraft = providers.filter { $0.id != id }
                    deletingID = nil
                }
            } message: { _ in
                Text("保存后，引用此 Provider 的 Assistant 切回本地，Writer 显示未配置，Decision 清除云端引用。")
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
                    restored = true
                } catch {
                    if !Task.isCancelled {
                        settings.present(.error(error.localizedDescription))
                        toast = SaveToast(text: error.localizedDescription, succeeded: false)
                    }
                }
            }
        }

        private func summary(_ brain: AgentBrain) -> String {
            let choice = settings.brainDraft(brain)
            if choice.usesLocal {
                return brain == .decision ? "本地 · D3 Decision" : "本地 · Gemma 4 E2B"
            }
            guard let provider = settings.providers.first(where: { $0.id == choice.providerID }) else {
                return "未配置"
            }
            return [provider.name, choice.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @MainActor
    public struct AgentBrainSettingsView: View {
        private enum Selection: Hashable {
            case local
            case cloud(String)
            case unconfigured
        }

        @Bindable private var settings: SettingsState
        private let controls: any SettingsControlling
        private let resources: ModelResourcesState
        private let resourceControls: any ModelResourcesControlling
        private let brain: AgentBrain
        private let save: (BrainSettingsChange) async -> Bool
        @State private var draft: AgentBrainDraft?
        @State private var result: String?
        @State private var restoreError: String?

        public init(
            brain: AgentBrain, settings: SettingsState, controls: any SettingsControlling,
            resources: ModelResourcesState, resourceControls: any ModelResourcesControlling,
            save: @escaping (BrainSettingsChange) async -> Bool
        ) {
            self.brain = brain
            self.settings = settings
            self.controls = controls
            self.resources = resources
            self.resourceControls = resourceControls
            self.save = save
        }

        public var body: some View {
            Form {
                if let draft {
                    configuration(draft)
                    if let result { Text(result).foregroundStyle(.secondary) }
                    if let error = settings.error { Text(error).foregroundStyle(.red) }
                } else if let restoreError {
                    Text(restoreError).foregroundStyle(.red)
                    Button("重新加载配置") { Task { await restore() } }
                } else {
                    ProgressView()
                }
            }
            .disabled(settings.isSaving)
            .navigationTitle(brain.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.isSaving ? "正在保存…" : "保存") {
                        guard let draft else { return }
                        Task {
                            result = nil
                            if await save(.brain(brain, draft)) { result = "保存成功" }
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("settings.\(brain.rawValue).save")
                }
            }
            .task { await restore() }
            .task {
                if brain != .writer { await resourceControls.restore() }
            }
            .onDisappear { controls.cancelDiscovery() }
        }

        private var canSave: Bool {
            guard !settings.isSaving, let draft, draft != settings.brainDraft(brain) else { return false }
            return draft.providerID == nil || !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        @ViewBuilder private func configuration(_ choice: AgentBrainDraft) -> some View {
            Section {
                Picker("Provider", selection: Binding(get: { selection }, set: select)) {
                    if brain != .assistant { Text("未配置").tag(Selection.unconfigured) }
                    Text(brain == .decision ? "本地 D3" : "本地 Gemma 4 E2B").tag(Selection.local)
                        .disabled(
                            brain == .writer
                                || (brain == .decision && !choice.usesLocal
                                    && !resources.installedGroups.contains(.decision))
                        )
                    ForEach(settings.providers, id: \.id) { provider in
                        Text(provider.name).tag(Selection.cloud(provider.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.\(brain.rawValue).provider")
                if !choice.usesLocal, let id = choice.providerID { modelPicker(id) }
                if brain == .writer, choice.providerID != nil {
                    Toggle(
                        "深度思考",
                        isOn: Binding(
                            get: { draft?.writerThinking ?? false },
                            set: {
                                draft?.writerThinking = $0
                                result = nil
                            })
                    )
                    .accessibilityIdentifier("settings.writer.thinking")
                }
            } footer: {
                Text(details(choice))
            }
            if brain == .decision {
                if choice.usesLocal {
                    Section("云端备用") {
                        Picker(
                            "Provider",
                            selection: Binding(
                                get: { draft?.providerID }, set: setCloudProvider)
                        ) {
                            Text("无备用").tag(String?.none)
                            ForEach(settings.providers, id: \.id) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("settings.decision.fallback.provider")
                        if let id = choice.providerID { modelPicker(id) }
                    }
                }
                Section("最近决策路径") {
                    Text(resources.decisionStatus).foregroundStyle(.secondary)
                }
            }
        }

        private func modelPicker(_ id: String) -> some View {
            ProviderModelPicker(
                settings: settings, controls: controls, providerID: id,
                model: Binding(
                    get: { draft?.model ?? "" },
                    set: {
                        draft?.model = $0
                        result = nil
                    }),
                identifier: "settings.\(brain.rawValue).model")
        }

        private func details(_ choice: AgentBrainDraft) -> String {
            switch brain {
            case .assistant:
                return choice.usesLocal && !resources.installedGroups.contains(.language)
                    ? "请在 Agent Brains 下载 Gemma 4 E2B。"
                    : "对话协调模型，默认关闭思考；无法关闭时使用最低思考档位。"
            case .writer:
                return "本地 Gemma 缺少 Writer 所需的原生工具调用。深度思考设置用于新建或续作委托。"
            case .decision:
                return !resources.installedGroups.contains(.decision)
                    ? "可在 Agent Brains 下载 D3。云端模型需支持工具调用；不可用时保留输入并排队。"
                    : "云端模型需支持工具调用。本地 D3 不可用时使用已保存的云端备用。"
            }
        }

        private var selection: Selection {
            guard let draft else { return .unconfigured }
            if draft.usesLocal { return .local }
            return draft.providerID.map(Selection.cloud) ?? .unconfigured
        }
        private func select(_ selection: Selection) {
            switch selection {
            case .local:
                guard brain != .writer else { return }
                guard brain != .decision || draft?.usesLocal == true || resources.installedGroups.contains(.decision)
                else { return }
                draft?.usesLocal = true
                if brain == .assistant { setCloudProvider(nil) }
            case .cloud(let id):
                draft?.usesLocal = false
                setCloudProvider(id)
            case .unconfigured:
                draft?.usesLocal = false
                setCloudProvider(nil)
            }
            result = nil
        }
        private func setCloudProvider(_ id: String?) {
            if draft?.providerID != id {
                draft?.providerID = id
                draft?.model = ""
            }
            result = nil
            if let id { controls.loadModels(providerID: id) }
        }

        private func restore() async {
            do {
                try await controls.restore()
                try Task.checkCancellation()
                if draft == nil { draft = settings.brainDraft(brain) }
                if let id = draft?.providerID { controls.loadModels(providerID: id) }
                restoreError = nil
            } catch {
                if !Task.isCancelled { restoreError = error.localizedDescription }
            }
        }
    }

    /// Shared discovery and selection rendering for Agent Brains and Decision.
    @MainActor
    struct ProviderModelPicker: View {
        @Bindable var settings: SettingsState
        let controls: any SettingsControlling
        let providerID: String
        @Binding var model: String
        let identifier: String
        var body: some View {
            let values = settings.modelCatalogs[providerID] ?? []
            Picker("模型", selection: $model) {
                Text("请选择模型").tag("")
                if !model.isEmpty && !values.contains(model) { Text(model).tag(model) }
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(identifier)
            if settings.loadingProviderIDs.contains(providerID) {
                HStack {
                    ProgressView()
                    Text("正在加载模型…").foregroundStyle(.secondary)
                }
            } else if let error = settings.modelErrors[providerID] {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重新加载模型") { controls.loadModels(providerID: providerID) }
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
