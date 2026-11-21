import Foundation

/// Incremental lexical checkpoints, not a replacement for WebKit's HTML/JS parser.
/// Scalar offsets remain stable when a combining mark arrives in a later model delta.
public struct ArtifactContentParser: Sendable {
    public enum Format: Sendable { case html, script, markdown, text }
    public let format: Format
    public private(set) var scalarCount = 0
    public private(set) var checkpointScalars = 0
    private var inTag = false
    private var quote: Unicode.Scalar?
    private var escaped = false
    private var line = ""
    private var fenced = false
    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "svg": format = .html
        case "js", "css", "json": format = .script
        case "md": format = .markdown
        default: format = .text
        }
    }
    public mutating func append(_ chunk: String) {
        for scalar in chunk.unicodeScalars {
            scalarCount += 1
            switch format {
            case .text: checkpointScalars = scalarCount
            case .html:
                if inTag {
                    if let active = quote {
                        if scalar == active { quote = nil }
                    } else if scalar == "\"" || scalar == "'" {
                        quote = scalar
                    } else if scalar == ">" {
                        inTag = false
                        checkpointScalars = scalarCount
                    }
                } else if scalar == "<" {
                    inTag = true
                } else {
                    checkpointScalars = scalarCount
                }
            case .script:
                if escaped {
                    escaped = false
                } else if quote != nil, scalar == "\\" {
                    escaped = true
                } else if let active = quote {
                    if scalar == active { quote = nil }
                } else if scalar == "\"" || scalar == "'" || scalar == "`" {
                    quote = scalar
                } else if scalar == "\n" || scalar == ";" || scalar == "}" {
                    checkpointScalars = scalarCount
                }
            case .markdown:
                if scalar == "\n" {
                    if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
                    line = ""
                    checkpointScalars = scalarCount
                } else {
                    // Only fence recognition needs a prefix; source text lives in the bounded draft buffer.
                    if line.unicodeScalars.count < 3 { line.unicodeScalars.append(scalar) }
                    if !fenced, line != "`", line != "``", line != "~", line != "~~" { checkpointScalars = scalarCount }
                }
            }
        }
    }
    public func checkpoint(in text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(checkpointScalars)))
    }
}
