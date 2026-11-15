#if os(iOS)
    import SwiftUI

    /// Native feature list. Route selection crosses the injected Agent intent interface.
    @MainActor
    public struct SettingsView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let bluetooth: BluetoothSettingsState
        let navigate: (AppDestination) -> Void
        let languagePreference: Binding<AppLanguagePreference>?
        public init(
            bluetooth: BluetoothSettingsState, languagePreference: Binding<AppLanguagePreference>? = nil,
            navigate: @escaping (AppDestination) -> Void
        ) {
            self.bluetooth = bluetooth
            self.languagePreference = languagePreference
            self.navigate = navigate
        }
        public var body: some View {
            List {
                if let languagePreference {
                    Picker(selection: languagePreference) {
                        Text(appCopy.text("System")).tag(AppLanguagePreference.system)
                        Text(verbatim: "简体中文").tag(AppLanguagePreference.simplifiedChinese)
                        Text(verbatim: "English").tag(AppLanguagePreference.english)
                    } label: {
                        Label(appCopy.text("App Language"), systemImage: "globe")
                    }
                    .accessibilityIdentifier("settings.appLanguage")
                }
                Section(appCopy.text("AI Models")) {
                    destination(
                        .recognition, title: "Speech Recognition", icon: "waveform",
                        identifier: "settings.recognition.open")
                    destination(
                        .synthesis, title: "Speech Synthesis", icon: "speaker.wave.2",
                        identifier: "settings.synthesis.open")
                    destination(.language, title: "Agent Models", icon: "atom", identifier: "settings.language.open")
                    destination(
                        .vision, title: "Vision Recognition", icon: "viewfinder", identifier: "settings.vision.open")
                }
                Section(appCopy.text("External Devices")) {
                    destination(
                        .bluetooth, title: "Bluetooth", icon: "bluetooth",
                        identifier: "settings.bluetooth.open")
                }
                Section(appCopy.text("User")) {
                    destination(.album, title: "Album", icon: "photo.on.rectangle", identifier: "settings.user.album")
                    destination(
                        .assistantHistory, title: "My Assistant", icon: "bubble.left.and.bubble.right",
                        identifier: "settings.assistant.records")
                    destination(
                        .writerHistory, title: "My Writer", icon: "pencil.and.outline",
                        identifier: "settings.writer.records")
                    Label(appCopy.text("Memory"), systemImage: "brain.head.profile")
                        .accessibilityIdentifier("settings.user.memory")
                }
            }
            .navigationTitle(appCopy.text("Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preferredColorScheme(.dark)
        }
        private func destination(_ page: AppDestination, title: String, icon: String, identifier: String) -> some View {
            Button {
                navigate(page)
            } label: {
                HStack {
                    if page == .bluetooth {
                        Label {
                            Text(appCopy.text(title))
                        } icon: {
                            BluetoothSymbol()
                                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                .frame(width: 18, height: 22)
                        }
                    } else {
                        Label(appCopy.text(title), systemImage: icon)
                    }
                    Spacer()
                    if page == .bluetooth {
                        Text(appCopy.text(bluetooth.summary)).foregroundStyle(.secondary).font(.subheadline)
                    }
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
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                Section(appCopy.text("Cloud Providers & Models")) {
                    ForEach(providers, id: \.id) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(provider.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(appCopy.text("Delete"), role: .destructive) { deletingID = provider.id }
                            Button(appCopy.text("Edit")) {
                                providerEditor = ProviderEditorDraft(provider: provider, existing: providers)
                            }.tint(.blue)
                        }
                    }
                    Button(appCopy.text("Add Provider"), systemImage: "plus.circle") {
                        providerEditor = ProviderEditorDraft(provider: nil, existing: providers)
                    }.disabled(!restored || providers.count >= 32)
                }
                Section(appCopy.text("Agent Models")) {
                    ForEach(AgentBrain.allCases) { brain in
                        Button {
                            navigate(brain)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(appCopy.text(brain.title))
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
            .navigationTitle(appCopy.text("Agent Models"))
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
                                text: succeeded
                                    ? appCopy.text("Saved successfully")
                                    : (settings.error ?? appCopy.text("Could not save. Try again.")),
                                succeeded: succeeded
                            )
                        }
                    } label: {
                        Text(appCopy.text("Save"))
                            .opacity(settings.isSaving ? 0 : 1)
                            .overlay {
                                ProgressView().opacity(settings.isSaving ? 1 : 0)
                            }
                            .accessibilityLabel(settings.isSaving ? appCopy.text("Saving") : appCopy.text("Save"))
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
                appCopy.text("Delete provider?"),
                isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }),
                presenting: deletingID
            ) { id in
                Button(appCopy.text("Cancel"), role: .cancel) { deletingID = nil }
                Button(appCopy.text("Delete"), role: .destructive) {
                    providerDraft = providers.filter { $0.id != id }
                    deletingID = nil
                }
            } message: { _ in
                Text(
                    appCopy.text(
                        "After saving, Assistant will switch to its local model, Writer will be unconfigured, and Decision will clear this cloud provider."
                    ))
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
                if brain == .decision {
                    return choice.decisionLocalModelID == "d3-lite"
                        ? appCopy.text("Local · D3 Lite") : appCopy.text("Local · D3 Edge")
                }
                return appCopy.text("Local · Gemma 4 E2B")
            }
            guard let provider = settings.providers.first(where: { $0.id == choice.providerID }) else {
                return appCopy.text("Unconfigured")
            }
            return [provider.name, choice.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @MainActor
    public struct AgentBrainSettingsView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
        @State private var selectionError: String?
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
                    if let selectionError { Text(appCopy.text(selectionError)).foregroundStyle(.red) }
                    if let result { Text(result).foregroundStyle(.secondary) }
                    if let error = settings.error { Text(appCopy.text(error)).foregroundStyle(.red) }
                } else if let restoreError {
                    Text(appCopy.text(restoreError)).foregroundStyle(.red)
                    Button(appCopy.text("Reload settings")) { Task { await restore() } }
                } else {
                    ProgressView()
                }
            }
            .disabled(settings.isSaving)
            .navigationTitle(appCopy.text(brain.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.isSaving ? appCopy.text("Saving…") : appCopy.text("Save")) {
                        guard let draft else { return }
                        Task {
                            result = nil
                            guard validateLocalSelection(draft) else { return }
                            if await save(.brain(brain, draft)) { result = appCopy.text("Saved successfully") }
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("settings.\(brain.rawValue).save")
                }
            }
            .task { await restore() }
            .task { await resourceControls.restore() }
            .onDisappear { controls.cancelDiscovery() }
        }

        private var canSave: Bool {
            guard !settings.isSaving, let draft, draft != settings.brainDraft(brain) else { return false }
            return draft.usesLocal || draft.providerID == nil
                || !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        @ViewBuilder private func configuration(_ choice: AgentBrainDraft) -> some View {
            Section {
                Picker(appCopy.text("Provider"), selection: Binding(get: { selection }, set: select)) {
                    if brain != .assistant { Text(appCopy.text("Unconfigured")).tag(Selection.unconfigured) }
                    Text(appCopy.text("Local")).tag(Selection.local)
                    ForEach(settings.providers, id: \.id) { provider in
                        Text(provider.name).tag(Selection.cloud(provider.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.\(brain.rawValue).provider")
                if choice.usesLocal {
                    Picker(
                        appCopy.text("Model"),
                        selection: Binding(
                            get: { localModelID(choice) }, set: selectLocalModel)
                    ) {
                        if brain == .decision {
                            Text("D3 Edge").tag("d3-edge")
                            Text("D3 Lite").tag("d3-lite")
                        } else {
                            Text("Gemma 4 E2B").tag("gemma4-e2b")
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("settings.\(brain.rawValue).model")
                } else if let id = choice.providerID {
                    modelPicker(id)
                }
                if brain == .writer, choice.providerID != nil {
                    Toggle(
                        appCopy.text("Extended thinking"),
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
                Section(appCopy.text("Latest decision route")) {
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
                    ? appCopy.text("Download Gemma 4 E2B in Agent Models.")
                    : appCopy.text("Thinking is off by default. If the model requires it, the lowest setting is used.")
            case .writer:
                return appCopy.text(
                    "Local Gemma supports tool calls within its context limit. Extended thinking applies to cloud models on new or resumed assignments."
                )
            case .decision:
                return appCopy.text(
                    "Only the selected model is used. If it fails, an error is shown and input is queued.")
            }
        }

        private func localModelID(_ choice: AgentBrainDraft) -> String {
            brain == .decision ? choice.decisionLocalModelID : "gemma4-e2b"
        }

        private func validateLocalSelection(_ choice: AgentBrainDraft) -> Bool {
            guard choice.usesLocal else { return true }
            guard resources.items.contains(where: { $0.id == localModelID(choice) && $0.installed }) else {
                selectionError = "This local model is not downloaded. Download it in Agent Models first."
                return false
            }
            selectionError = nil
            return true
        }

        private func selectLocalModel(_ id: String) {
            guard var choice = draft else { return }
            choice.decisionLocalModelID = id
            guard validateLocalSelection(choice) else { return }
            draft = choice
            result = nil
        }

        private var selection: Selection {
            guard let draft else { return .unconfigured }
            if draft.usesLocal { return .local }
            return draft.providerID.map(Selection.cloud) ?? .unconfigured
        }
        private func select(_ selection: Selection) {
            switch selection {
            case .local:
                draft?.usesLocal = true
                setCloudProvider(nil)
                if let draft { _ = validateLocalSelection(draft) }
            case .cloud(let id):
                selectionError = nil
                draft?.usesLocal = false
                setCloudProvider(id)
            case .unconfigured:
                selectionError = nil
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
                if draft == nil {
                    draft = settings.brainDraft(brain)
                    if draft?.usesLocal == true {
                        draft?.providerID = nil
                        draft?.model = ""
                    }
                }
                if draft?.usesLocal == false, let id = draft?.providerID { controls.loadModels(providerID: id) }
                restoreError = nil
            } catch {
                if !Task.isCancelled { restoreError = error.localizedDescription }
            }
        }
    }

    /// Shared discovery and selection rendering for Agent Models and Decision.
    @MainActor
    struct ProviderModelPicker: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable var settings: SettingsState
        let controls: any SettingsControlling
        let providerID: String
        @Binding var model: String
        let identifier: String
        var body: some View {
            let values = settings.modelCatalogs[providerID] ?? []
            Picker(appCopy.text("Model"), selection: $model) {
                Text(appCopy.text("Select a model")).tag("")
                if !model.isEmpty && !values.contains(model) { Text(model).tag(model) }
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(identifier)
            if settings.loadingProviderIDs.contains(providerID) {
                HStack {
                    ProgressView()
                    Text(appCopy.text("Loading models…")).foregroundStyle(.secondary)
                }
            } else if let error = settings.modelErrors[providerID] {
                Text(appCopy.text(error)).font(.caption).foregroundStyle(.red)
                Button(appCopy.text("Reload models")) { controls.loadModels(providerID: providerID) }
            }
        }
    }

    @MainActor
    private struct ProviderEditorView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                            TextField(appCopy.text("Name"), text: $draft.name)
                                .accessibilityIdentifier("settings.cloud.name")
                            pasteButton(appCopy.text("Name"), text: $draft.name)
                        }
                        HStack {
                            TextField(appCopy.text("URL (optional, defaults to OpenAI)"), text: $draft.url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel(appCopy.text("Service URL. Leave blank to use OpenAI."))
                                .accessibilityIdentifier("settings.cloud.url")
                            pasteButton("URL", text: $draft.url)
                        }
                        HStack {
                            SecureField(appCopy.text("API key (optional)"), text: $draft.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .accessibilityIdentifier("settings.cloud.key")
                            pasteButton("Key", text: $draft.key)
                        }
                    } footer: {
                        Text(
                            appCopy.text(
                                "Leave the URL blank to use OpenAI. Confirm, then select Save on the provider list to apply the configuration."
                            ))
                    }
                    if let error { Section { Text(appCopy.text(error)).foregroundStyle(.red) } }
                }
                .navigationTitle(
                    draft.originalURL == nil ? appCopy.text("Add Provider") : appCopy.text("Edit Provider")
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(appCopy.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(appCopy.text("Confirm")) {
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
            .accessibilityLabel(appCopy.format("Paste %@", String(describing: title)))
        }
    }

#endif
