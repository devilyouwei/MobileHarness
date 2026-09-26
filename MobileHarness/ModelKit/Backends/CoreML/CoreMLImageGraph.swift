import CoreML
import CoreVideo
import Foundation

/// Fixed RGB image input and a single float tensor output. Native objects remain actor isolated.
public actor CoreMLImageGraph {
    private let model: MLModel
    public init(contentsOf url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        if url.pathExtension == "mlpackage" {
            let compiled = try MLModel.compileModel(at: url)
            defer { try? FileManager.default.removeItem(at: compiled) }
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        } else {
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == ["image"],
            let input = description.inputDescriptionsByName["image"]?.imageConstraint,
            input.pixelsWide == 640, input.pixelsHigh == 640,
            let output = description.outputDescriptionsByName["predictions"]?.multiArrayConstraint,
            output.shape.map(\.intValue) == [1, 56, 8400]
        else { throw CoreMLGraphError.invalidTensor("YOLO image/output contract") }
    }
    public func run(rgb: Data) throws -> CoreMLTensor {
        try Task.checkCancellation()
        guard rgb.count == 640 * 640 * 3 else { throw CoreMLGraphError.invalidTensor("RGB size") }
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 640, kCVPixelFormatType_32BGRA, nil, &optional)
        guard status == kCVReturnSuccess, let pixels = optional else {
            throw CoreMLGraphError.invalidTensor("Pixel buffer allocation")
        }
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else {
            throw CoreMLGraphError.invalidTensor("Pixel buffer lock")
        }
        do {
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else {
                throw CoreMLGraphError.invalidTensor("Pixel buffer storage")
            }
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            rgb.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                let dst = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<640 {
                    for x in 0..<640 {
                        let i = (y * 640 + x) * 3
                        let j = y * stride + x * 4
                        dst[j] = src[i + 2]
                        dst[j + 1] = src[i + 1]
                        dst[j + 2] = src[i]
                        dst[j + 3] = 255
                    }
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixels)])
        let output = try model.prediction(from: provider)
        try Task.checkCancellation()
        guard let array = output.featureValue(for: "predictions")?.multiArrayValue,
            array.shape.map(\.intValue) == [1, 56, 8400]
        else { throw CoreMLGraphError.invalidOutput("predictions") }
        // Indexed access respects non-contiguous Core ML tensor strides.
        let values = (0..<56).flatMap { channel in
            (0..<8400).map { index in array[[0, NSNumber(value: channel), NSNumber(value: index)]].floatValue }
        }
        return CoreMLTensor(shape: [1, 56, 8400], values: values)
    }
}
