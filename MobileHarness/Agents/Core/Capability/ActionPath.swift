/// An explicitly registered three-level capability address; never a reflected source path.
public struct ActionPath: Hashable, Sendable, CustomStringConvertible {
    public let domain: String
    public let module: String
    public let function: String

    public init(domain: String, module: String, function: String) {
        self.domain = domain
        self.module = module
        self.function = function
    }

    public var isValid: Bool {
        [domain, module, function].allSatisfy { segment in
            let bytes = Array(segment.utf8)
            func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
            guard let first = bytes.first, bytes.count <= 64, letter(first) else { return false }
            return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    public var description: String { "\(domain).\(module).\(function)" }
}
