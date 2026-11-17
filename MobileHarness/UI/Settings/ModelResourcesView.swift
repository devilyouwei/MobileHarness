#if os(iOS)
    import SwiftUI

    @MainActor
    public struct ModelResourcesView: View {
        @Environment(\.locale) private var appCopyLocale
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
        private var customEnabled: Bool {
            group == .recognition ? state.source.useCustomRecognition : state.source.useCustomSynthesis
        }
        public var body: some View {
            Form {
                if group == .recognition, let audioDetection, let audioDetectionRequests {
                    AudioDetectionSection(state: audioDetection, requests: audioDetectionRequests)
                }
                if group == .recognition || group == .synthesis {
                    Section {
                        Toggle(
                            group == .recognition
                                ? appCopy.text("Use custom recognition model") : appCopy.text("Use custom model"),
                            isOn: Binding(
                                get: { customEnabled },
                                set: { value in Task { await controls.setCustomModel(group, enabled: value) } })
                        )
                        .disabled(state.saving || !state.hasRestored)
                        .accessibilityIdentifier("settings.\(group.rawValue).custom")
                    } footer: {
                        Text(
                            group == .recognition
                                ? appCopy.text(
                                    "Download Nemotron first. Turning this off uses Apple speech recognition.")
                                : appCopy.text("Download MOSS first. Turning this off uses Apple system voices."))
                    }
                }
                if group == .recognition {
                    Section {
                        Toggle(
                            appCopy.text("Noise suppression"),
                            isOn: Binding(
                                get: { state.source.useSpeechEnhancement },
                                set: { enabled in Task { await controls.setSpeechEnhancement(enabled: enabled) } })
                        )
                        .disabled(state.saving || !state.hasRestored)
                        .accessibilityIdentifier("settings.recognition.enhancement")
                    } footer: {
                        Text(
                            appCopy.text(
                                "Download DeepFilterNet3 first. Works with Apple and custom recognition. Applies the next time listening starts and adds about 400 ms of buffering."
                            ))
                    }
                    SpeechDetectionSettings(state: state, controls: controls)
                }
                ModelResourceSections(state: state, controls: controls, group: group)
            }
            .navigationTitle(appCopy.text(group.title))
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
            Section {
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
                if let error = state.error { Text(copy.text(error)).foregroundStyle(.red) }
            } header: {
                Text(copy.text("Speech detection"))
            } footer: {
                Text(
                    copy.text(
                        "Higher values reduce false triggers but may delay or miss short speech. Applies the next time listening starts."
                    ))
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

        @ViewBuilder var body: some View {
            Section(group == .language ? appCopy.text("Local Models") : appCopy.text("Custom model")) {
                if group != .vision {
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
                let modelIDs =
                    includesDecision ? group.modelIDs.union(ModelResourceGroup.decision.modelIDs) : group.modelIDs
                ForEach(state.items.filter { modelIDs.contains($0.id) }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .center, spacing: 8) {
                                    if ModelResourceGroup.language.modelIDs.contains(item.id) {
                                        modelKindBadge("Chat", color: .blue)
                                    } else if ModelResourceGroup.decision.modelIDs.contains(item.id) {
                                        modelKindBadge("Decision", color: .orange)
                                    }
                                    Text(appCopy.text(item.name))
                                }
                                if item.id == "deepfilternet3" {
                                    Text(
                                        appCopy.text(
                                            "Loaded at startup when installed. Enable Noise suppression to use it for listening."
                                        )
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                if item.id == "silero" {
                                    Text(
                                        appCopy.text(
                                            "Used automatically for voice activity detection after downloading.")
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
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
                if includesDecision {
                    HStack {
                        HStack(alignment: .center, spacing: 8) {
                            modelKindBadge("Chat", color: .blue)
                            Text(appCopy.text("Apple System LLM"))
                        }
                        Spacer()
                        Text(appCopy.text(state.appleSystemAvailable ? "Available" : "Unavailable"))
                            .foregroundStyle(.secondary)
                    }
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
                Text(
                    removal?.id == "deepfilternet3"
                        ? appCopy.text("Noise suppression will turn off. Your speech recognition model stays selected.")
                        : removal?.id == "silero"
                            ? appCopy.text("Voice activity detection will switch to the basic detector.")
                            : group == .recognition || group == .synthesis
                                ? appCopy.text("Speech will switch to Apple. Download the model again to re-enable it.")
                                : removal.map { ModelResourceGroup.decision.modelIDs.contains($0.id) } == true
                                    ? appCopy.text(
                                        "If this model is selected, download it again or choose another model to restore decision-making."
                                    )
                                    : group == .language
                                        ? appCopy.text(
                                            "Use a cloud model or download Gemma 4 E2B again for local chat.")
                                        : appCopy.text("Download YOLO again to use local pose recognition."))
            }
            .task {
                await controls.restore()
                guard !Task.isCancelled else { return }
                selectedSource =
                    state.source.endpoint == "https://huggingface.co"
                    ? "official" : (state.source.endpoint == "https://hf-mirror.com" ? "mirror" : "custom")
            }

            if let error = state.error { Section { Text(appCopy.text(error)).foregroundStyle(.red) } }

        }
    }
#endif
