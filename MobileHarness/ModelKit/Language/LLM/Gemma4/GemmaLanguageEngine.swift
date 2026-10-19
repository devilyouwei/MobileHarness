import CoreAILanguageModels
import Darwin
import Foundation
import Metal
import OSLog
import Tokenizers

public struct GemmaLanguageTurn: Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct GemmaLanguageGeneration: Sendable {
    public let stopped: Bool
    public let generatedTokens: Int
}

public enum GemmaLanguageError: Error, Sendable {
    case unsupportedDevice(String)
    case noGPU
    case invalidTable(String)
    case bufferAllocation(String)
    case busy
    case nonMonotonicText
    case outputTooLarge
    case contextLimit
}

/// Gemma's decode-only CoreAI graph with immutable, checkpoint-matched PLE buffers.
@available(iOS 27, macOS 27, *)
public actor GemmaLanguageEngine {
    private static let signposter = OSSignposter(subsystem: "dev.mobileharness", category: "GemmaPerformance")
    nonisolated let contextLimit: Int
    private let engine: any InferenceEngine
    private let tokenizer: any Tokenizer
    private let tables: [String: StaticInputBuffer]
    private var active = false

    public init(directory: URL) async throws {
        let interval = Self.signposter.beginInterval("EngineLoad")
        defer { Self.signposter.endInterval("EngineLoad", interval) }
        #if os(iOS)
            var system = utsname()
            uname(&system)
            let machine = withUnsafeBytes(of: system.machine) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard ["iPhone18,1", "iPhone18,2"].contains(machine) else {
                throw GemmaLanguageError.unsupportedDevice(machine)
            }
            let bundleName = "gemma4_e2b_qat_decode_int4lin_tbl_aotc_h18p"
        #else
            let bundleName = "gemma4_e2b_qat_decode_int4lin_tbl"
        #endif
        // The graph accepts S=1 only. This engine reads the setting per generation.
        setenv("COREAI_CHUNK_THRESHOLD", "1", 1)
        guard let device = MTLCreateSystemDefaultDevice() else { throw GemmaLanguageError.noGPU }
        let tableRoot = directory.appendingPathComponent("ios-frontend/gemma4_qat_gather_raw")
        var buffers: [String: StaticInputBuffer] = [:]
        for (input, name, size) in [
            ("ple_table", "embed_per_layer.i8", 262144 * 8960),
            ("ple_scale", "embed_per_layer.scale.f32", 262144 * 4),
        ] {
            let url = tableRoot.appendingPathComponent(name)
            let actual = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actual == size else { throw GemmaLanguageError.invalidTable(name) }
            buffers[input] = StaticInputBuffer(try Self.loadBuffer(url: url, size: size, device: device))
        }
        tables = buffers
        let bundle = try LanguageBundle(
            at: directory.appendingPathComponent("gpu-pipelined-b2/" + bundleName))
        #if os(iOS)
            let isIOS = true
        #else
            let isIOS = false
        #endif
        contextLimit = GemmaContextBudget.effectiveContextLimit(modelLimit: bundle.maxContextLength, isIOS: isIOS)
        guard contextLimit >= 2 else { throw GemmaLanguageError.contextLimit }
        let config = ModelConfig(
            name: bundle.name, tokenizer: bundle.tokenizer, vocabSize: bundle.vocabSize,
            maxContextLength: contextLimit, serializedModel: [bundle.modelAssetPath],
            function: "main")
        engine = try await EngineFactory.createEngine(
            config: JSONEncoder().encode(config), modelURL: bundle.requireModelURL(for: "main"),
            options: EngineOptions(variant: "coreai-pipelined", staticInputBuffers: buffers))
        tokenizer = try await bundle.loadTokenizer()
    }

    public func tokenize(_ messages: [GemmaLanguageTurn]) -> [Int] {
        tokenizer.encode(text: Self.render(messages))
    }

    public static func render(_ messages: [GemmaLanguageTurn]) -> String {
        "<bos>"
            + messages.map {
                "<|turn>\($0.role == "assistant" ? "model" : $0.role)\n\($0.content)<turn|>\n"
            }.joined()
            + "<|turn>model\n"
    }

    /// Reset each request, consume real tokens, then join cancellation before releasing the lease.
    public func generate(
        tokens: [Int], maximumTokens: Int, temperature: Double, stopTokens: [Int],
        onText: @Sendable (String) throws -> Void
    ) async throws -> GemmaLanguageGeneration {
        guard !active else { throw GemmaLanguageError.busy }
        guard !tokens.isEmpty, maximumTokens > 0, maximumTokens <= contextLimit,
            tokens.count <= contextLimit - maximumTokens
        else { throw GemmaLanguageError.contextLimit }
        active = true
        defer { active = false }
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "Generation", id: signpostID, "input=\(tokens.count) outputBudget=\(maximumTokens)")
        defer { Self.signposter.endInterval("Generation", interval) }
        do {
            try Task.checkCancellation()
            try await engine.reset()
            let stopIDs = Set(
                ["<eos>", "<turn|>"].compactMap { tokenizer.convertTokenToId($0) } + stopTokens)
            let stream = try await engine.generate(
                with: tokens.map(Int32.init), samplingConfiguration: SamplingConfiguration(temperature: temperature),
                inferenceOptions: InferenceOptions(maxTokens: maximumTokens))
            var generated: [Int] = []
            var count = 0
            var stopped = false
            var emitted = ""
            for try await output in stream {
                try Task.checkCancellation()
                count += 1
                if count == 1 { Self.signposter.emitEvent("FirstNativeToken", id: signpostID) }
                let token = Int(output.tokenId)
                if stopIDs.contains(token) {
                    stopped = true
                    stream.setStopReason(.eos)
                    break
                }
                generated.append(token)
                let decoded = tokenizer.decode(tokens: generated, skipSpecialTokens: false)
                guard decoded.utf8.count <= 262144 else { throw GemmaLanguageError.outputTooLarge }
                var visible = GemmaResponseText.visible(decoded)
                while visible.last == "\u{FFFD}" { visible.removeLast() }
                guard visible.hasPrefix(emitted) else { throw GemmaLanguageError.nonMonotonicText }
                let delta = String(visible.dropFirst(emitted.count))
                if !delta.isEmpty {
                    if emitted.isEmpty {
                        Self.signposter.emitEvent("FirstVisibleText", id: signpostID, "generated=\(count)")
                    }
                    try onText(delta)
                }
                emitted = visible
            }
            // Pipelined decode owns a worker; cancel joins it even on early EOS.
            try await engine.cancel()
            try await engine.reset()
            try Task.checkCancellation()
            return GemmaLanguageGeneration(stopped: stopped, generatedTokens: count)
        } catch {
            // Preserve the original failure while joining the worker and clearing its state.
            do { try await engine.cancel() } catch {}
            do { try await engine.reset() } catch {}
            throw error
        }
    }

    private static func loadBuffer(url: URL, size: Int, device: any MTLDevice) throws -> any MTLBuffer {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw GemmaLanguageError.invalidTable(url.lastPathComponent) }
        defer { close(descriptor) }
        guard let buffer = device.makeBuffer(length: size, options: .storageModeShared) else {
            throw GemmaLanguageError.bufferAllocation(url.lastPathComponent)
        }
        var offset = 0
        while offset < size {
            let count = read(descriptor, buffer.contents() + offset, min(1 << 27, size - offset))
            guard count > 0 else { throw GemmaLanguageError.invalidTable(url.lastPathComponent) }
            offset += count
        }
        return buffer
    }
}

/// Reasoning channels are never forwarded as business Agent text.
public enum GemmaResponseText {
    public static func visible(_ text: String) -> String {
        let opener = "<|channel>"
        var remaining = text[...]
        var result = ""
        while let start = remaining.range(of: opener) {
            result += remaining[..<start.lowerBound]
            remaining = remaining[start.upperBound...]
            guard let newline = remaining.firstIndex(of: "\n") else { return result }
            let channel = remaining[..<newline]
            remaining = remaining[remaining.index(after: newline)...]
            if channel == "final" { continue }
            // Thought and unknown channels are withheld, including incomplete closing markers.
            guard let close = remaining.range(of: "<channel|>") else { return result }
            remaining = remaining[close.upperBound...]
        }
        // Withhold only a possible partial opening marker until its next token arrives.
        let tail = String(remaining)
        for length in stride(from: min(opener.count - 1, tail.count), through: 1, by: -1) {
            if tail.hasSuffix(opener.prefix(length)) {
                return result + tail.dropLast(length)
            }
        }
        return result + tail
    }
}
