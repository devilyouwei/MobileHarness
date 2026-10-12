import CoreML
import CoreVideo
import Foundation
import ImageIO
import ModelKitCoreML
import Vision
import os

/// Fixed RGB image input and a single float tensor output. Native objects remain actor isolated.
public actor YOLOImageGraph {
    private let model: MLModel
    private let outputName: String
    private let visionModel: VNCoreMLModel
    public enum Compute: Sendable { case cpuAndNeuralEngine, all }
    private let preparation = YOLOImagePreparation()
    private let signposter = OSSignposter(subsystem: "dev.mobileharness.models", category: "Pose")
    public init(contentsOf url: URL, compute: Compute = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute == .all ? .all : .cpuAndNeuralEngine
        if url.pathExtension == "mlpackage" {
            let compiled = try MLModel.compileModel(at: url)
            defer { try? FileManager.default.removeItem(at: compiled) }
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        } else {
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        visionModel = try VNCoreMLModel(for: model)
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == ["image"],
            let input = description.inputDescriptionsByName["image"]?.imageConstraint,
            input.pixelsWide == 640, input.pixelsHigh == 640,
            description.outputDescriptionsByName.count == 1,
            let name = description.outputDescriptionsByName.keys.first,
            let output = description.outputDescriptionsByName[name]?.multiArrayConstraint,
            output.shape.map(\.intValue) == [1, 300, 57]
        else { throw CoreMLGraphError.invalidTensor("YOLO26 end-to-end image/output contract") }
        outputName = name
    }
    public func run(rgb: Data, layout: YOLOImageLayout) throws -> CoreMLTensor {
        try Task.checkCancellation()
        let prepareInterval = signposter.beginInterval("PrepareImage")
        let pixels: CVPixelBuffer
        do {
            defer { signposter.endInterval("PrepareImage", prepareInterval) }
            pixels = try preparation.prepare(rgb: rgb, layout: layout)
        }
        try Task.checkCancellation()
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixels)])
        let predictionInterval = signposter.beginInterval("Prediction")
        let output: any MLFeatureProvider
        do {
            defer { signposter.endInterval("Prediction", predictionInterval) }
            output = try model.prediction(from: provider)
        }
        try Task.checkCancellation()
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLGraphError.invalidOutput("predictions")
        }
        let readInterval = signposter.beginInterval("ReadTensor")
        defer { signposter.endInterval("ReadTensor", readInterval) }
        return try PoseTensorReader.read(array)
    }
    /// The producer retains immutable pixels; the closure is invoked only on this actor.
    public func runNative(source: @Sendable () -> CVPixelBuffer, rotation: Int) throws -> CoreMLTensor {
        try Task.checkCancellation()
        guard (0...3).contains(rotation) else { throw CoreMLGraphError.invalidTensor("Orientation") }
        let pixels = source()
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304,
            CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA
        else { throw CoreMLGraphError.invalidTensor("Native image buffer") }
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFit
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        let interval = signposter.beginInterval("VisionPreprocessAndPrediction")
        do {
            defer { signposter.endInterval("VisionPreprocessAndPrediction", interval) }
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientations[rotation], options: [:])
                .perform([request])
        }
        try Task.checkCancellation()
        guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
            let array = observations.first(where: { $0.featureName == outputName })?.featureValue.multiArrayValue
        else { throw CoreMLGraphError.invalidOutput("Vision predictions") }
        let readInterval = signposter.beginInterval("ReadTensor")
        defer { signposter.endInterval("ReadTensor", readInterval) }
        return try PoseTensorReader.read(array)
    }

}
