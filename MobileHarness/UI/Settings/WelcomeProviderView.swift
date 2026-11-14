#if os(iOS)
    import SwiftUI

    /// First-run provider entry; persistence remains behind the existing settings controller.
    @MainActor
    struct WelcomeProviderView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                            Text(appCopy.text("Connect your AI service")).font(.title2.bold())
                            Text(appCopy.text("Add a cloud LLM provider, then choose models for Assistant and Writer."))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                    Section {
                        HStack {
                            TextField(appCopy.text("URL (optional, defaults to OpenAI)"), text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel(appCopy.text("Service URL. Leave blank to use OpenAI."))
                                .accessibilityIdentifier("welcome.provider.url")
                            pasteButton("URL", text: $url)
                        }
                        HStack {
                            SecureField(appCopy.text("API key"), text: $key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .accessibilityIdentifier("welcome.provider.key")
                            pasteButton("API key", text: $key)
                        }
                    } header: {
                        Text(appCopy.text("Cloud service"))
                    } footer: {
                        Text(
                            appCopy.text(
                                "Leave the URL blank for https://api.openai.com/v1, or enter an OpenAI-compatible endpoint. Your API key is stored in the device keychain."
                            ))
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
                                    error = settings.error ?? appCopy.text("Could not save. Try again.")
                                } else {
                                    key = ""
                                }
                            }
                        } label: {
                            HStack {
                                if settings.isSaving { ProgressView() }
                                Text(
                                    settings.isSaving
                                        ? appCopy.text("Saving…") : appCopy.text("Save and choose a model")
                                )
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
                        Button(appCopy.text("Set up later"), action: skip).disabled(settings.isSaving)
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
            .accessibilityLabel(appCopy.format("Paste %@", String(describing: title)))
            .accessibilityIdentifier(title == "URL" ? "welcome.provider.pasteURL" : "welcome.provider.pasteKey")
        }
    }
#endif
