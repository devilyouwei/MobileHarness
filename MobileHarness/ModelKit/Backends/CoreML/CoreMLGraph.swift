import CoreML
import Foundation

public struct CoreMLTensor: Sendable {
    public let shape: [Int]
    public let values: [Float]
    public init(shape: [Int], values: [Float]) {
        self.shape = shape
        self.values = values
    }
}

public enum CoreMLGraphError: Error {
    case invalidTensor(String)
    case invalidOutput(String)
}

/// All MLModel/MLMultiArray objects stay on this actor. Callers exchange immutable values.
public actor CoreMLGraph {
    private let model: MLModel
    public enum Compute: Sendable { case cpuOnly, cpuAndNeuralEngine }
    public init(contentsOf url: URL, functionName: String? = nil, compute: Compute = .cpuOnly) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute == .cpuOnly ? .cpuOnly : .cpuAndNeuralEngine
        configuration.functionName = functionName
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    public func run(_ inputs: [String: CoreMLTensor]) throws -> [String: CoreMLTensor] {
        try Task.checkCancellation()
        let descriptions = model.modelDescription.inputDescriptionsByName
        guard Set(inputs.keys) == Set(descriptions.keys) else { throw CoreMLGraphError.invalidTensor("names") }
        var features: [String: MLFeatureValue] = [:]
        for (name, tensor) in inputs {
            guard let constraint = descriptions[name]?.multiArrayConstraint,
                tensor.shape == constraint.shape.map(\.intValue),
                tensor.values.count == tensor.shape.reduce(1, *), tensor.values.allSatisfy(\.isFinite)
            else { throw CoreMLGraphError.invalidTensor(name) }
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            for (index, value) in tensor.values.enumerated() { array[index] = NSNumber(value: value) }
            features[name] = MLFeatureValue(multiArray: array)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        try Task.checkCancellation()
        var tensors: [String: CoreMLTensor] = [:]
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue, array.count <= 1_048_576 else {
                throw CoreMLGraphError.invalidOutput(name)
            }
            let values = (0..<array.count).map { array[$0].floatValue }
            guard values.allSatisfy(\.isFinite) else { throw CoreMLGraphError.invalidOutput(name) }
            tensors[name] = CoreMLTensor(shape: array.shape.map(\.intValue), values: values)
        }
        return tensors
    }
}
