import Foundation
import Synchronization

/// Persists OS task identity in taskDescription; completion files survive relaunch before a waiter reattaches.
final class ArtifactDownloadTransport: NSObject, URLSessionDownloadDelegate, Sendable {
    struct ResumeRecord: Codable {
        let url: URL
        let maximumBytes: Int64
        let data: Data
    }
    private struct State {
        var invalidated = false
        var invalidationWaiter: CheckedContinuation<Void, Never>?
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
    func cancelAndJoin() async {
        guard let session = state.withLock({ $0.session }) else { return }
        session.invalidateAndCancel()
        await withCheckedContinuation { continuation in
            let done = state.withLock { value in
                if value.invalidated { return true }
                value.invalidationWaiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let waiter = state.withLock { value in
            value.invalidated = true
            let waiter = value.invalidationWaiter
            value.invalidationWaiter = nil
            value.session = nil
            return waiter
        }
        waiter?.resume()
    }
    var receivedBytes: Int64 { state.withLock { $0.received } }
    func resetProgress() { state.withLock { $0.received = 0 } }
    func finishTransfers() { state.withLock { $0.session }?.finishTasksAndInvalidate() }
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let session = state.withLock({ $0.session }) else { throw ModelArtifactError.storage }
        let descriptor = destination.absoluteString + "\n" + String(maximumBytes)
        let existing = await session.allTasks
        let task: URLSessionDownloadTask
        if let restored = existing.first(where: {
            $0.taskDescription == descriptor && $0.originalRequest?.url == url
                && ($0.state == .running || $0.state == .suspended)
        }) as? URLSessionDownloadTask {
            task = restored
        } else if let data = try Self.resumeData(for: url, destination: destination, maximumBytes: maximumBytes) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
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
            guard let response = downloadTask.response as? HTTPURLResponse,
                response.statusCode == 200 || response.statusCode == 206,
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
            let resume = destination.appendingPathExtension("resume")
            if FileManager.default.fileExists(atPath: resume.path) { try FileManager.default.removeItem(at: resume) }
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
        guard let error else { return }
        do {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                data.count <= 8 * 1024 * 1024, let url = task.originalRequest?.url,
                let fields = task.taskDescription?.split(separator: "\n"), fields.count == 2,
                let destination = URL(string: String(fields[0])), destination.isFileURL,
                let maximum = Int64(fields[1])
            {
                let record = ResumeRecord(url: url, maximumBytes: maximum, data: data)
                let encoded = try JSONEncoder().encode(record)
                #if os(iOS)
                    try encoded.write(
                        to: destination.appendingPathExtension("resume"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                    try encoded.write(to: destination.appendingPathExtension("resume"), options: .atomic)
                #endif
            }
            finish(task, .failure(error))
        } catch { finish(task, .failure(error)) }
    }
    static func resumeData(for url: URL, destination: URL, maximumBytes: Int64) throws -> Data? {
        let file = destination.appendingPathExtension("resume")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard file.resolvingSymlinksInPath() == file else { throw ModelArtifactError.storage }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 12 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 12 * 1024 * 1024 else { throw ModelArtifactError.integrity }
        let record = try JSONDecoder().decode(ResumeRecord.self, from: data)
        guard record.url == url, record.maximumBytes == maximumBytes else {
            try FileManager.default.removeItem(at: file)
            return nil
        }
        guard record.data.count <= 8 * 1024 * 1024 else { throw ModelArtifactError.integrity }
        try FileManager.default.removeItem(at: file)
        return record.data
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
