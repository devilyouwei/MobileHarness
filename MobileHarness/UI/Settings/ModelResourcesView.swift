#if os(iOS)
    import SwiftUI

    @MainActor public struct ModelResourcesView: View {
        @Bindable private var state: ModelResourcesState
        private let controls: any ModelResourcesControlling
        private let group: ModelResourceGroup
        private let audioDetection: AudioDetectionState?
        private let audioDetectionControls: (any AudioDetectionControlling)?
        public init(
            state: ModelResourcesState, controls: any ModelResourcesControlling, group: ModelResourceGroup,
            audioDetection: AudioDetectionState? = nil,
            audioDetectionControls: (any AudioDetectionControlling)? = nil
        ) {
            self.state = state
            self.controls = controls
            self.group = group
            self.audioDetection = audioDetection
            self.audioDetectionControls = audioDetectionControls
        }
        private var customEnabled: Bool {
            group == .recognition ? state.source.useCustomRecognition : state.source.useCustomSynthesis
        }
        public var body: some View {
            Form {
                if group == .recognition, let audioDetection, let audioDetectionControls {
                    AudioDetectionSection(state: audioDetection, controls: audioDetectionControls)
                }
                if group == .recognition || group == .synthesis {
                    Section {
                        Toggle(
                            group == .recognition ? "使用自定义识别模型" : "使用自定义模型",
                            isOn: Binding(
                                get: { customEnabled },
                                set: { value in Task { await controls.setCustomModel(group, enabled: value) } })
                        )
                        .disabled(state.saving || !state.hasRestored)
                        .accessibilityIdentifier("settings.\(group.rawValue).custom")
                    } footer: {
                        Text(
                            group == .recognition
                                ? "开启前请先下载 Nemotron；关闭时使用 Apple 语音识别。"
                                : "开启前请先下载 MOSS；关闭时使用 Apple 系统声音。")
                    }
                }
                ModelResourceSections(state: state, controls: controls, group: group)
            }
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "请先安装模型",
                isPresented: Binding(
                    get: { state.installationNotice != nil }, set: { if !$0 { state.installationNotice = nil } })
            ) {
                Button("知道了", role: .cancel) { state.installationNotice = nil }
            } message: {
                Text(state.installationNotice ?? "")
            }
        }
    }

    @MainActor struct ModelResourceSections: View {
        @Bindable var state: ModelResourcesState
        let controls: any ModelResourcesControlling
        let group: ModelResourceGroup
        @State private var selectedSource = "official"
        @State private var removal: ModelResourceItem?
        private func percentage(_ progress: Double) -> String {
            progress < 0.001 ? "<0.1%" : String(format: "%.1f%%", progress * 100)
        }
        @ViewBuilder var body: some View {
            Section(group == .language ? "本地大模型" : "自定义模型") {
                if group != .vision {
                    Picker("下载源", selection: $selectedSource) {
                        Text("Hugging Face 官方").tag("official")
                        Text("HF Mirror 中国镜像").tag("mirror")
                        Text("自定义域名").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .disabled(state.saving || !state.hasRestored)
                    .onChange(of: selectedSource) { _, value in
                        if value == "official" { state.source.endpoint = "https://huggingface.co" }
                        if value == "mirror" { state.source.endpoint = "https://hf-mirror.com" }
                    }
                    if selectedSource == "custom" {
                        HStack {
                            TextField("https://your-domain.example", text: $state.source.endpoint)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            PasteButton(payloadType: String.self) { values in
                                if let value = values.first { state.source.endpoint = value }
                            }.labelStyle(.iconOnly).accessibilityLabel("粘贴下载域名")
                        }
                        .disabled(state.saving || !state.hasRestored)
                    }
                }
                ForEach(state.items.filter { group.modelIDs.contains($0.id) }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                if item.id == "silero" {
                                    Text("下载后自动用于人声检测。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(
                                    "\(state.status(item)) · \(item.installed ? "" : "预计 ")\(ByteCountFormatter.string(fromByteCount: item.installed ? item.installedBytes : item.bytes, countStyle: .file))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                Text("版本 \(item.revision.prefix(12)) · \(item.license)").font(.caption2)
                                    .foregroundStyle(
                                        .secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 0) {
                                if state.isDownloading(item) {
                                    Button(state.isCancelling(item.id) ? "正在取消…" : "取消下载") {
                                        Task { await controls.perform(item.id, operation: .cancel) }
                                    }.frame(minHeight: 44).disabled(state.isCancelling(item.id))
                                } else if !state.isBusy(item) {
                                    if !item.installed {
                                        Button(item.failure == nil ? "下载" : "继续下载") {
                                            Task { await controls.perform(item.id, operation: .download) }
                                        }.frame(minHeight: 44).disabled(state.saving || !state.hasRestored)
                                    }
                                    if item.installed || item.failure != nil {
                                        Button("删除", role: .destructive) { removal = item }.frame(minHeight: 44)
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
                                        .accessibilityLabel("\(item.name)下载进度")
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
                                            ? "正在连接下载来源，等待数据…" : state.status(item)
                                    ).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !state.isBusy(item), let failure = item.failure {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }

            .confirmationDialog(
                "停止相关功能并删除模型？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
            ) {
                if let item = removal {
                    Button("停止并删除 \(item.name)", role: .destructive) {
                        removal = nil
                        Task { await controls.perform(item.id, operation: .remove) }
                    }
                }
            } message: {
                Text(
                    removal?.id == "silero"
                        ? "删除后将使用基础声音检测。"
                        : group == .recognition || group == .synthesis
                            ? "删除后将使用 Apple 语音，再次启用需重新下载。"
                            : group == .language
                                ? "删除后需要使用云端大模型，或重新下载 Gemma 4 E2B 才能进行本地对话。"
                                : "删除后需要重新下载 YOLO 才能使用本地姿态识别。")
            }
            .task(id: state.source.endpoint) {
                guard group != .vision else { return }
                do {
                    try await Task.sleep(for: .milliseconds(600))
                    while state.saving || !state.hasRestored {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try Task.checkCancellation()
                    await controls.saveDownloadSource()
                } catch {
                    // Editing or leaving the page cancels pending autosave.
                }
            }
            .task {
                await controls.restore()
                selectedSource =
                    state.source.endpoint == "https://huggingface.co"
                    ? "official" : (state.source.endpoint == "https://hf-mirror.com" ? "mirror" : "custom")
            }

            if let error = state.error { Section { Text(error).foregroundStyle(.red) } }

        }
    }
#endif
