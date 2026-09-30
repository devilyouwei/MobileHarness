import Foundation

public enum StorageError: Error, Equatable, Sendable {
    case capacityExceeded, missing, timedOut, duplicate, closed, expired, forbidden
}

/// Single-producer/single-consumer process-local stream with explicit byte and item limits.
public actor BoundedMemoryStream<Element: Sendable> {
    private let maximumBytes: Int
    private let maximumItems: Int
    private let waitTimeout: Duration?
    private let size: @Sendable (Element) -> Int
    private var items: [Element] = []
    private var bytes = 0
    private var finished = false
    private var failure: (any Error)?
    private var readerID: UUID?
    private var reader: CheckedContinuation<Element?, Error>?

    public init(
        maximumBytes: Int, maximumItems: Int, waitTimeout: Duration?,
        size: @escaping @Sendable (Element) -> Int
    ) {
        precondition(maximumBytes > 0 && maximumItems > 0)
        precondition(waitTimeout.map { $0 > .zero } ?? true)
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
        self.waitTimeout = waitTimeout
        self.size = size
    }

    public var bufferedBytes: Int { bytes }

    public func append(_ item: Element) throws {
        try check()
        guard !finished else { throw StorageError.closed }
        let count = size(item)
        guard count > 0, count <= maximumBytes - bytes, items.count < maximumItems else {
            throw StorageError.capacityExceeded
        }
        if let reader {
            self.reader = nil
            readerID = nil
            reader.resume(returning: item)
        } else {
            items.append(item)
            bytes += count
        }
    }

    public func next() async throws -> Element? {
        try check()
        if !items.isEmpty {
            let item = items.removeFirst()
            bytes -= size(item)
            return item
        }
        if finished { return nil }
        guard reader == nil else { throw StorageError.duplicate }
        let id = UUID()
        readerID = id
        let deadline = waitTimeout.map { timeout in
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if self.readerID == id, self.reader != nil { self.fail(StorageError.timedOut) }
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try check()
            return try await withCheckedThrowingContinuation { reader = $0 }
        } onCancel: {
            Task { await self.fail(CancellationError()) }
        }
    }

    public func finish() {
        guard failure == nil else { return }
        finished = true
        let pending = reader
        reader = nil
        readerID = nil
        pending?.resume(returning: nil)
    }

    public func cancel() { fail(CancellationError()) }

    public func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        items.removeAll()
        bytes = 0
        let reading = reader
        reader = nil
        readerID = nil
        reading?.resume(throwing: error)
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
    }
}
