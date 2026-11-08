#if os(iOS)
    import SwiftUI

    /// First-run provider entry; persistence remains behind the existing settings controller.
    @MainActor
    struct WelcomeProviderView: View {
        let settings: SettingsState
        let save: (String, String) async -> Bool
        let skip: () -> Void
        @State private var url = ""
        @State private var key = ""
        @State private var error: String?

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.largeTitle).foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text("连接你的 AI 服务").font(.title2.bold())
                            Text("添加云端 LLM Provider，随后为 Assistant 和 Writer 分别选择模型。")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                    Section {
                        HStack {
                            TextField("URL（可选，默认 OpenAI）", text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("服务 URL，可选，留空使用 OpenAI")
                                .accessibilityIdentifier("welcome.provider.url")
                            pasteButton("URL", text: $url)
                        }
                        HStack {
                            SecureField("API key", text: $key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .accessibilityIdentifier("welcome.provider.key")
                            pasteButton("API key", text: $key)
                        }
                    } header: {
                        Text("云端服务")
                    } footer: {
                        Text("URL 留空使用 https://api.openai.com/v1，也可填写兼容 OpenAI 的服务地址。API key 安全保存在设备钥匙串中。")
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                            .accessibilityIdentifier("welcome.provider.error")
                    }
                    Section {
                        Button {
                            Task {
                                error = nil
                                if !(await save(url, key)) {
                                    error = settings.error ?? "保存失败，请重试"
                                } else {
                                    key = ""
                                }
                            }
                        } label: {
                            HStack {
                                if settings.isSaving { ProgressView() }
                                Text(settings.isSaving ? "正在保存…" : "保存并选择模型")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("welcome.provider.save")
                    }
                }
                .disabled(settings.isSaving)
                .navigationTitle("Welcome")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("稍后设置", action: skip).disabled(settings.isSaving)
                            .accessibilityIdentifier("welcome.provider.skip")
                    }
                }
            }
            .interactiveDismissDisabled(settings.isSaving)
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
            .accessibilityIdentifier(title == "URL" ? "welcome.provider.pasteURL" : "welcome.provider.pasteKey")
        }
    }
#endif
