import Foundation
import FunctionContracts

public enum ActionLocalizationError: Error, Equatable {
    case invalidFile(String)
    case unknownFunction(String)
    case unknownParameter(function: String, parameter: String)
}

/// Translations of Action declarations, loaded from `<resourceRoot>/Localization/<Domain>/<Module>.<language>.json`
/// (the packaged copy of `Resources/Actions`).
/// The `@Action` text is the default language; a missing file, function or parameter keeps that text.
public enum ActionLocalization {
    private struct File: Decodable { let entries: [String: ActionTranslation] }

    /// Translations by language and `Domain.Module.title`, validated against `declarations`.
    public static func translations(
        for declarations: [ActionDeclaration], resourceRoot: URL
    ) throws -> [String: [String: ActionTranslation]] {
        let root = resourceRoot.appendingPathComponent("Localization", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [:] }
        let known = Dictionary(uniqueKeysWithValues: declarations.map { ($0.path.description, $0) })
        var result: [String: [String: ActionTranslation]] = [:]
        for case let url as URL in walker where url.pathExtension == "json" {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard parts.count == 2 else { throw ActionLocalizationError.invalidFile(url.lastPathComponent) }
            let prefix = url.deletingLastPathComponent().lastPathComponent + "." + parts[0] + "."
            let file: File
            do { file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)) } catch {
                throw ActionLocalizationError.invalidFile(url.lastPathComponent)
            }
            for (title, translation) in file.entries {
                let path = prefix + title
                guard let declaration = known[path] else { throw ActionLocalizationError.unknownFunction(path) }
                let names = Set(declaration.parameters.map(\.name))
                if let extra = translation.parameters.keys.sorted().first(where: { !names.contains($0) }) {
                    throw ActionLocalizationError.unknownParameter(function: path, parameter: extra)
                }
                result[String(parts[1]), default: [:]][path] = translation
            }
        }
        return result
    }
}
