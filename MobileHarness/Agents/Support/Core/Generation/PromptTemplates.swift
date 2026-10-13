import Foundation

public enum PromptTemplateError: Error, Equatable, Sendable {
    case invalidDocument
    case invalidTemplate(String)
    case missingTemplate(String)
    case invalidVariables(String)
    case outputTooLarge
    case resourceMissing(String)
}

/// Immutable, bounded templates. Inserted values are never parsed as template source.
public struct PromptTemplates: Sendable {
    private enum Segment: Sendable {
        case literal(String)
        case variable(String)
    }
    private struct Template: Sendable {
        let segments: [Segment]
        let variables: Set<String>
    }
    private let templates: [String: Template]
    public var names: Set<String> { Set(templates.keys) }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Document: Decodable {
        let version: Int
        let templates: [String: String]
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            guard Set(fields.allKeys.map(\.stringValue)) == ["version", "templates"] else {
                throw PromptTemplateError.invalidDocument
            }
            version = try fields.decode(Int.self, forKey: Key("version"))
            templates = try fields.decode([String: String].self, forKey: Key("templates"))
        }
    }

    public init(data: Data) throws {
        guard data.count <= 65_536 else { throw PromptTemplateError.invalidDocument }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw PromptTemplateError.invalidDocument
        }
        guard document.version == 1, (1...64).contains(document.templates.count) else {
            throw PromptTemplateError.invalidDocument
        }
        var compiled: [String: Template] = [:]
        for (name, body) in document.templates {
            guard Self.validName(name), body.utf8.count <= 16_384 else {
                throw PromptTemplateError.invalidTemplate(name)
            }
            var segments: [Segment] = []
            var variables: Set<String> = []
            var remaining = body[...]
            while let start = remaining.range(of: "{{") {
                let literal = String(remaining[..<start.lowerBound])
                guard !literal.contains("}}"),
                    let end = remaining[start.upperBound...].range(of: "}}")
                else { throw PromptTemplateError.invalidTemplate(name) }
                let variable = String(remaining[start.upperBound..<end.lowerBound])
                guard Self.validName(variable) else { throw PromptTemplateError.invalidTemplate(name) }
                segments.append(.literal(literal))
                segments.append(.variable(variable))
                variables.insert(variable)
                remaining = remaining[end.upperBound...]
            }
            guard !remaining.contains("}}") else { throw PromptTemplateError.invalidTemplate(name) }
            segments.append(.literal(String(remaining)))
            compiled[name] = Template(segments: segments, variables: variables)
        }
        templates = compiled
    }

    public func render(_ name: String, variables: [String: String] = [:]) throws -> String {
        guard let template = templates[name] else { throw PromptTemplateError.missingTemplate(name) }
        guard Set(variables.keys) == template.variables else { throw PromptTemplateError.invalidVariables(name) }
        var output = ""
        var bytes = 0
        for segment in template.segments {
            let value: String
            switch segment {
            case .literal(let text): value = text
            case .variable(let key):
                guard let supplied = variables[key] else { throw PromptTemplateError.invalidVariables(name) }
                value = supplied
            }
            let size = value.utf8.count
            guard size <= 65_536 - bytes else { throw PromptTemplateError.outputTooLarge }
            bytes += size
            output += value
        }
        return output
    }

    public static func load(named name: String, bundle: Bundle) throws -> Self {
        guard validName(name), let url = bundle.url(forResource: name, withExtension: "json") else {
            throw PromptTemplateError.resourceMissing(name)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try Self(data: file.read(upToCount: 65_537) ?? Data())
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 95 || $0 == 46
            }
    }
}

/// Generic protocol guidance is owned by AgentCore, independently of role resources.
public enum FunctionTokenPrompts {
    private static let stored = Result { try PromptTemplates.load(named: "FunctionTokenPrompts", bundle: .module) }
    public static func load() throws -> PromptTemplates { try stored.get() }
}
