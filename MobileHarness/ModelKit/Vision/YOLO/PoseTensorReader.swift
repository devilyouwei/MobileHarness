import Accelerate
import CoreML
import ModelKitCoreML

/// Bulk access avoids NSNumber indexing per scalar. Native storage never escapes the closure.
enum PoseTensorReader {
    static func read(_ array: MLMultiArray) throws -> CoreMLTensor {
        guard array.shape.map(\.intValue) == [1, 300, 57] else {
            throw CoreMLGraphError.invalidOutput("predictions shape")
        }
        let values: [Float] = try array.withUnsafeBytes { bytes in
            // Core ML may materialize storage when entering the closure; read strides only now.
            let strides = array.strides.map(\.intValue)
            guard strides.count == 3, strides.allSatisfy({ $0 > 0 }) else {
                throw CoreMLGraphError.invalidOutput("predictions strides")
            }
            switch array.dataType {
            case .float32:
                return try copy(bytes.bindMemory(to: Float.self), strides: strides) { Float($0) }
            case .float16:
                return try copy(bytes.bindMemory(to: Float16.self), strides: strides) { Float($0) }
            case .double:
                return try copy(bytes.bindMemory(to: Double.self), strides: strides) { Float($0) }
            default: throw CoreMLGraphError.invalidOutput("predictions type")
            }
        }
        return CoreMLTensor(shape: [1, 300, 57], values: values)
    }

    private static func copy<T>(
        _ source: UnsafeBufferPointer<T>, strides: [Int], convert: (T) -> Float
    ) throws -> [Float] {
        // Bounds checks without overflowing even for an invalid external descriptor.
        guard !source.isEmpty, strides[1] <= (source.count - 1) / 299,
            strides[2] <= (source.count - 1 - 299 * strides[1]) / 56
        else { throw CoreMLGraphError.invalidOutput("predictions storage") }
        if T.self == Float.self, strides[1] == 57, strides[2] == 1 {
            let pointer = UnsafeRawPointer(source.baseAddress!).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: 300 * 57))
        }
        var values = [Float](repeating: 0, count: 300 * 57)
        try values.withUnsafeMutableBufferPointer { destination in
            for channel in 0..<300 {
                try Task.checkCancellation()
                let input = source.baseAddress!.advanced(by: channel * strides[1])
                let output = destination.baseAddress!.advanced(by: channel * 57)
                if T.self == Float.self {
                    // vDSP supports strided copies without per-element Swift work.
                    let floats = UnsafeRawPointer(input).assumingMemoryBound(to: Float.self)
                    var zero: Float = 0
                    vDSP_vsadd(floats, vDSP_Stride(strides[2]), &zero, output, 1, 57)
                } else {
                    for index in 0..<57 { output[index] = convert(input[index * strides[2]]) }
                }
            }
        }
        return values
    }
}
