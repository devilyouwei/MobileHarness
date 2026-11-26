import Foundation
import ModelKit
import ModelKitCoreML

public actor SmartTurn: SpeechEndpointCapability {
    private static let windowSamples = 128_000
    private let modelURL: URL
    private let resource: ModelResource<CoreMLGraph>

    public init(context: ModelContext, artifacts: URL) throws {
        let url = artifacts.appendingPathComponent("smart_turn.mlmodelc")
        modelURL = url
        resource = try context.resource {
            try await CoreMLGraph(contentsOf: url, compute: .cpuAndNeuralEngine)
        }
    }

    public var availability: CapabilityAvailability {
        FileManager.default.fileExists(atPath: modelURL.path)
            ? .available : .unavailable(reason: "Smart Turn model artifacts are not installed")
    }

    public func completionProbability(for samples: [Float]) async throws -> Float? {
        guard !samples.isEmpty, samples.count <= Self.windowSamples else {
            throw CapabilityError.invalidRequest("Invalid Smart Turn audio window")
        }
        guard let lease = try await resource.acquireIfReady() else { return nil }
        do {
            let audio = [Float](repeating: 0, count: Self.windowSamples - samples.count) + samples
            let outputs = try await lease.model.run(["audio": .init(shape: [1, Self.windowSamples], values: audio)])
            guard let probability = outputs["probability"], probability.shape == [1, 1],
                let value = probability.values.first, (0...1).contains(value)
            else { throw CapabilityError.invalidRequest("Unexpected Smart Turn output") }
            await resource.release(lease.id)
            return value
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}
