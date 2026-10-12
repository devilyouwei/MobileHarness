import Foundation
import ModelKitRuntime
import Synchronization

/// A persisted file plan and at most three OS transfers. Delegate callbacks schedule successors
/// before returning, so advancement never depends on a foreground Swift task or page lifetime.
final class HubBackgroundTransfer: NSObject, URLSessionDownloadDelegate, Sendable {
    struct Member: Codable, Sendable, Equatable {
        let path: String
        let url: URL
        let bytes: Int64
    }
    struct Plan: Codable, Sendable {
        let id: String
        let revision: String
        let endpoint: String
        let members: [Member]
    }
    private struct State {
        var session: URLSession?
        var active: [Int: Int] = [:]
        var done: Set<Int> = []
        var received: [Int: Int64] = [:]
        var retries: [Int: Int] = [:]
        var waiter: CheckedContinuation<Void, Error>?
        var failure: (any Error)?
        var armed = false
        var cancelled = false
    }
    private let state = Mutex(State())
    private let root: URL
    private let plan: Plan
    private let identifier: String
    private let report: @Sendable (Double) -> Void
    init(root: URL, plan: Plan, allowsCellular: Bool, progress: @escaping @Sendable (Double) -> Void) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.plan = plan
        self.report = progress
        identifier = "dev.mobileharness.artifacts.hub." + root.lastPathComponent
        super.init()
        guard !plan.members.isEmpty, plan.members.count <= 16384,
            Set(plan.members.map(\.path)).count == plan.members.count,
            plan.members.allSatisfy({
                ModelArtifactCatalog.validInstalledPath($0.path) && $0.url.scheme == "https" && $0.bytes >= 0
                    && $0.bytes <= 32 * 1024 * 1024 * 1024
                    && !$0.path.hasPrefix(".hub-") && $0.path != ".installation.json"
            })
        else { throw ModelArtifactError.invalidCatalog }
        var total: Int64 = 0
        for member in plan.members {
            guard total <= 32 * 1024 * 1024 * 1024 - member.bytes else { throw ModelArtifactError.invalidCatalog }
            total += member.bytes
        }
        #if os(iOS)
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
        #else
            let configuration = URLSessionConfiguration.default
        #endif
        configuration.allowsCellularAccess = allowsCellular
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 86400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
    }
    private func descriptor(_ index: Int) -> String {
        "\(index)\n\(plan.members[index].path)\n\(plan.members[index].url.absoluteString)"
    }
    private func memberIndex(_ description: String) -> Int? {
        guard let first = description.split(separator: "\n").first, let index = Int(first),
            plan.members.indices.contains(index), descriptor(index) == description
        else { return nil }
        return index
    }
    private func destination(_ index: Int) -> URL { root.appendingPathComponent(plan.members[index].path) }
    private func resumeFile(_ index: Int) -> URL { root.appendingPathComponent(".hub-resume/\(index)") }
    static func isComplete(_ url: URL, bytes: Int64) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
            && values?.fileSize.map(Int64.init) == bytes
    }
    func run() async throws {
        guard let session = state.withLock({ $0.session }) else { throw ModelArtifactError.storage }
        let tasks = await session.allTasks
        var completed: Set<Int> = []
        for i in plan.members.indices where Self.isComplete(destination(i), bytes: plan.members[i].bytes) {
            completed.insert(i)
        }
        state.withLock { value in
            value.done.formUnion(completed)
            for task in tasks {
                guard let description = task.taskDescription, let index = memberIndex(description),
                    plan.members.indices.contains(index), task.originalRequest?.url == plan.members[index].url,
                    !value.done.contains(index), !value.active.values.contains(index),
                    task.state == .running || task.state == .suspended
                else {
                    task.cancel()
                    continue
                }
                value.active[task.taskIdentifier] = index
                value.received[index] = max(0, task.countOfBytesReceived)
                task.resume()
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock {
                    $0.waiter = continuation
                    $0.armed = true
                }
                if Task.isCancelled { cancel() } else { pump() }
            }
        } onCancel: {
            self.cancel()
        }
        session.finishTasksAndInvalidate()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".hub-resume"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".hub-plan.json"))
    }
    private func pump() {
        let result = state.withLock { value -> (CheckedContinuation<Void, Error>?, (any Error)?, Double) in
            guard value.armed, let session = value.session else { return (nil, nil, 0) }
            if value.failure == nil && !value.cancelled {
                // Large files first; up to three active and a bounded persisted FIFO remainder.
                for index in plan.members.indices.sorted(by: { plan.members[$0].bytes > plan.members[$1].bytes }) {
                    if value.active.count >= 3 { break }
                    guard !value.done.contains(index), !value.active.values.contains(index) else { continue }
                    let resume = try? Data(contentsOf: resumeFile(index))
                    let task: URLSessionDownloadTask
                    if let resume, resume.count <= 8 * 1024 * 1024 {
                        task = session.downloadTask(withResumeData: resume)
                        try? FileManager.default.removeItem(at: resumeFile(index))
                    } else {
                        task = session.downloadTask(with: plan.members[index].url)
                    }
                    task.taskDescription = descriptor(index)
                    value.active[task.taskIdentifier] = index
                    task.resume()
                }
            }
            let total = plan.members.reduce(0.0) { $0 + Double(max(1, $1.bytes)) }
            let bytes = plan.members.indices.reduce(0.0) { partial, index in
                partial
                    + (value.done.contains(index)
                        ? Double(max(1, plan.members[index].bytes))
                        : Double(min(plan.members[index].bytes, value.received[index] ?? 0)))
            }
            let finished =
                value.active.isEmpty
                && (value.failure != nil || value.cancelled || value.done.count == plan.members.count)
            let waiter = finished ? value.waiter : nil
            if finished { value.waiter = nil }
            return (waiter, value.cancelled ? CancellationError() : value.failure, min(1, bytes / total))
        }
        report(result.2)
        if let waiter = result.0 {
            if let error = result.1 {
                state.withLock { $0.session }?.finishTasksAndInvalidate()
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
    private func cancel() {
        let session = state.withLock { value in
            value.cancelled = true
            return value.session
        }
        session?.getAllTasks { tasks in
            for task in tasks { task.cancel() }
            self.pump()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = downloadTask.taskDescription.flatMap(memberIndex), plan.members.indices.contains(index) else {
            downloadTask.cancel()
            return
        }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                response.url?.scheme == "https", Self.isComplete(location, bytes: plan.members[index].bytes)
            else { throw ModelArtifactError.integrity }
            let target = destination(index)
            guard target.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw ModelArtifactError.integrity
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: location.path)
            #endif
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            state.withLock {
                $0.done.insert(index)
                $0.received[index] = nil
            }
        } catch {
            state.withLock { $0.failure = error }
        }
        // Only didCompleteWithError retires a task, including successful tasks.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = task.taskDescription.flatMap(memberIndex), plan.members.indices.contains(index) else {
            return
        }
        if let error, let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
            resume.count <= 8 * 1024 * 1024
        {
            do {
                try FileManager.default.createDirectory(
                    at: resumeFile(index).deletingLastPathComponent(), withIntermediateDirectories: true)
                try resume.write(to: resumeFile(index), options: .atomic)
            } catch { state.withLock { $0.failure = error } }
        }
        state.withLock { value in
            value.active[task.taskIdentifier] = nil
            if let error, !value.cancelled {
                let code = (error as NSError).code
                let retryable =
                    (error as NSError).domain == NSURLErrorDomain && [-1001, -1005, -1009, -1004, -1003].contains(code)
                if retryable && value.retries[index, default: 0] < 3 {
                    value.retries[index, default: 0] += 1
                } else {
                    value.failure = error
                }
            }
        }
        pump()
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let index = downloadTask.taskDescription.flatMap(memberIndex), plan.members.indices.contains(index) else {
            downloadTask.cancel()
            return
        }
        guard totalBytesWritten <= plan.members[index].bytes, totalBytesExpectedToWrite <= plan.members[index].bytes
        else {
            downloadTask.cancel()
            return
        }
        let fraction = state.withLock { value -> Double in
            value.received[index] = totalBytesWritten
            let total = plan.members.reduce(0.0) { $0 + Double(max(1, $1.bytes)) }
            return plan.members.indices.reduce(0.0) {
                $0
                    + (value.done.contains($1)
                        ? Double(max(1, plan.members[$1].bytes)) : Double(value.received[$1] ?? 0))
            } / total
        }
        report(min(1, fraction))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        ModelArtifactBackgroundEvents.finished(identifier)
    }
}
