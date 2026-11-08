import AgentCore
import CoreGraphics
import Foundation
import ImageIO
import ModelKit
import StorageCore
import Testing

@testable import Agents
@testable import ModelKitOpenAI
@testable import PlatformKit

let modelPhotoLimits = NativeImageCompression.Limits(
    maximumDimension: 1568, maximumPixels: 1_048_576, maximumBytes: 1024 * 1024)

func compressionFixture(
    width: Int, height: Int, orientation: Int = 1, noise: Bool = false, format: String = "public.jpeg"
) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: width * height * 3)
    var random: UInt32 = 17
    for pixel in 0..<width * height {
        if noise {
            for channel in 0..<3 {
                random = random &* 1_664_525 &+ 1_013_904_223
                bytes[pixel * 3 + channel] = UInt8(truncatingIfNeeded: random >> 24)
            }
        } else {
            bytes[pixel * 3 + (pixel % width < width / 2 ? 0 : 2)] = 255
        }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(
        CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, format as CFString, 1, nil))
    CGImageDestinationAddImage(
        destination, image,
        [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: orientation] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private func preparedImage(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func compressionColor(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let sample = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

@Test(arguments: [(4000, 3000), (3000, 4000), (6000, 1000), (2000, 2000)])
func nativeImageCompressionPreservesCompositionAndBounds(size: (Int, Int)) async throws {
    let original = try compressionFixture(width: size.0, height: size.1)
    let compressed = try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits)
    let image = try preparedImage(compressed)
    #expect(max(image.width, image.height) <= 1568 && image.width * image.height <= 1_048_576)
    #expect(compressed.count <= 1024 * 1024 && compressed.count < original.count)
    #expect(abs(Double(image.width) / Double(image.height) - Double(size.0) / Double(size.1)) < 0.02)
    let left = try compressionColor(image, x: image.width / 4, y: image.height / 2)
    let right = try compressionColor(image, x: image.width * 3 / 4, y: image.height / 2)
    #expect(left[0] > 200 && left[2] < 50 && right[2] > 200 && right[0] < 50)
}

@Test func nativeImageCompressionNormalizesEXIFOrientationAndKeepsSmallJPEG() async throws {
    let upright = try compressionFixture(width: 80, height: 40)
    #expect(try await NativeImageCompression.jpeg(from: upright, limits: modelPhotoLimits) == upright)
    let rotated = try compressionFixture(width: 800, height: 400, orientation: 6)
    let result = try await NativeImageCompression.jpeg(from: rotated, limits: modelPhotoLimits)
    let image = try preparedImage(result)
    #expect(image.width == 400 && image.height == 800)
    let top = try compressionColor(image, x: 200, y: 200)
    let bottom = try compressionColor(image, x: 200, y: 600)
    #expect(top[0] > 200 && bottom[2] > 200)
}

@Test func nativeImageCompressionMeetsByteBudgetOrFailsExplicitly() async throws {
    let original = try compressionFixture(width: 1024, height: 768, noise: true)
    let result = try await NativeImageCompression.jpeg(
        from: original, limits: .init(maximumDimension: 1024, maximumPixels: 1024 * 768, maximumBytes: 128 * 1024))
    #expect(result.count <= 128 * 1024)
    #expect(try preparedImage(result).width < 1024)
    await #expect(throws: NativeImageCompression.Failure.sizeBudgetExceeded) {
        try await NativeImageCompression.jpeg(
            from: original, limits: .init(maximumDimension: 1024, maximumPixels: 1024 * 768, maximumBytes: 1024))
    }
}

@Test func nativeImageCompressionRejectsMalformedInputLimitsAndCancellation() async throws {
    for invalid in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] {
        await #expect(throws: NativeImageCompression.Failure.invalidImage) {
            try await NativeImageCompression.jpeg(from: invalid, limits: modelPhotoLimits)
        }
    }
    let original = try compressionFixture(width: 80, height: 40)
    let unsupported = try compressionFixture(width: 80, height: 40, format: "com.compuserve.gif")
    await #expect(throws: NativeImageCompression.Failure.unsupportedImage) {
        try await NativeImageCompression.jpeg(from: unsupported, limits: modelPhotoLimits)
    }
    for limits in [
        NativeImageCompression.Limits(maximumDimension: 0, maximumPixels: 1, maximumBytes: 1024),
        .init(maximumDimension: 4097, maximumPixels: 1, maximumBytes: 1024),
        .init(maximumDimension: 10, maximumPixels: 0, maximumBytes: 1024),
        .init(maximumDimension: 10, maximumPixels: 100, maximumBytes: 100),
        .init(maximumDimension: 10, maximumPixels: 100, maximumBytes: 1024, quality: .nan),
    ] {
        await #expect(throws: NativeImageCompression.Failure.invalidLimits) {
            try await NativeImageCompression.jpeg(from: original, limits: limits)
        }
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func nativeImageCompressionConvertsPNGWithoutUpscaling() async throws {
    let original = try compressionFixture(width: 160, height: 80, format: "public.png")
    let result = try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits)
    let image = try preparedImage(result)
    #expect(image.width == 160 && image.height == 80)
}

