import Foundation
import Observation

@MainActor @Observable
public final class SpeechDiagnosticState {
    public var text = "你好，Hello world，欢迎使用本地语音助手。"
    public var report = "中英双语 · Core ML · MOSS Nano Beta · zh_1 / en_2"
    public var isRunning = false
    public var isStopping = false
    public init() {}
    public func presentRunning(_ value: Bool) { isRunning = value }
    public func presentStopping(_ value: Bool) { isStopping = value }
    public func presentReport(_ value: String) { report = value }
    public func appendReport(_ value: String) { report += value }

}

@MainActor
public protocol SpeechDiagnosticControlling: AnyObject {
    func start()
    func stop()
}
