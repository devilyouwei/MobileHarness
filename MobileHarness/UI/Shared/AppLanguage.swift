import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var speechRecognitionLocale: String { self == .simplifiedChinese ? "zh-CN" : "en-US" }

    public init(preferredLanguage: String?) {
        let code = preferredLanguage?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        self = code == "zh" ? .simplifiedChinese : .english
    }

    public func text(_ key: String) -> String {
        guard !key.isEmpty, self == .simplifiedChinese else { return key }
        return Self.chineseResources?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    private static let chineseResources = Bundle.module.url(forResource: "zh-Hans", withExtension: "lproj")
        .flatMap(Bundle.init(url:))

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

public enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    public func resolve(preferredLanguage: String?) -> AppLanguage {
        switch self {
        case .system: AppLanguage(preferredLanguage: preferredLanguage)
        case .simplifiedChinese: .simplifiedChinese
        case .english: .english
        }
    }
}