@Test func nativeCameraPhotoPreparationFitsLargeJPEGWithoutAnotherCapture() async throws {
    let original = try compressionFixture(width: 3072, height: 2304, orientation: 6, noise: true)
    try #require(original.count > 4 * 1024 * 1024)
    await #expect(throws: NativeImageCompression.Failure.invalidImage) {
        try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits)
    }
    let result = try await NativeImageCompression.cameraPhotoJPEG(from: original)
    let image = try preparedImage(result)
    #expect(result.count <= 4 * 1024 * 1024)
    #expect(image.width <= 2304 && image.height <= 3072)
    #expect(abs(Double(image.width) / Double(image.height) - 0.75) < 0.002)
}

@Test func nativeCameraPhotoPreparationPreservesSmallOriginalAndRejectsInvalidDataOrCancellation() async throws {
    let original = try compressionFixture(width: 80, height: 40, orientation: 6)
    #expect(try await NativeImageCompression.cameraPhotoJPEG(from: original) == original)
    for invalid in [
        Data(), Data(repeating: 0, count: 4 * 1024 * 1024 + 1),
        Data(repeating: 0, count: 32 * 1024 * 1024 + 1),
    ] {
        await #expect(throws: NativeImageCompression.Failure.invalidImage) {
            try await NativeImageCompression.cameraPhotoJPEG(from: invalid)
        }
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeImageCompression.cameraPhotoJPEG(from: original)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func nativeCameraPhotoPreparationPreservesMirroredComposition() async throws {
    var original = try compressionFixture(width: 80, height: 40, orientation: 2)
    // Synthetic trailing padding forces preparation without changing the image or its EXIF mirror.
    original.append(Data(repeating: 0, count: 4 * 1024 * 1024))
    let result = try await NativeImageCompression.cameraPhotoJPEG(from: original)
    let image = try preparedImage(result)
    #expect(image.width == 80 && image.height == 40)
    let left = try compressionColor(image, x: 20, y: 20)
    let right = try compressionColor(image, x: 60, y: 20)
    #expect(left[2] > 200 && left[0] < 50 && right[0] > 200 && right[2] < 50)
}

@Test func nativeImageCompressionEnforcesExplicitInputBudgets() async throws {
    let original = try compressionFixture(width: 80, height: 40)
    for inputLimits in [
        NativeImageCompression.InputLimits(maximumBytes: 0), .init(maximumBytes: 32 * 1024 * 1024 + 1),
        .init(maximumDimension: 0), .init(maximumDimension: 65536), .init(maximumPixels: 0),
        .init(maximumPixels: 268_435_457),
    ] {
        await #expect(throws: NativeImageCompression.Failure.invalidLimits) {
            try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits, inputLimits: inputLimits)
        }
    }
    for inputLimits in [
        NativeImageCompression.InputLimits(maximumBytes: original.count - 1), .init(maximumDimension: 79),
        .init(maximumPixels: 3199),
    ] {
        await #expect(throws: NativeImageCompression.Failure.invalidImage) {
            try await NativeImageCompression.jpeg(from: original, limits: modelPhotoLimits, inputLimits: inputLimits)
        }
    }
}

actor ModelPhotoReadCounter {
    private(set) var count = 0
    func read() { count += 1 }
}

private struct CompressedPhotoModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    var supportsImages = true
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> { throw CancellationError() }
}

private enum PhotoPreparationTestFailure: Error { case expected }

