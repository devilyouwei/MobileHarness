import Foundation
import ModelKitCoreAI
import Testing

@available(macOS 27, iOS 27, *)
@Test func decisionWeightArchiveReadsScalarsAndRejectsInvalidTensorBounds() throws {
    #if canImport(CoreAI)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
        defer { try? FileManager.default.removeItem(at: url) }
        var header = Data(
            #"{"w":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"bad":{"dtype":"F32","shape":[2],"data_offsets":[0,12]}}"#
                .utf8)
        while header.count % 8 != 0 { header.append(32) }
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        for number: Float in [1.25, -2.5] {
            var bits = number.bitPattern.littleEndian
            data.append(withUnsafeBytes(of: &bits) { Data($0) })
        }
        try data.write(to: url)
        let archive = try SafeTensorArchive(contentsOf: url)
        #expect(try archive.tensor(named: "w", shape: [2]).floats() == [1.25, -2.5])
        #expect(throws: CoreAIGraphError.self) { try archive.tensor(named: "bad", shape: [2]) }
        #expect(throws: CoreAIGraphError.self) { try archive.tensor(named: "w", shape: [1]) }
        try Data([0]).write(to: url)
        #expect(throws: CoreAIGraphError.self) { try SafeTensorArchive(contentsOf: url) }
    #else
        Issue.record("CoreAI is required for the weight archive integration test")
    #endif
}
