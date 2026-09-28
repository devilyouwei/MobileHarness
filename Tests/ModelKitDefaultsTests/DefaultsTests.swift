import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import Testing

@Test func defaultAssemblyIsLazyAndSynthesisUsesMossNano() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    // Standalone Swift Testing does not expose its XCTest bundle to MLX's bundle search.
    let testResources = try #require(Bundle(for: TestBundleAnchor.self).resourceURL)
    let metalBundle = testResources.appendingPathComponent("mlx-swift_Cmlx.bundle")
    let metalResources = try #require(Bundle(url: metalBundle)?.resourceURL)
    let previousDirectory = FileManager.default.currentDirectoryPath
    try #require(FileManager.default.changeCurrentDirectoryPath(metalResources.path))
    defer { _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let managers = try await withThrowingTaskGroup(of: ModelManager.self) { group in
        for _ in 0..<16 { group.addTask { try await ModelKitDefaults.manager(resources: missing) } }
        var results: [ModelManager] = []
        for try await result in group { results.append(result) }
        return results
    }
    let manager = try #require(managers.first)
    #expect(managers.allSatisfy { $0 === manager })
    await #expect(throws: ModelKitConfigurationError.resourceDirectoryConflict) {
        _ = try await ModelKitDefaults.manager(resources: missing.appendingPathComponent("other"))
    }
    for capability in [ProvidedCapability.chat, .recognition, .synthesis, .voiceActivity, .pose] {
        #expect(try await manager.status(capability) == .registered)
    }
    let pose = try await manager.get(.pose, load: false)
    let samePose = try await manager.get(.pose, load: false)
    let samePoseInstance = (pose as AnyObject) === (samePose as AnyObject)
    #expect(samePoseInstance)
    #expect(try await manager.status(.pose) == .unloaded)
    let synthesis = try await manager.get(.synthesis, load: false)
    let again = try await manager.get(.synthesis, load: false)
    let sameInstance = (synthesis as AnyObject) === (again as AnyObject)
    #expect(sameInstance)
    let mossNano = try await manager.get(ModelKitDefaults.mossNano, as: .synthesis, load: false)
    let sameMossNanoInstance = (synthesis as AnyObject) === (mossNano as AnyObject)
    #expect(sameMossNanoInstance)
    if case .available = await synthesis.availability {
        Issue.record("Missing MossNano resources must not resolve to system speech")
    }
    await #expect(throws: (any Error).self) { try await manager.load(.synthesis) }
    #expect(try await manager.status(.synthesis) == .unloaded)
    #expect(try await manager.status(ModelKitDefaults.mossNano) == .unloaded)
    #expect(try await manager.status(.chat) == .registered)
    await #expect(throws: ModelRegistrationError.missingDefault(.judge)) { _ = try await manager.get(.judge) }
    await manager.shutdown()
    let closed = try await ModelKitDefaults.manager(resources: missing)
    let sameManager = closed === manager
    #expect(sameManager)
    await #expect(throws: CapabilityError.sessionClosed) { _ = try await closed.get(.synthesis) }
}

private final class TestBundleAnchor: NSObject {}
