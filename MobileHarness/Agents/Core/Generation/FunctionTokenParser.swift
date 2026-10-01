import Foundation

/// Parses the Function Token protocol: natural text and a restricted XML syntax.
/// Independent of model tokenizer boundaries. One instance per generation; errors are terminal.
public struct FunctionTokenParser: Sendable {
    private var utf8: [UInt8] = []
    private var expectedBytes = 0
    private var tag: String?
    private var quote: Unicode.Scalar?
    private var entity: String?
    private var text = ""
    private var channels = ChannelParser()
    private var totalBytes = 0
    private var tokenCount = 0
    private var closed = false
    public init() {}

    public mutating func append(_ fragment: String) throws -> [FunctionToken] { try append(Data(fragment.utf8)) }

    public mutating func append(_ bytes: Data) throws -> [FunctionToken] {
        guard !closed else { throw GenerationError.closed }
        do {
            guard bytes.count <= 65_536 - totalBytes else { throw GenerationError.limitExceeded }
            totalBytes += bytes.count
            var result: [FunctionToken] = []
            for byte in bytes {
                if utf8.isEmpty {
                    if byte < 128 {
                        try consume(Unicode.Scalar(byte), into: &result)
                        continue
                    }
                    switch byte {
                    case 0xC2...0xDF: expectedBytes = 2
                    case 0xE0...0xEF: expectedBytes = 3
                    case 0xF0...0xF4: expectedBytes = 4
                    default: throw GenerationError.invalidUTF8
                    }
                } else if !(0x80...0xBF).contains(byte) {
                    throw GenerationError.invalidUTF8
                }
                utf8.append(byte)
                if utf8.count == expectedBytes {
                    guard let value = String(bytes: utf8, encoding: .utf8), let scalar = value.unicodeScalars.first
                    else {
                        throw GenerationError.invalidUTF8
                    }
                    try consume(scalar, into: &result)
                    utf8.removeAll(keepingCapacity: true)
                }
            }
            flushText(into: &result)
            return result
        } catch {
            closed = true
            throw error
        }
    }

    public mutating func finish() throws -> [FunctionToken] {
        guard !closed else { throw GenerationError.closed }
        closed = true
        guard utf8.isEmpty, tag == nil, entity == nil, channels.isEmpty else {
            throw GenerationError.incompleteDocument
        }
        var result: [FunctionToken] = []
        flushText(into: &result)
        return result
    }

    private mutating func flushText(into result: inout [FunctionToken]) {
        if !text.isEmpty {
            result.append(.text(text, channel: channels.current))
            text = ""
        }
    }

    private mutating func consume(_ scalar: Unicode.Scalar, into result: inout [FunctionToken]) throws {
        guard Self.validScalar(scalar) else { throw GenerationError.malformedMarkup }
        if tag != nil {
            tag!.unicodeScalars.append(scalar)
            guard tag!.utf8.count <= 4096 else { throw GenerationError.limitExceeded }
            if let active = quote {
                if scalar == active { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                let complete = tag!
                tag = nil
                try parseTag(complete, into: &result)
            }
            return
        }
        if entity != nil {
            if scalar == ";" {
                text += try Self.decodeEntity(entity!)
                entity = nil
            } else {
                guard scalar != "<", scalar != "&", !Character(scalar).isWhitespace else {
                    throw GenerationError.invalidEntity
                }
                entity!.unicodeScalars.append(scalar)
                guard entity!.count <= 16 else { throw GenerationError.limitExceeded }
            }
        } else if scalar == "<" {
            flushText(into: &result)
            tag = "<"
        } else if scalar == "&" {
            entity = ""
        } else {
            text.unicodeScalars.append(scalar)
        }
    }

    private mutating func parseTag(_ value: String, into result: inout [FunctionToken]) throws {
        tokenCount += 1
        guard tokenCount <= 1024 else { throw GenerationError.limitExceeded }
        let content = String(value.dropFirst().dropLast())
        if content == "wait" {
            try channels.openWait()
            result.append(.scheduling(.beginWait))
            return
        }
        if content == "/wait" {
            try channels.closeWait()
            result.append(.scheduling(.endWait))
            return
        }
        if content.hasPrefix("/channel.") {
            let name = String(content.dropFirst(9))
            try channels.close(name)
            result.append(.boundary)
            return
        }
        if content.hasPrefix("channel.") {
            let name = String(content.dropFirst(8))
            try channels.open(name)
            result.append(.boundary)
            return
        }
        guard content.hasSuffix("/") else { throw GenerationError.malformedMarkup }
        let chars = Array(content.dropLast())
        var index = 0
        func whitespace(_ c: Character) -> Bool { c == " " || c == "\n" || c == "\r" || c == "\t" }
        func name() -> String {
            let start = index
            while index < chars.count, !whitespace(chars[index]), chars[index] != "=" { index += 1 }
            return String(chars[start..<index])
        }
        func skip() { while index < chars.count, whitespace(chars[index]) { index += 1 } }
        let alias = name()
        guard CapabilityRegistry.validName(alias), alias != "wait", !alias.hasPrefix("channel.") else {
            throw GenerationError.malformedMarkup
        }
        var params: [String: String] = [:]
        while index < chars.count {
            guard whitespace(chars[index]) else { throw GenerationError.malformedMarkup }
            skip()
            if index == chars.count { break }
            let key = name()
            guard CapabilityRegistry.validName(key), params[key] == nil else { throw GenerationError.malformedMarkup }
            skip()
            guard index < chars.count, chars[index] == "=" else { throw GenerationError.malformedMarkup }
            index += 1
            skip()
            guard index < chars.count, chars[index] == "\"" || chars[index] == "'" else {
                throw GenerationError.malformedMarkup
            }
            let delimiter = chars[index]
            index += 1
            let start = index
            while index < chars.count, chars[index] != delimiter { index += 1 }
            guard index < chars.count else { throw GenerationError.malformedMarkup }
            params[key] = try Self.decodeAttribute(String(chars[start..<index]))
            guard params.count <= 32 else { throw GenerationError.limitExceeded }
            index += 1
        }
        result.append(.action(name: alias, parameters: params, channel: channels.current))
    }

    private static func decodeAttribute(_ value: String) throws -> String {
        var output = ""
        var entity: String?
        for scalar in value.unicodeScalars {
            guard scalar != "<" else { throw GenerationError.malformedMarkup }
            if entity != nil {
                if scalar == ";" {
                    output += try decodeEntity(entity!)
                    entity = nil
                } else {
                    entity!.unicodeScalars.append(scalar)
                }
            } else if scalar == "&" {
                entity = ""
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        guard entity == nil else { throw GenerationError.invalidEntity }
        return output
    }

    private static func decodeEntity(_ value: String) throws -> String {
        switch value {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            let hex = value.hasPrefix("#x")
            let digits = value.dropFirst(hex ? 2 : 1)
            guard !digits.isEmpty,
                digits.utf8.allSatisfy({
                    (48...57).contains($0) || (hex && ((65...70).contains($0) || (97...102).contains($0)))
                })
            else { throw GenerationError.invalidEntity }
            guard value.hasPrefix("#"), let number = UInt32(value.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                let scalar = Unicode.Scalar(number), validScalar(scalar)
            else { throw GenerationError.invalidEntity }
            return String(scalar)
        }
    }

    private static func validScalar(_ value: Unicode.Scalar) -> Bool {
        value.value == 9 || value.value == 10 || value.value == 13
            || (0x20...0xD7FF).contains(value.value) || (0xE000...0xFFFD).contains(value.value)
            || (0x10000...0x10FFFF).contains(value.value)
    }
}
