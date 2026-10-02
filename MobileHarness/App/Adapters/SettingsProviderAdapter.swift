import AppWorkflows
import Foundation
import ModelKitDefaults
import ModelKitOpenAI
import UI

@MainActor
enum SettingsProviderAdapter {
    static var initial: CloudSettingsDraft {
        .init(
            enabled: false, url: OpenAIChatConfiguration.defaultBaseURL, key: "",
            model: OpenAIChatConfiguration.defaultModel)
    }
    static func operations(resources: URL) -> SettingsProviderOperations {
        SettingsProviderOperations(
            initial: initial,
            prepare: { draft in
                let configuration: OpenAIChatConfiguration?
                if let draft, draft.enabled {
                    configuration = try OpenAIChatConfiguration(
                        baseURL: OpenAIChatConfiguration.endpoint(draft.url), apiKey: draft.key,
                        model: draft.model.isEmpty ? OpenAIChatConfiguration.defaultModel : draft.model)
                } else {
                    configuration = nil
                }
                return { try await ModelKitDefaults.configureChat(resources: resources, configuration: configuration) }
            },
            discover: { draft in
                try await OpenAIChatConfiguration.models(
                    baseURL: OpenAIChatConfiguration.endpoint(draft.url), apiKey: draft.key)
            },
            errorMessage: { error in
                guard case OpenAIChatError.httpStatus(let status) = error else { return nil }
                return status == 401 || status == 403
                    ? "Key 无效或没有访问权限，请检查后重试"
                    : "服务返回错误（\(status)），请检查 URL 后重试"
            })
    }
}
