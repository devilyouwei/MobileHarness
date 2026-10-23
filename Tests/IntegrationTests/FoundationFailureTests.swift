import Agents
import AppStorage
import Foundation
import Gateway
import ModelKit
import ModelKitDefaults
import PlatformKit
import StorageCore
import Synchronization
import Testing
import UI

private protocol FailureSourceContract: Sendable {
    var fileID: String { get }
    var function: String { get }
    var line: UInt { get }
}
extension StorageFailure.Source: FailureSourceContract {}
extension PlatformFailure.Source: FailureSourceContract {}
extension ModelFailure.Source: FailureSourceContract {}
extension UIFailure.Source: FailureSourceContract {}

private protocol FailureEnvelopeContract: Error, CustomStringConvertible {
    associatedtype Code: RawRepresentable where Code.RawValue == String
    associatedtype Source: FailureSourceContract
    var code: Code { get }
    var component: String { get }
    var operation: String { get }
    var message: String { get }
    var underlying: any Error { get }
    var cleanupErrors: [any Error] { get }
    var source: Source { get }
    var isCancellation: Bool { get }
}
extension StorageFailure: FailureEnvelopeContract {}
extension PlatformFailure: FailureEnvelopeContract {}
extension ModelFailure: FailureEnvelopeContract {}
extension UIFailure: FailureEnvelopeContract {}

@Test func foundationFailureEnvelopesPreserveNativeIdentityAndShareFieldSemantics() throws {
    let native = NSError(domain: "native.fixture", code: 42, userInfo: ["detail": "original"])
    let cleanup = NSError(domain: "cleanup.fixture", code: 9)
    let failures: [any FailureEnvelopeContract] = [
        StorageFailure(
            component: "child", operation: "work", underlying: native, cleanupErrors: [cleanup], fileID: "fixture",
            function: "operation", line: 42),
        PlatformFailure(
            component: "child", operation: "work", underlying: native, cleanupErrors: [cleanup], fileID: "fixture",
            function: "operation", line: 42),
        ModelFailure(
            component: "child", operation: "work", underlying: native, cleanupErrors: [cleanup], fileID: "fixture",
            function: "operation", line: 42),
        UIFailure(
            component: "child", operation: "work", underlying: native, cleanupErrors: [cleanup], fileID: "fixture",
            function: "operation", line: 42),
    ]
    for failure in failures {
        #expect(failure.code.rawValue == "cleanup.failed")
        #expect(failure.component == "child")
        #expect(failure.operation == "work")
        #expect(failure.message == String(describing: native))
        #expect((failure.underlying as NSError) === native)
        #expect((try #require(failure.cleanupErrors.first) as NSError) === cleanup)
        #expect(failure.source.fileID == "fixture")
        #expect(failure.source.function == "operation")
        #expect(failure.source.line == 42)
        #expect(!failure.isCancellation)
        #expect(failure.description.contains("cleanup"))
        #expect(ApplicationContainer.failureDetails(failure)?.code == "cleanup.failed")
    }
}

@Test func foundationFailureRewrappingKeepsFirstSourceAndAllCleanupErrors() {
    let native = NSError(domain: "native.fixture", code: 42)
    let first = NSError(domain: "cleanup.fixture", code: 1)
    let second = NSError(domain: "cleanup.fixture", code: 2)
    let failures: [any FailureEnvelopeContract] = [
        StorageFailure(
            component: "outer", operation: "retry",
            underlying: StorageFailure(
                component: "origin", operation: "work", underlying: native, cleanupErrors: [first], fileID: "origin",
                function: "source", line: 10), cleanupErrors: [second]),
        PlatformFailure(
            component: "outer", operation: "retry",
            underlying: PlatformFailure(
                component: "origin", operation: "work", underlying: native, cleanupErrors: [first], fileID: "origin",
                function: "source", line: 10), cleanupErrors: [second]),
        ModelFailure(
            component: "outer", operation: "retry",
            underlying: ModelFailure(
                component: "origin", operation: "work", underlying: native, cleanupErrors: [first], fileID: "origin",
                function: "source", line: 10), cleanupErrors: [second]),
        UIFailure(
            component: "outer", operation: "retry",
            underlying: UIFailure(
                component: "origin", operation: "work", underlying: native, cleanupErrors: [first], fileID: "origin",
                function: "source", line: 10), cleanupErrors: [second]),
    ]
    for failure in failures {
        #expect(failure.component == "origin")
        #expect(failure.operation == "work")
        #expect(failure.source.fileID == "origin")
        #expect(failure.source.line == 10)
        #expect((failure.underlying as NSError) === native)
        #expect(failure.cleanupErrors.count == 2)
        #expect((failure.cleanupErrors[0] as NSError) === first)
        #expect((failure.cleanupErrors[1] as NSError) === second)
    }
}

