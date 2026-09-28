import SwiftUI

/// First-level settings list; feature-specific forms live in their own destination.
@MainActor
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let save: () async -> Bool

    var body: some View {
        List {
            NavigationLink {
                CloudLLMSettingsView(settings: settings, save: save)
            } label: {
                Label("云端 LLM", systemImage: "cloud")
            }
            .accessibilityIdentifier("settings.cloud.open")
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

@MainActor
private struct CloudLLMSettingsView: View {
    @Bindable var settings: AppSettings
    let save: () async -> Bool

    var body: some View {
        Form {
            Section {
                Toggle("使用云端 LLM", isOn: $settings.isEnabled)
                    .accessibilityIdentifier("settings.cloud.enabled")
            } footer: {
                Text("开启后使用所选云端模型，关闭后使用本地模型。保存后立即生效，关闭不会删除已有配置。")
            }
            Section {
                HStack {
                    TextField("https://provider.example/v1", text: $settings.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("云端模型 URL")
                        .accessibilityIdentifier("settings.cloud.url")
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first {
                            settings.url = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("粘贴 URL")
                    .accessibilityIdentifier("settings.cloud.url.paste")
                }
                HStack {
                    SecureField("API Key", text: $settings.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("settings.cloud.key")
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first {
                            settings.key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("粘贴 Key")
                    .accessibilityIdentifier("settings.cloud.key.paste")
                }
                Button(action: settings.loadModels) {
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
                }
            } header: {
                Text("服务配置")
            } footer: {
                Text("填写 API 地址和 Key，加载后选择对话模型。Key 安全保存在此设备中。")
            }
            Section {
                Text(settings.isSaving ? "正在保存…" : (settings.error ?? settings.notice ?? "配置修改后，点击右上角保存。"))
                    .foregroundStyle(settings.error == nil ? Color.secondary : .red)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .accessibilityIdentifier("settings.status")
            }
            .transaction { $0.animation = nil }

        }
        .disabled(settings.isSaving)
        .navigationTitle("云端 LLM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        // Keep native back navigation mounted; the App-owned save continues across navigation.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { _ = await save() }
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
        .onDisappear { settings.cancelDiscovery() }
    }
}
