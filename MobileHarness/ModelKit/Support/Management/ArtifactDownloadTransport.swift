import Foundation
import Synchronization

/// Persists OS task identity in taskDescription; completion files survive relaunch before a waiter reattaches.
final class ArtifactDownloadTransport: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var received: Int64 = 0
        var session: URLSession?
        var waiters: [Int: CheckedContinuation<URL, Error>] = [:]
        var results: [Int: Result<URL, Error>] = [:]
    }
    private let state = Mutex(State())
    private let onProgress: @Sendable () -> Void
    private let identifier: String
    init(identifier: String, allowsCellular: Bool, onProgress: @escaping @Sendable () -> Void = {}) {
        self.onProgress = onProgress
        self.identifier = identifier
        super.init()
        #if os(iOS)
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
        #else
            let configuration = URLSessionConfiguration.default
        #endif
        configuration.allowsCellularAccess = allowsCellular
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
    }
    var receivedBytes: Int64 { state.withLock { $0.received } }
    func resetProgress() { state.withLock { $0.received = 0 } }
    func finishTransfers() { state.withLock { $0.session }?.finishTasksAndInvalidate() }
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let session = state.withLock({ $0.session }) else { throw ModelArtifactError.storage }
        let descriptor = destination.absoluteString + "\n" + String(maximumBytes)
        let existing = await session.allTasks
        let task =
            existing.first { $0.taskDescription == descriptor && $0.originalRequest?.url == url }
            as? URLSessionDownloadTask
            ?? session.downloadTask(with: url)
        task.taskDescription = descriptor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { value -> Result<URL, Error>? in
                    if let result = value.results.removeValue(forKey: task.taskIdentifier) { return result }
                    value.waiters[task.taskIdentifier] = continuation
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }
    private func finish(_ task: URLSessionTask, _ result: Result<URL, Error>) {
        let waiter = state.withLock { value in
            let waiter = value.waiters.removeValue(forKey: task.taskIdentifier)
            if waiter == nil, value.results.count < 2 { value.results[task.taskIdentifier] = result }
            return waiter
        }
        waiter?.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                response.url?.scheme == "https", let descriptor = downloadTask.taskDescription
            else {
                throw ModelArtifactError.integrity
            }
            let fields = descriptor.split(separator: "\n")
            guard fields.count == 2, let destination = URL(string: String(fields[0])), destination.isFileURL,
                let expected = Int64(fields[1]), expected >= 0,
                destination.lastPathComponent.hasPrefix(".incoming-"),
                destination.path.contains("/staging/"),
                let actual = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?
                    .int64Value,
                actual <= expected
            else { throw ModelArtifactError.integrity }
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: location, to: destination)
            }
            finish(downloadTask, .success(destination))
        } catch { finish(downloadTask, .failure(error)) }
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        state.withLock { $0.received = totalBytesWritten }
        onProgress()
        guard let limit = downloadTask.taskDescription?.split(separator: "\n").last.flatMap({ Int64($0) }) else {
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, .failure(error)) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        ModelArtifactBackgroundEvents.finished(identifier)
    }
}

public enum ModelArtifactBackgroundEvents {
    private static let handlers = Mutex<[String: @Sendable () -> Void]>([:])
    public static func register(_ identifier: String, completion: @escaping @Sendable () -> Void) {
        let previous = handlers.withLock { $0.updateValue(completion, forKey: identifier) }
        previous?()
    }
    public static func finished(_ identifier: String) {
        handlers.withLock { $0.removeValue(forKey: identifier) }?()
    }
}
