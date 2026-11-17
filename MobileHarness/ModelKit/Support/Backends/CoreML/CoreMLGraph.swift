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
                Self.accepts(tensor.shape, constraint: constraint),
                tensor.values.count == tensor.shape.reduce(1, *), tensor.values.allSatisfy(\.isFinite)
            else { throw CoreMLGraphError.invalidTensor(name) }
            let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
            Self.write(tensor.values, to: array)
            features[name] = MLFeatureValue(multiArray: array)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        try Task.checkCancellation()
        var tensors: [String: CoreMLTensor] = [:]
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue, array.count <= 1_048_576 else {
                throw CoreMLGraphError.invalidOutput(name)
            }
            let values = Self.read(array)
            guard values.allSatisfy(\.isFinite) else { throw CoreMLGraphError.invalidOutput(name) }
            tensors[name] = CoreMLTensor(shape: array.shape.map(\.intValue), values: values)
        }
        return tensors
    }
    // Dense arrays avoid per-element NSNumber allocation; arbitrary views retain indexed semantics.
    static func read(_ array: MLMultiArray) -> [Float] {
        if isContiguous(array) {
            switch array.dataType {
            case .float32:
                return Array(
                    UnsafeBufferPointer(
                        start: array.dataPointer.assumingMemoryBound(to: Float.self), count: array.count))
            case .float16:
                return UnsafeBufferPointer(
                    start: array.dataPointer.assumingMemoryBound(to: Float16.self), count: array.count
                ).map { Float($0) }
            default: break
            }
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
    static func write(_ values: [Float], to array: MLMultiArray) {
        precondition(values.count == array.count)
        if isContiguous(array) {
            switch array.dataType {
            case .float32:
                values.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        array.dataPointer.assumingMemoryBound(to: Float.self).update(from: base, count: values.count)
                    }
                }
                return
            case .float16:
                let target = array.dataPointer.assumingMemoryBound(to: Float16.self)
                for index in values.indices { target[index] = Float16(values[index]) }
                return
            default: break
            }
        }
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
    }
    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        guard array.shape.count == array.strides.count else { return false }
        var stride = 1
        for index in array.shape.indices.reversed() {
            let dimension = array.shape[index].intValue
            guard dimension > 0, dimension == 1 || array.strides[index].intValue == stride else { return false }
            let next = stride.multipliedReportingOverflow(by: dimension)
            guard !next.overflow else { return false }
            stride = next.partialValue
        }
        return stride == array.count
    }
    private static func accepts(_ shape: [Int], constraint: MLMultiArrayConstraint) -> Bool {
        guard !shape.isEmpty, shape.count <= 8 else { return false }
        var count = 1
        for size in shape {
            guard size > 0, size <= 1_048_576 / count else { return false }
            count *= size
        }
        let rule = constraint.shapeConstraint
        switch rule.type {
        case .enumerated:
            return rule.enumeratedShapes.contains { $0.map(\.intValue) == shape }
        case .range:
            guard shape.count == constraint.shape.count else { return false }
            return shape.enumerated().allSatisfy { index, size in
                guard index < rule.sizeRangeForDimension.count else { return false }
                let range = rule.sizeRangeForDimension[index].rangeValue
                return NSLocationInRange(size, range)
            }
        default: return shape == constraint.shape.map(\.intValue)
        }
    }

}
