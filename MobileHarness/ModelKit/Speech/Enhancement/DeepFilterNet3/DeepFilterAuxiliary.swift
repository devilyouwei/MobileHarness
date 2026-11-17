import Foundation
import ModelKit

/// Strict, bounded reader for the published stored ZIP / little-endian float32 NPY bundle.
struct DeepFilterAuxiliary: Sendable {
    let arrays: [String: [Float]]
    static let shapes = [
        "erb_fb": [481, 32], "erb_inv_fb": [32, 481], "window": [960],
        "mean_norm_state": [32], "unit_norm_state": [1, 96],
    ]
    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 262144 else { throw CapabilityError.invalidRequest("Invalid auxiliary size") }
        try self.init(data: Data(contentsOf: url))
    }
    init(data: Data) throws {
        func invalid() -> CapabilityError { .invalidRequest("Invalid DeepFilterNet3 auxiliary archive") }
        guard data.count <= 262144 else { throw invalid() }
        func integer(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, count <= 8, offset <= data.count - count else { throw invalid() }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(data[offset + i]) << (8 * i) }
            guard value <= 262144 || (count == 4 && value == 0xffff_ffff) else { throw invalid() }
            return Int(value)
        }
        var result: [String: [Float]] = [:]
        var offset = 0
        while offset + 4 <= data.count, Array(data[offset..<offset + 4]) == [80, 75, 3, 4] {
            guard try integer(offset + 6, 2) == 0, try integer(offset + 8, 2) == 0 else { throw invalid() }
            var compressed = try integer(offset + 18, 4)
            var size = try integer(offset + 22, 4)
            let nameLength = try integer(offset + 26, 2)
            let extraLength = try integer(offset + 28, 2)
            let nameStart = offset + 30
            let extraStart = nameStart + nameLength
            let start = extraStart + extraLength
            guard start <= data.count,
                let filename = String(data: data[nameStart..<extraStart], encoding: .utf8),
                filename.hasSuffix(".npy")
            else { throw invalid() }
            if size == 0xffff_ffff || compressed == 0xffff_ffff {
                guard extraLength >= 20, try integer(extraStart, 2) == 1,
                    try integer(extraStart + 2, 2) >= 16
                else { throw invalid() }
                size = try integer(extraStart + 4, 8)
                compressed = try integer(extraStart + 12, 8)
            }
            guard size == compressed, size >= 10, start <= data.count - size else { throw invalid() }
            let name = String(filename.dropLast(4))
            guard let shape = Self.shapes[name], result[name] == nil,
                Array(data[start..<start + 8]) == [147, 78, 85, 77, 80, 89, 1, 0]
            else { throw invalid() }
            let headerSize = try integer(start + 8, 2)
            let payload = start + 10 + headerSize
            guard payload <= start + size,
                let header = String(data: data[start + 10..<payload], encoding: .ascii),
                header.contains("'<f4'"),
                let key = header.range(of: "'shape':"),
                let open = header[key.upperBound...].firstIndex(of: "("),
                let close = header[open...].firstIndex(of: ")")
            else { throw invalid() }
            let actual = header[header.index(after: open)..<close].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            let count = shape.reduce(1, *)
            guard actual == shape, start + size - payload == count * 4 else { throw invalid() }
            var values: [Float] = []
            for i in 0..<count {
                let index = payload + i * 4
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[index + $1]) << (8 * $1) }
                let value = Float(bitPattern: bits)
                guard value.isFinite else { throw invalid() }
                values.append(value)
            }
            if header.contains("'fortran_order': True"), shape.count == 2 {
                let raw = values
                for row in 0..<shape[0] {
                    for column in 0..<shape[1] {
                        values[row * shape[1] + column] = raw[column * shape[0] + row]
                    }
                }
            } else if !header.contains("'fortran_order': False") {
                throw invalid()
            }
            result[name] = values
            offset = start + size
        }
        guard Set(result.keys) == Set(Self.shapes.keys),
            result["unit_norm_state"]!.allSatisfy({ $0 > 0 })
        else { throw invalid() }
        arrays = result
    }
}
