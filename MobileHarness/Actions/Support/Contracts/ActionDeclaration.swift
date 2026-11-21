import Foundation

/// Canonical argument documentation. Both transports encode values as strings.
public struct ActionParameter: Codable, Sendable, Equatable {
    public enum ValueType: String, Codable, Sendable { case string, integer, number, boolean }
    public let name: String
    public let valueType: ValueType
    public let required: Bool
    public let description: String
    public let constraints: String
    public let values: [String]
    public init(
        _ name: String, type: ValueType = .string, required: Bool = true,
        description: String, constraints: String = "", values: [String] = []
    ) {
        self.name = name
        self.valueType = type
        self.required = required
        self.description = description
        self.constraints = constraints
        self.values = values
    }
}

/// Immutable projection of the owning @Action; Skills provide aliases and teaching examples.
public struct ActionDeclaration: Codable, Sendable, Equatable {
    public let path: ActionIdentifier
    public let doc: String
    public let parameters: [ActionParameter]
    public init(path: ActionIdentifier, doc: String, parameters: [ActionParameter] = []) {
        self.path = path
        self.doc = doc
        self.parameters = parameters
    }
    public func validate() throws {
        guard path.isValid, !doc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            doc.utf8.count <= 2048, parameters.count <= 32,
            Set(parameters.map(\.name)).count == parameters.count,
            parameters.allSatisfy({
                ActionIdentifier.validName($0.name)
                    && !$0.description.isEmpty && $0.description.utf8.count <= 2048
                    && $0.constraints.utf8.count <= 2048 && $0.values.count <= 32
                    && Set($0.values).count == $0.values.count
            })
        else { throw ActionExecutionError.invalidDefinition(path) }
    }
    public func actionObject(alias: String) throws -> [String: Any] {
        try validate()
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else {
            throw ActionExecutionError.invalidDefinition(path)
        }
        object["alias"] = alias
        object["parameters"] = parameters.map { p in
            [
                "name": p.name, "valueType": p.valueType.rawValue, "required": p.required,
                "description": p.description, "constraints": p.constraints,
            ] as [String: Any]
        }
        return object
    }
    public var nativeSchema: [String: Any] {
        let properties = Dictionary(
            uniqueKeysWithValues: parameters.map { p in
                var property: [String: Any] = ["type": "string", "description": p.description]
                if !p.values.isEmpty { property["enum"] = p.values }
                return (p.name, property)
            })
        return [
            "type": "object", "properties": properties,
            "required": parameters.filter(\.required).map(\.name), "additionalProperties": false,
        ]
    }
}

/// Translated model-facing prose for one function. Names, types, requirements and enum values are never translated.
public struct ActionTranslation: Codable, Sendable, Equatable {
    public struct Parameter: Codable, Sendable, Equatable {
        public let description: String
        public let constraints: String?
        public init(description: String, constraints: String? = nil) {
            self.description = description
            self.constraints = constraints
        }
    }
    public let description: String
    public let parameters: [String: Parameter]
    public init(description: String, parameters: [String: Parameter] = [:]) {
        self.description = description
        self.parameters = parameters
    }
}

extension ActionDeclaration {
    /// Overlay a translation; absent parameter entries keep the declaration's default-language text.
    public func localized(_ translation: ActionTranslation) -> ActionDeclaration {
        ActionDeclaration(
            path: path, doc: translation.description,
            parameters: parameters.map { parameter in
                let text = translation.parameters[parameter.name]
                return ActionParameter(
                    parameter.name, type: parameter.valueType, required: parameter.required,
                    description: text?.description ?? parameter.description,
                    constraints: text?.constraints ?? parameter.constraints, values: parameter.values)
            })
    }
}