@Test func assistantWebScreenshotResultsBecomeScopedUntrustedImages() async throws {
    let input = AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("web"))
    let bytes = try compressionFixture(width: 80, height: 40)
    for path in ["browse", "snapshot", "navigate"] {
        let messages = try await AssistantContextBuilder.webImageObservations(
            [
                .init(
                    path: "Web.Page." + path,
                    result: .init(callID: UUID().uuidString, value: #"{"mediaID":"media_1"}"#))
            ],
            input: input, chat: CompressedPhotoModel(),
            read: { id, received in
                #expect(received.id == input.id && received.sessionID == input.sessionID)
                return try ChatImage(id: id, data: bytes)
            }, prepareJPEG: { data, _ in data })
        #expect(messages.count == 1)
        #expect(messages.first?.images?.first?.id == "media_1")
        #expect(messages.first?.content.contains("untrusted data") == true)
    }
}

@Test func assistantWebImagePreparationRejectsErrorsInvalidOutputAndForeignIdentity() async throws {
    let id = "media_1"
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("photo"))
    let observation = AgentChatObservation(
        path: "Web.Page.snapshot",
        result: ToolResult(callID: UUID().uuidString, value: "{\"mediaID\":\"\(id)\"}"))
    let original = try compressionFixture(width: 80, height: 40)
    let read: @Sendable (String, AgentInput) async throws -> ChatImage = { id, _ in
        try ChatImage(id: id, data: original)
    }
    await #expect(throws: PhotoPreparationTestFailure.expected) {
        try await AssistantContextBuilder.webImageObservations(
            [observation], input: input, chat: CompressedPhotoModel(), read: read,
            prepareJPEG: { _, _ in throw PhotoPreparationTestFailure.expected })
    }
    for output in [Data(), Data(repeating: 1, count: 1024 * 1024 + 1)] {
        await #expect(throws: CapabilityError.self) {
            try await AssistantContextBuilder.webImageObservations(
                [observation], input: input, chat: CompressedPhotoModel(), read: read,
                prepareJPEG: { _, _ in output })
        }
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await AssistantContextBuilder.webImageObservations(
            [observation], input: input, chat: CompressedPhotoModel(),
            read: { _, _ in try ChatImage(id: UUID().uuidString, data: original) },
            prepareJPEG: { _, _ in
                Issue.record("A foreign photo must not reach preparation")
                return original
            })
    }
    let cancelled = Task {
        try await AssistantContextBuilder.webImageObservations(
            [observation], input: input, chat: CompressedPhotoModel(), read: read,
            prepareJPEG: { data, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return data
            })
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func assistantWebImagePreparationSkipsUnsupportedModelsAndNonPhotoResults() async throws {
    let id = "media_1"
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("photo"))
    let observation = AgentChatObservation(
        path: "Web.Page.snapshot",
        result: ToolResult(callID: UUID().uuidString, value: "{\"mediaID\":\"\(id)\"}"))
    let read: @Sendable (String, AgentInput) async throws -> ChatImage = { _, _ in
        Issue.record("Skipped observations must not read a photo")
        throw PhotoPreparationTestFailure.expected
    }
    let prepare: @Sendable (Data, AssistantWebImagePolicy) async throws -> Data = { _, _ in
        Issue.record("Skipped observations must not prepare a photo")
        throw PhotoPreparationTestFailure.expected
    }
    let unavailable = try await AssistantContextBuilder.webImageObservations(
        [observation], input: input, chat: CompressedPhotoModel(supportsImages: false), read: read,
        prepareJPEG: prepare)
    #expect(unavailable.count == 1 && unavailable.first?.images == nil)
    #expect(unavailable.first?.content.contains("image analysis is unavailable") == true)
    let ignored = try await AssistantContextBuilder.webImageObservations(
        [
            .init(path: "Camera.Capture.savePhoto", result: observation.result),
            .init(
                path: "Web.Page.snapshot",
                result: .init(callID: observation.result.callID, value: "failed", isError: true)),
        ], input: input, chat: CompressedPhotoModel(), read: read, prepareJPEG: prepare)
    #expect(ignored.isEmpty)
}

@Test func modelPhotoUploadUsesReducedBytesWhileStoredOriginalSurvivesReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("photo"))
    let owner = StorageOwner(namespace: "photos", source: "assistant", session: input.sessionID, input: input.id)
    let original = try compressionFixture(width: 4000, height: 3000)
    let store = try fixtureMediaStore(root: directory)
    let id = try await store.save(original, owner: owner)
    let observation = AgentChatObservation(
        path: "Web.Page.snapshot",
        result: ToolResult(callID: UUID().uuidString, value: "{\"mediaID\":\"\(id)\"}"))
    let handler = AssistantContextBuilder.webImageObservationHandler(
        read: { id, _ in
            try await ChatImage(id: id, data: store.read(id, owner: owner))
        },
        prepareJPEG: { data, policy in
            #expect(data == original)
            #expect(policy.maximumDimension == 1568 && policy.maximumPixels == 1_048_576)
            #expect(policy.maximumBytes == 1024 * 1024 && policy.quality == 0.82)
            return try await NativeImageCompression.jpeg(
                from: data,
                limits: .init(
                    maximumDimension: policy.maximumDimension, maximumPixels: policy.maximumPixels,
                    maximumBytes: policy.maximumBytes, quality: policy.quality))
        })
    let messages = try await handler([observation], input, CompressedPhotoModel())
    let attachment = try #require(messages.first?.images?.first)
    #expect(attachment.id == id && attachment.mimeType == "image/jpeg" && attachment.data != original)
    let decoded = try preparedImage(attachment.data)
    #expect(decoded.width * decoded.height <= 1_048_576)
    let configuration = try OpenAIChatConfiguration(
        baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "", model: "gpt-4o")
    let request = try ChatRequest(
        messages: messages, context: InferenceContext(requestID: input.id, scopeID: input.sessionID))
    let http = try configuration.request(request)
    let body = try #require(http.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let wireMessages = try #require(object["input"] as? [[String: Any]])
    let content = try #require(wireMessages.first?["content"] as? [[String: Any]])
    let wireImage = try #require(content.first { $0["type"] as? String == "input_image" })
    let url = try #require(wireImage["image_url"] as? String)
    #expect(url == "data:image/jpeg;base64," + attachment.data.base64EncodedString())
    #expect(wireImage["detail"] as? String == "auto")
    let reopened = try fixtureMediaStore(root: directory)
    #expect(try await reopened.read(id, owner: owner) == original)
}
