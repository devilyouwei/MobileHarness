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
        @ViewBuilder var body: some View {
            Section(group == .language ? appCopy.text("Local model downloads") : appCopy.text("Custom model")) {
                if group != .vision {
                    Picker(appCopy.text("Download source"), selection: $selectedSource) {
                        Text(appCopy.text("Official Hugging Face")).tag("official")
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
                if includesDecision {
                    Button(appCopy.text("Save download settings")) { Task { _ = await controls.saveDownloadSource() } }
                        .disabled(state.saving || !state.hasRestored)
                        .accessibilityIdentifier("settings.brains.downloadSource.save")
                }
                let modelIDs =
                    includesDecision ? group.modelIDs.union(ModelResourceGroup.decision.modelIDs) : group.modelIDs
                ForEach(state.items.filter { modelIDs.contains($0.id) }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appCopy.text(item.name))
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
                                Text(
                                    appCopy.format(
                                        "Revision %@ · %@", String(describing: item.revision.prefix(12)),
                                        String(describing: item.license))
                                ).font(.caption2)
                                    .foregroundStyle(
                                        .secondary)
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
                    removal?.id == "silero"
                        ? appCopy.text("Voice activity detection will switch to the basic detector.")
                        : group == .recognition || group == .synthesis
                            ? appCopy.text("Speech will switch to Apple. Download the model again to re-enable it.")
                            : removal?.id == "d3-edge"
                                ? appCopy.text(
                                    "Decision will use the saved cloud fallback. If unavailable, it keeps and queues input."
                                )
                                : group == .language
                                    ? appCopy.text("Use a cloud model or download Gemma 4 E2B again for local chat.")
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
