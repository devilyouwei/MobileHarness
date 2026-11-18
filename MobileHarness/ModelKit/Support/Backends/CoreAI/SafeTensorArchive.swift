#if canImport(CoreAI)
    import Foundation

    /// Mapped F32 safetensors storage used by graphs with external constant weight inputs.
    @available(iOS 27, macOS 27, *)
    public struct SafeTensorArchive {
        private struct Entry: Decodable {
            enum CodingKeys: String, CodingKey {
                case dtype, shape
                case dataOffsets = "data_offsets"
            }
            let dtype: String
            let shape: [Int]
            let dataOffsets: [Int]
        }
        private let data: Data
        private let offset: Int
        private let entries: [String: Entry]

        public init(contentsOf url: URL) throws {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count >= 8 else { throw CoreAIGraphError.invalidWeights("Missing header") }
            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            guard length <= 16 * 1024 * 1024, length <= data.count - 8 else {
                throw CoreAIGraphError.invalidWeights("Invalid header length")
            }
            offset = 8 + Int(length)
            let object = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<offset))
            guard var dictionary = object as? [String: Any] else {
                throw CoreAIGraphError.invalidWeights("Invalid header")
            }
            dictionary.removeValue(forKey: "__metadata__")
            entries = try JSONDecoder().decode(
                [String: Entry].self, from: JSONSerialization.data(withJSONObject: dictionary))
        }

        public func tensor(named name: String, shape: [Int]) throws -> TensorValue {
            guard let entry = entries[name], entry.dtype == "F32", entry.shape == shape,
                entry.dataOffsets.count == 2, shape.allSatisfy({ $0 >= 0 })
            else {
                throw CoreAIGraphError.invalidWeights("Invalid F32 tensor: \(name)")
            }
            var count = 1
            for dimension in shape {
                let product = count.multipliedReportingOverflow(by: dimension)
                guard !product.overflow else { throw CoreAIGraphError.invalidWeights(name) }
                count = product.partialValue
            }
            let start = entry.dataOffsets[0]
            let end = entry.dataOffsets[1]
            guard start >= 0, end >= start, end <= data.count - offset,
                count <= (data.count - offset) / 4, end - start == count * 4, (offset + start) % 4 == 0
            else {
                throw CoreAIGraphError.invalidWeights("Invalid tensor bounds: \(name)")
            }
            let values: [Float] = data.withUnsafeBytes { raw in
                Array(
                    UnsafeRawBufferPointer(rebasing: raw[(offset + start)..<(offset + end)]).bindMemory(to: Float.self))
            }
            return .float32(values, shape: shape)
        }
    }
#endif
