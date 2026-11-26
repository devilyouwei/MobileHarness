#if os(iOS)
    import SwiftUI

    @MainActor
    public struct ModelResourcesView: View {
        @Environment(\.locale) private var appCopyLocale
        @Environment(\.scenePhase) private var scenePhase
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable private var state: ModelResourcesState
        private let controls: any ModelResourcesControlling
        private let group: ModelResourceGroup
        private let audioDetection: AudioDetectionState?
        private let audioDetectionRequests: (UIRequests<AudioDetectionInput, Void>)?
        public init(
            state: ModelResourcesState, controls: any ModelResourcesControlling, group: ModelResourceGroup,
            audioDetection: AudioDetectionState? = nil,
            audioDetectionRequests: (UIRequests<AudioDetectionInput, Void>)? = nil
        ) {
            self.state = state
            self.controls = controls
            self.group = group
            self.audioDetection = audioDetection
            self.audioDetectionRequests = audioDetectionRequests
        }
        private var isSpeech: Bool { group == .recognition || group == .synthesis }

        public var body: some View {
            Form {
                if isSpeech {
                    if let audioDetection, let audioDetectionRequests {
                        AudioDetectionSection(state: audioDetection, requests: audioDetectionRequests)
                    }
                    ForEach(SpeechCapability.allCases, id: \.rawValue) { capability in
                        Section {
                            speechPicker(capability)
                            if capability == .voiceActivity {
                                SpeechDetectionSettings(state: state, controls: controls)
                            }
                            if capability == .keywordSpotting {
                                KeywordDetectionSettings(
                                    state: state, controls: controls,
                                    enabled: keywordModelSelected
                                        && !(audioDetection?.isActive == true
                                            && audioDetection?.snapshot.keywordTest == true)
                                )
                                if let audioDetection, let audioDetectionRequests {
                                    KeywordDetectionControls(
                                        state: audioDetection, requests: audioDetectionRequests,
                                        modelSelected: keywordModelSelected)
                                }
                            }
                            if capability == .synthesis, let voices = selectedSynthesisVoices {
                                synthesisPickers(voices)
                            }
                        } header: {
                            Text(appCopy.text(capability.title))
                        } footer: {
                            if capability == .voiceActivity {
                                Text(
                                    appCopy.text(
                                        "Higher values reduce false triggers but may delay or miss short speech. Applies the next time listening starts."
                                    ))
                            }
                            if capability == .keywordSpotting {
                                Text(
                                    appCopy.text(
                                        "Lower values make keywords easier to detect. Applies the next time listening or testing starts."
                                    ))
                            }
                        }
                    }
                }
                ModelResourceSections(state: state, controls: controls, group: group)
            }
            .task { if isSpeech { await controls.restore() } }
            .onDisappear { stopDetection() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stopDetection() } }
            .navigationTitle(appCopy.text(isSpeech ? "Speech" : group == .vision ? "Vision" : group.title))
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                appCopy.text("Install the model first"),
                isPresented: Binding(
                    get: { state.installationNotice != nil }, set: { if !$0 { state.installationNotice = nil } })
            ) {
                Button(appCopy.text("OK"), role: .cancel) { state.installationNotice = nil }
            } message: {
                Text(appCopy.text(state.installationNotice ?? ""))
            }
        }

        private func stopDetection() {
            guard isSpeech, let audioDetectionRequests else { return }
            Task { try? await audioDetectionRequests.submitControl(.stop) }
        }

        private var keywordModelSelected: Bool {
            guard state.hasRestored, !state.saving,
                let selected = state.source.speechModels?[SpeechCapability.keywordSpotting.rawValue], selected != "off",
                let option = state.speechOptions(for: .keywordSpotting).first(where: { $0.id == selected })
            else { return false }
            return isAvailable(option)
        }

        private func speechPicker(_ capability: SpeechCapability) -> some View {
            let options = state.speechOptions(for: capability)
            let selection = Binding(
                get: { state.source.speechModels?[capability.rawValue] ?? options.first?.id ?? "" },
                set: { id in Task { await controls.selectSpeechModel(id, for: capability) } })
            return Picker(appCopy.text("Model"), selection: selection) {
                if options.isEmpty { Text(appCopy.text("Loading…")).tag("") }
                ForEach(options) { option in
                    let available = isAvailable(option)
                    Text(
                        available
                            ? appCopy.text(option.title)
                            : appCopy.format("%@ (not installed)", appCopy.text(option.title))
                    )
                    .tag(option.id)
                    .disabled(!available)
                }
            }
            .pickerStyle(.menu)
            .disabled(
                state.saving || !state.hasRestored || options.isEmpty
                    || (capability == .keywordSpotting && audioDetection?.isActive == true
                        && audioDetection?.snapshot.keywordTest == true)
            )
            .accessibilityIdentifier("settings.speech.\(capability.rawValue).model")
        }

        private var selectedSynthesisVoices: [String: [String]]? {
            let selected = state.source.speechModels?[SpeechCapability.synthesis.rawValue]
            return state.speechOptions(for: .synthesis).first { $0.id == selected }?.voicesByLanguage
        }

        private func synthesisPickers(_ voices: [String: [String]]) -> some View {
            let languages = voices.keys.sorted()
            let selected = state.source.synthesisVoice
            let language =
                languages.first { key in selected.map { voices[key]?.contains($0) == true } ?? false }
                ?? languages.first ?? ""
            let options = voices[language] ?? []
            let voice = selected.flatMap { options.contains($0) ? $0 : nil } ?? options.first ?? ""
            return Group {
                Picker(
                    appCopy.text("Voice language"),
                    selection: Binding(
                        get: { language },
                        set: { language in
                            if let voice = voices[language]?.first {
                                Task { await controls.selectSynthesisVoice(voice) }
                            }
                        })
                ) {
                    ForEach(languages, id: \.self) { language in
                        Text(appCopy.text(language == "zh" ? "Mandarin Chinese" : "English")).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.speech.synthesis.language")
                Picker(
                    appCopy.text("Voice"),
                    selection: Binding(get: { voice }, set: { id in Task { await controls.selectSynthesisVoice(id) } })
                ) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("settings.speech.synthesis.voice")
            }
            .pickerStyle(.menu)
            .disabled(state.saving || !state.hasRestored)
        }

        private func isAvailable(_ option: SpeechModelChoice) -> Bool {
            guard let artifact = option.artifactID else { return true }
            return state.items.contains { $0.id == artifact && $0.installed && !state.isBusy($0) }
        }
    }

    @MainActor
    private struct KeywordDetectionSettings: View {
        @Environment(\.locale) private var locale
        @Bindable var state: ModelResourcesState
        let controls: any ModelResourcesControlling
        let enabled: Bool
        @State private var threshold = 0.25

        private var copy: AppLanguage { AppLanguage(preferredLanguage: locale.identifier) }

        var body: some View {
            VStack(alignment: .leading) {
                Text(copy.format("Keyword confidence threshold: %.2f", threshold))
                Slider(value: $threshold, in: 0.10...0.60, step: 0.05, onEditingChanged: save)
                    .accessibilityLabel(copy.text("Keyword confidence threshold"))
                    .accessibilityIdentifier("settings.speech.keywordSpotting.threshold")
            }
            .disabled(!enabled)
            .onAppear(perform: restore)
            .onChange(of: state.source.keywordThreshold) { _, _ in restore() }
        }

        private func restore() { threshold = state.source.keywordThreshold }

        private func save(_ editing: Bool) {
            guard !editing else { return }
            let selected = (threshold * 20).rounded() / 20
            Task {
                await controls.setKeywordThreshold(selected)
                restore()
            }
        }
    }

    @MainActor
    private struct SpeechDetectionSettings: View {
        @Environment(\.locale) private var locale
        @Bindable var state: ModelResourcesState
        let controls: any ModelResourcesControlling
        @State private var windows = 8.0
        @State private var threshold = 0.65
        private var copy: AppLanguage { AppLanguage(preferredLanguage: locale.identifier) }
        private func restore() {
            windows = Double(state.source.vadOnsetWindows)
            threshold = state.source.vadThreshold
        }
        private func save(_ editing: Bool) {
            guard !editing else { return }
            let count = Int(windows.rounded())
            let probability = (threshold * 20).rounded() / 20
            Task {
                await controls.setSpeechDetection(windows: count, threshold: probability)
                restore()
            }
        }
        var body: some View {
            Group {
                VStack(alignment: .leading) {
                    Text(copy.format("Speech onset: %d windows (%d ms)", Int(windows), Int(windows) * 32))
                    Slider(value: $windows, in: 1...16, step: 1, onEditingChanged: save)
                        .accessibilityLabel(copy.text("Speech onset windows"))
                        .accessibilityIdentifier("settings.recognition.onsetWindows")
                }
                VStack(alignment: .leading) {
                    Text(copy.format("Speech probability threshold: %.2f", threshold))
                    Slider(value: $threshold, in: 0.05...0.95, step: 0.05, onEditingChanged: save)
                        .accessibilityLabel(copy.text("Speech probability threshold"))
                        .accessibilityIdentifier("settings.recognition.vadThreshold")
                }
            }
            .disabled(state.saving || !state.hasRestored)
            .onAppear(perform: restore)
            .onChange(of: state.hasRestored) { _, _ in restore() }
            .onChange(of: state.source.vadOnsetWindows) { _, _ in restore() }
            .onChange(of: state.source.vadThreshold) { _, _ in restore() }
        }
    }

    @MainActor
    struct ModelResourceSections: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable var state: ModelResourcesState
        let controls: any ModelResourcesControlling
        let group: ModelResourceGroup
        var includesDecision = false
        @State private var selectedSource = "official"
        @State private var removal: ModelResourceItem?
        private func percentage(_ progress: Double) -> String {
            progress < 0.001 ? "<0.1%" : String(format: "%.1f%%", progress * 100)
        }
        private func modelKindBadge(_ title: String, color: Color) -> some View {
            Text(appCopy.text(title))
                .font(.caption.weight(.semibold))
                .fixedSize()
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
        }

        private var isSpeech: Bool { group == .recognition || group == .synthesis }

        var body: some View {
            Group {
                if isSpeech {
                    Section(appCopy.text("Custom model downloads")) { downloadSource }
                    ForEach(SpeechCapability.allCases, id: \.rawValue) { capability in
                        let ids = Set(state.speechOptions(for: capability).compactMap(\.artifactID))
                        let items = state.items.filter { ids.contains($0.id) }
                        if !items.isEmpty {
                            Section(appCopy.text(capability.title)) { ForEach(items, content: resourceRow) }
                        }
                    }
                } else {
                    otherModels
                }
            }

            .confirmationDialog(
                appCopy.text("Stop related features and delete the model?"),
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
            ) {
                if let item = removal {
                    Button(appCopy.format("Stop and delete %@", String(describing: item.name)), role: .destructive) {
                        removal = nil
                        Task { await controls.perform(item.id, operation: .remove) }
                    }
                }
            } message: {
                if let item = removal {
                    Text(appCopy.text(removalMessage(for: item.id)))
                }
            }
            .task {
                if !isSpeech { await controls.restore() }
                guard !Task.isCancelled else { return }
                syncDownloadSource()
            }
            .onChange(of: state.hasRestored) { _, restored in if restored { syncDownloadSource() } }

            if let error = state.error { Section { Text(appCopy.text(error)).foregroundStyle(.red) } }

        }
        private func removalMessage(for id: String) -> String {
            if isSpeech {
                switch state.speechOptions.first(where: { $0.artifactID == id })?.capability {
                case .voiceActivity: return "Voice activity detection will switch to the basic detector."
                case .enhancement:
                    return "Noise suppression will turn off. Your speech recognition model stays selected."
                case .endpointConfirmation:
                    return "Speech will end based on voice activity detection."
                case .keywordSpotting:
                    return "Fast interrupt will turn off. Decision will continue handling interruptions."
                default: return "Speech will switch to Apple. Download the model again to re-enable it."
                }
            }
            if state.modelIDs(for: .decision).contains(id) {
                return
                    "If this model is selected, download it again or choose another model to restore decision-making."
            }
            if group == .language { return "Use another model or download this model again for local chat." }
            return "Download YOLO again to use local pose recognition."
        }

        private func syncDownloadSource() {
            switch state.source.endpoint {
            case "https://huggingface.co": selectedSource = "official"
            case "https://hf-mirror.com": selectedSource = "mirror"
            default: selectedSource = "custom"
            }
        }

        @ViewBuilder private var downloadSource: some View {
            Picker(appCopy.text("Download source"), selection: $selectedSource) {
                Text(appCopy.text("Hugging Face")).tag("official")
                Text(appCopy.text("HF Mirror (China)")).tag("mirror")
                Text(appCopy.text("Custom domain")).tag("custom")
            }
            .pickerStyle(.menu)
            .disabled(state.saving || !state.hasRestored)
            .onChange(of: selectedSource) { _, value in
                if value == "official" { controls.editDownloadSource("https://huggingface.co") }
                if value == "mirror" { controls.editDownloadSource("https://hf-mirror.com") }
            }
            if selectedSource == "custom" {
                HStack {
                    TextField(
                        "https://your-domain.example",
                        text: Binding(get: { state.source.endpoint }, set: controls.editDownloadSource)
                    )
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { controls.editDownloadSource(value) }
                    }.labelStyle(.iconOnly).accessibilityLabel(appCopy.text("Paste download domain"))
                }
                .disabled(state.saving || !state.hasRestored)
            }
        }

        private var otherModels: some View {
            Section(group == .language ? appCopy.text("Local Models") : appCopy.text("Custom model")) {
                if group != .vision { downloadSource }
                let ids =
                    includesDecision
                    ? state.modelIDs(for: group).union(state.modelIDs(for: .decision)) : state.modelIDs(for: group)
                ForEach(state.items.filter { ids.contains($0.id) }, content: resourceRow)
                if includesDecision {
                    ForEach(state.languageModels.filter { $0.artifactID == nil }) { model in
                        HStack {
                            HStack(alignment: .center, spacing: 8) {
                                if model.nativeDecision {
                                    modelKindBadge("Decision", color: .orange)
                                } else {
                                    modelKindBadge("Chat", color: .blue)
                                }
                                Text(appCopy.text(model.name))
                            }
                            Spacer()
                            Text(appCopy.text(model.available ? "Available" : "Unavailable"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private func resourceRow(_ item: ModelResourceItem) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .center, spacing: 8) {
                            if state.modelIDs(for: .language).contains(item.id) {
                                modelKindBadge("Chat", color: .blue)
                            } else if state.modelIDs(for: .decision).contains(item.id) {
                                modelKindBadge("Decision", color: .orange)
                            }
                            Text(appCopy.text(item.name))
                        }
                        Text(
                            "\(appCopy.text(state.status(item))) · \(item.installed ? "" : appCopy.text("Estimated "))\(ByteCountFormatter.string(fromByteCount: item.installed ? item.installedBytes : item.bytes, countStyle: .file))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(item.license).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 0) {
                        if state.isDownloading(item) {
                            Button(
                                state.isCancelling(item.id)
                                    ? appCopy.text("Cancelling…") : appCopy.text("Cancel download")
                            ) {
                                Task { await controls.perform(item.id, operation: .cancel) }
                            }.frame(minHeight: 44).disabled(state.isCancelling(item.id))
                                .accessibilityIdentifier("settings.model.\(item.id).cancel")
                        } else if !state.isBusy(item) {
                            if !item.installed {
                                Button(
                                    item.failure == nil
                                        ? appCopy.text("Download") : appCopy.text("Resume download")
                                ) {
                                    Task { await controls.perform(item.id, operation: .download) }
                                }.frame(minHeight: 44).disabled(state.saving || !state.hasRestored)
                                    .accessibilityIdentifier("settings.model.\(item.id).download")
                            }
                            if item.installed || item.failure != nil {
                                Button(appCopy.text("Delete"), role: .destructive) { removal = item }.frame(
                                    minHeight: 44
                                )
                                .accessibilityIdentifier("settings.model.\(item.id).delete")
                            }
                        }
                    }.buttonStyle(.borderless)
                        .font(.subheadline)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if state.isBusy(item) {
                    if item.activity == .downloading && item.progress > 0 && !state.isCancelling(item.id) {
                        HStack {
                            ProgressView(value: item.progress)
                                .accessibilityLabel(
                                    appCopy.format("Download progress for %@", String(describing: item.name))
                                )
                                .accessibilityValue(percentage(item.progress))
                            Text(percentage(item.progress))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(
                                item.activity == .downloading && item.progress == 0
                                    && !state.isCancelling(item.id)
                                    ? appCopy.text("Connecting to the download source…")
                                    : appCopy.text(state.status(item))
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !state.isBusy(item), let failure = item.failure {
                    Text(appCopy.text(failure)).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
#endif