@Test func foundationFailureCancellationClassificationNeverHidesCleanupFailure() async {
    let normal: [any FailureEnvelopeContract] = [
        StorageFailure(component: "root", operation: "stop", underlying: CancellationError()),
        PlatformFailure(component: "root", operation: "stop", underlying: CancellationError()),
        ModelFailure(component: "root", operation: "stop", underlying: CancellationError()),
        UIFailure(component: "root", operation: "stop", underlying: CancellationError()),
    ]
    let cleanup = NSError(domain: "cleanup.fixture", code: 1)
    let failed: [any FailureEnvelopeContract] = [
        StorageFailure(component: "root", operation: "stop", underlying: CancellationError(), cleanupErrors: [cleanup]),
        PlatformFailure(
            component: "root", operation: "stop", underlying: CancellationError(), cleanupErrors: [cleanup]),
        ModelFailure(component: "root", operation: "stop", underlying: CancellationError(), cleanupErrors: [cleanup]),
        UIFailure(component: "root", operation: "stop", underlying: CancellationError(), cleanupErrors: [cleanup]),
    ]
    let channel = ContainerFailureChannel()
    for failure in normal {
        #expect(failure.isCancellation)
        #expect(failure.code.rawValue == "cancelled")
        #expect(
            !channel.report(
                module: "fixture", component: "root", operation: "stop", error: failure,
                details: ApplicationContainer.failureDetails(failure)))
    }
    for failure in failed {
        #expect(!failure.isCancellation)
        #expect(failure.code.rawValue == "cleanup.failed")
        #expect(
            channel.report(
                module: "fixture", component: "root", operation: "stop", error: failure,
                details: ApplicationContainer.failureDetails(failure)))
    }
    #expect(channel.snapshot().records.contains { $0.delivery == .suppressed })
    #expect(channel.snapshot().records.contains { $0.delivery == .pending && $0.event.code == "cleanup.failed" })
    await channel.stop()
}

@Test func foundationFailureCodeSetsAndRootClassificationsAgree() {
    let expected = Set(StorageFailure.Code.allCases.map(\.rawValue))
    #expect(Set(PlatformFailure.Code.allCases.map(\.rawValue)) == expected)
    #expect(Set(ModelFailure.Code.allCases.map(\.rawValue)) == expected)
    #expect(Set(UIFailure.Code.allCases.map(\.rawValue)) == expected)
    #expect(StorageFailure(component: "root", operation: "start", underlying: StorageError.closed).code == .stopped)
    #expect(PlatformFailure(component: "root", operation: "start", underlying: PlatformError.stopped).code == .stopped)
    #expect(
        ModelFailure(component: "root", operation: "start", underlying: InferenceAdmissionError.stopped).code
            == .stopped)
    #expect(UIFailure(component: "root", operation: "start", underlying: UIContainerError.stopped).code == .stopped)
}

@Test func foundationFailureReportersPreserveCallerLocationAndWrappedBluetoothCondition() async {
    let channel = ContainerFailureChannel()
    let reporter = StorageFailureReporter(
        receive: channel.sink(module: "storage", details: ApplicationContainer.failureDetails))
    reporter.report("files", "read", StorageError.missing, fileID: "caller", function: "read", line: 73)
    let admission = PlatformAdmission(
        onFailure: channel.sink(module: "platform", details: ApplicationContainer.failureDetails))
    admission.report("connectivity.bluetooth", "connect", NexArmBluetoothError.unavailable)
    let records = channel.snapshot().records
    #expect((records[0].error as? StorageFailure)?.source.fileID == "caller")
    #expect((records[0].error as? StorageFailure)?.source.line == 73)
    #expect(records[0].event.code == "missing")
    #expect(records[1].error is PlatformFailure)
    #expect(records[1].event.code == "bluetooth.unavailable")
    #expect((records[1].error as? PlatformFailure)?.source.fileID.hasSuffix("FoundationFailureTests.swift") == true)
    await channel.stop()
}

@Test func foundationFailureSingleCleanupErrorIsNeverDemotedToConnectionStateOrCancellation() async {
    let channel = ContainerFailureChannel()
    let cancellation = StorageFailure(
        component: "root", operation: "stop", underlying: CancellationError(), code: .cleanupFailed)
    #expect(!cancellation.isCancellation)
    let native = PlatformFailure(
        component: "connectivity.bluetooth", operation: "stop", underlying: NexArmBluetoothError.unavailable,
        code: .cleanupFailed)
    #expect(
        channel.report(
            module: "platform", component: native.component, operation: native.operation, error: native,
            details: ApplicationContainer.failureDetails(native)))
    #expect(channel.snapshot().records.first?.event.code == "cleanup.failed")
    let lifecycle = PlatformFailure(
        component: "root", operation: "stop", underlying: PlatformError.unavailable, code: .cleanupFailed)
    #expect(
        channel.report(
            module: "platform", component: lifecycle.component, operation: lifecycle.operation, error: lifecycle,
            details: ApplicationContainer.failureDetails(lifecycle)))
    await channel.stop()
}
