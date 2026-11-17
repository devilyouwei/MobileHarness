import CoreML
import Testing

@testable import ModelKitCoreML

@Test func coreMLDenseTensorTransferPreservesFloatValues() throws {
    for type in [MLMultiArrayDataType.float16, .float32, .double, .int32] {
        let array = try MLMultiArray(shape: [1, 2, 3], dataType: type)
        let values: [Float] = [-3, -2, 0, 1, 2, 3]
        CoreMLGraph.write(values, to: array)
        #expect(CoreMLGraph.read(array) == values)
        #expect(CoreMLGraph.read(array) == (0..<array.count).map { array[$0].floatValue })
    }
    let half = try MLMultiArray(shape: [2], dataType: .float16)
    CoreMLGraph.write([0.125, -0.625], to: half)
    #expect(CoreMLGraph.read(half) == [0.125, -0.625])
}

@Test func coreMLStridedTensorTransferPreservesPaddingAndOrder() throws {
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 6)
    storage.initialize(repeating: -999, count: 6)
    let array = try MLMultiArray(
        dataPointer: storage, shape: [2, 2], dataType: .float32, strides: [3, 1], deallocator: { $0.deallocate() })
    CoreMLGraph.write([1, 2, 3, 4], to: array)
    #expect(CoreMLGraph.read(array) == [1, 2, 3, 4])
    #expect(storage[2] == -999 && storage[5] == -999)
}
