#if os(iOS)
    import SwiftUI

    @MainActor public struct ModelResourcesView: View {
        @Bindable private var state: ModelResourcesState
        @State private var selectedSource = "official"
        @State private var removal: ModelResourceItem?
        public init(state: ModelResourcesState) { self.state = state }
        private func percentage(_ progress: Double) -> String {
            progress < 0.001 ? "<0.1%" : String(format: "%.1f%%", progress * 100)
        }
        public var body: some View {
            Form {
                Section("下载来源") {
                    Picker("Hugging Face 来源", selection: $selectedSource) {
                        Text("官方站").tag("official")
                        Text("中国地区镜像 · HF-Mirror").tag("mirror")
                        Text("自定义域名").tag("custom")
                    }.onChange(of: selectedSource) { _, value in
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
                    }
                    Toggle("允许蜂窝网络下载", isOn: $state.source.allowsCellular)
                    Button("保存下载来源") { Task { await state.saveSource() } }.disabled(state.saving)
                    Text("更改仅用于新下载。镜像是第三方服务。GitHub 资源使用原始来源。应用退出后，HF 下载会在下次启动重新开始。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(state.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name)
                            Text(
                                "\(state.status(item)) · \(item.installed ? "" : "预计 ")\(ByteCountFormatter.string(fromByteCount: item.installed ? item.installedBytes : item.bytes, countStyle: .file))"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Text("版本 \(item.revision.prefix(12)) · \(item.license)").font(.caption2).foregroundStyle(
                                .secondary)
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
                            HStack {
                                if state.isDownloading(item) {
                                    Button(state.isCancelling(item.id) ? "正在取消…" : "取消下载") {
                                        Task { await state.perform(item.id, operation: "cancel") }
                                    }.disabled(state.isCancelling(item.id))
                                } else if !state.isBusy(item) {
                                    if !item.installed {
                                        Button(item.failure == nil ? "下载" : "继续下载") {
                                            Task { await state.perform(item.id, operation: "download") }
                                        }
                                    }
                                    if item.installed || item.failure != nil {
                                        Button("删除", role: .destructive) { removal = item }
                                    }
                                }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Text(
                    "已安装模型占用 "
                        + ByteCountFormatter.string(
                            fromByteCount: state.items.filter(\.installed).reduce(0) { $0 + $1.installedBytes },
                            countStyle: .file)
                )
                .font(.footnote).foregroundStyle(.secondary)
                if let error = state.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("本地模型资源")
            .confirmationDialog(
                "停止相关功能并删除模型？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
            ) {
                if let item = removal {
                    Button("停止并删除 \(item.name)", role: .destructive) {
                        removal = nil
                        Task { await state.perform(item.id, operation: "remove") }
                    }
                }
            } message: {
                Text("删除后，相关本地功能需要重新下载模型才能使用。")
            }
            .task {
                await state.restore()
                selectedSource =
                    state.source.endpoint == "https://huggingface.co"
                    ? "official" : (state.source.endpoint == "https://hf-mirror.com" ? "mirror" : "custom")
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    await state.refresh()
                }
            }
        }
    }
#endif
