import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import Testing

private actor InventoryFixture: ModelResourceInventoryCapability {
    var items: [ModelResourceFact] = []
    var fails = false
    var reads = 0
    func set(_ items: [ModelResourceFact]) { self.items = items }
    func failNext() { fails = true }
    func snapshotResources() async throws -> [ModelResourceFact] {
        reads += 1
        if fails {
            fails = false
            throw ResourceInventoryError.invalidSnapshot
        }
        return items
    }
}
@Test(.actionCatalog) func inventoryRefreshCrossesGatewaysAndFailureDoesNotBlockLaterRead() async throws {
    let fixture = InventoryFixture()
    await fixture.set([
        .init(id: "nemotron", name: "ASR", bytes: 100, completedBytes: 150, phase: .installed),
        .init(
            id: "moss-tts-nano", name: "TTS", bytes: 100, completedBytes: 42, phase: .downloading,
            failure: "network:fixture"),
    ])
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), inventory: fixture)
    let inventory = try ModelResourceInventory.decode(await runtime.inventory())
    #expect(inventory.items[0].progress == 1)
    #expect(inventory.items[1].progress == 0.42)
    #expect(inventory.items[1].active && inventory.items[1].failure == "network:fixture")
    #expect(inventory.installedGroups == [.recognition])
    await fixture.failNext()
    await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.inventory() }
    #expect(try ModelResourceInventory.decode(await runtime.inventory()).items == inventory.items)
    #expect(await fixture.reads == 3)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func inventoryRejectsDuplicateIDsOverflowAndNegativeFactsBeforeReturningPartialState()
    async throws
{
    let fixture = InventoryFixture()
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), inventory: fixture)
    let item = ModelResourceFact(id: "model", name: "Model", bytes: 10, phase: .notInstalled)
    await fixture.set([item, item])
    await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.inventory() }
    await fixture.set((0..<65).map { .init(id: "model\($0)", name: "Model", bytes: 10, phase: .installed) })
    await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.inventory() }
    await fixture.set([.init(id: "model", name: "Model", bytes: -1, phase: .failed)])
    await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.inventory() }
    await fixture.set([item])
    #expect(try ModelResourceInventory.decode(await runtime.inventory()).items == [item])
    await runtime.shutdown()
}
@Test(.actionCatalog) func installedGroupsShareActualPrerequisitesAndIgnoreOptionalVAD() throws {
    #expect(ResourceModelGroup.recognition.isInstalled(in: ["nemotron"]))
    #expect(!ResourceModelGroup.recognition.isInstalled(in: ["silero"]))
    let inventory = ModelResourceInventory(items: [.init(id: "moss-tts-nano", name: "TTS", bytes: 10, phase: .deleting)]
    )
    #expect(inventory.installedGroups.isEmpty)
    #expect(try ModelResourceInventory.decode(inventory.encoded()).installedGroups.isEmpty)
}
@Test(.actionCatalog) func inventoryEnforcesEncodedByteCapacityInAdditionToItemBound() throws {
    let inventory = ModelResourceInventory(
        items: (0..<64).map {
            .init(
                id: "model\($0)", name: String(repeating: "a", count: 256),
                revision: String(repeating: "b", count: 512),
                license: String(repeating: "c", count: 512), bytes: 1, phase: .failed,
                failure: String(repeating: "d", count: 1024))
        })
    #expect(throws: ResourceInventoryError.capacityExceeded) { try inventory.encoded() }
}

@Test(.actionCatalog) func largeInventoryReturnsIntactAndByteOverflowDoesNotBlockLaterRead() async throws {
    let fixture = InventoryFixture()
    let items: [ModelResourceFact] = (0..<22).map {
        .init(
            id: "model\($0)", name: String(repeating: "a", count: 256),
            revision: String(repeating: "b", count: 512),
            license: String(repeating: "c", count: 512), bytes: 100, completedBytes: 42,
            phase: .failed, failure: String(repeating: "d", count: 1024))
    }
    let expected = ModelResourceInventory(items: items)
    #expect(try expected.encoded().utf8.count > 48 * 1024)
    await fixture.set(items)
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), inventory: fixture)
    #expect(try ModelResourceInventory.decode(await runtime.inventory()) == expected)
    let oversized = (0..<32).map { index in
        ModelResourceFact(
            id: "overflow\(index)", name: items[0].name, revision: items[0].revision,
            license: items[0].license, bytes: 100, phase: .failed, failure: items[0].failure)
    }
    await fixture.set(oversized)
    await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.inventory() }
    await fixture.set(items)
    #expect(try ModelResourceInventory.decode(await runtime.inventory()) == expected)
    #expect(await fixture.reads == 3)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
