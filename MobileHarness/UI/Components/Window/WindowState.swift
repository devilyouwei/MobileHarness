import Foundation
import Observation

public enum WindowSizing: Sendable, Equatable {
    case standard
    case image(aspect: Double, controlsHeight: Double)
    func initial(width: Double, height: Double) -> WindowGeometry {
        guard case .image(let aspect, let controls) = self, aspect.isFinite, aspect > 0 else {
            return .initial(width: width, height: height)
        }
        let chrome = 52 + controls
        let topInset = height > width ? min(80, max(0, height - chrome - 1)) : 0
        let w = max(1, min(width - 32, max(1, height - topInset - chrome) * aspect))
        let h = w / aspect + chrome
        return .init(x: (width - w) / 2, y: max(topInset, (height - h) / 2), width: w, height: h)
    }
}

public enum WindowMode: String, Sendable { case normal, minimized, maximized }
public enum WindowPhase: String, Sendable { case opening, settled, changing, closing }
public enum WindowError: String, Error, Sendable, LocalizedError {
    case unavailable, capacity, missing, invalidPosition, invalidIcon, interrupted, busy
}

public struct WindowGeometry: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    /// Screen-edge shell expressed in the same safe-area-relative coordinates as normal windows.
    static func maximized(viewport: CGRect, safe: CGRect, topBoundary: Double?) -> Self {
        let top = min(viewport.maxY - 1, max(viewport.minY, topBoundary.map { $0 + 4 } ?? safe.minY))
        return .init(
            x: viewport.minX - safe.minX, y: top - safe.minY,
            width: max(1, viewport.width), height: max(1, viewport.maxY - top))
    }
    public static func initial(width: Double, height: Double) -> Self {
        .init(x: 16, y: height / 6, width: max(1, width - 32), height: height * 2 / 3)
    }
    public func constrained(width: Double, height: Double, card: Bool) -> Self {
        var value = self
        value.x = min(max(x, 0), max(0, width - self.width))
        value.y = min(max(y, 0), max(0, height - (card ? self.height : 52)))
        return value
    }
}

public struct WindowPresentation: Identifiable, Sendable {
    public let id: UUID
    public let content: String
    public let title: String
    public let icon: WindowIcon?
    public let color: Int
    public var sizing: WindowSizing = .standard
    public var mode: WindowMode = .normal
    public var restoreMode: WindowMode = .normal
    public var phase: WindowPhase = .opening
    public var normal: WindowGeometry
    public var card: WindowGeometry
    public var revision: UInt64 = 1
    public var presentedRevision: UInt64 = 0
    public var presentationConfirmed: Bool { phase == .settled && presentedRevision == revision }
    public var activity: String?
    public var failure: String?
    public var prompt: WindowPrompt?
}

/// One root-owned presentation state. Business lifecycle is supplied by Actions, never owned here.
@Observable @MainActor public final class WindowState {
    public private(set) var windows: [WindowPresentation] = []
    public private(set) var focusedID: UUID?
    public private(set) var generation = UUID()
    public private(set) var available = false
    /// Retained home windows may be covered by navigation without ending their lifetime.
    public internal(set) var isHostVisible = true
    public private(set) var width: Double = 0
    public private(set) var height: Double = 0
    public private(set) var maximizedFrame: WindowGeometry?
    public private(set) var cardTitleSize = WindowCardLayout.defaultTitleSize
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    public let requests = UIRequests<WindowInput, Void>()
    @ObservationIgnored private var inputs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inputTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var prompts:
        [UUID: (token: UUID, continuation: CheckedContinuation<String, any Error>)] = [:]
    @ObservationIgnored private var stopped = false
    public init() {}
    public func setAvailable(_ value: Bool) {
        guard !stopped else { return }
        available = value
        requests.setAvailable(value)
        if !value {
            generation = UUID()
            for task in inputs.values { task.cancel() }
            for prompt in prompts.values { prompt.continuation.resume(throwing: WindowError.unavailable) }
            prompts.removeAll()
            for i in windows.indices {
                windows[i].phase = .settled
                windows[i].prompt = nil
                windows[i].revision += 1
            }
            for waiter in waiters.values { waiter.resume(throwing: WindowError.unavailable) }
            waiters.removeAll()
        }
    }
    public func stop() async {
        setAvailable(false)
        stopped = true
        requests.stop()
        let current = Array(inputs.values)
        for task in current { await task.value }
        windows.removeAll()
        focusedID = nil
    }
    public func layout(width: Double, height: Double, maximized: WindowGeometry? = nil, titleSize: Double? = nil) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        if let titleSize, titleSize.isFinite, titleSize > 0 { cardTitleSize = titleSize }
        let first = self.width == 0
        self.width = width
        self.height = height
        maximizedFrame = maximized
        for i in windows.indices {
            let cardWidth = WindowCardLayout.width(title: windows[i].title, viewport: width, fontSize: cardTitleSize)
            if first {
                windows[i].normal = windows[i].sizing.initial(width: width, height: height)
                windows[i].card = .init(
                    x: max(0, width - cardWidth - 16), y: max(0, height - 64 - Double(i) * 56),
                    width: cardWidth, height: 48)
            } else {
                windows[i].card.x += (windows[i].card.width - cardWidth) / 2
                windows[i].card.width = cardWidth
            }
            let desired = windows[i].sizing.initial(width: width, height: height)
            windows[i].normal.width = desired.width
            windows[i].normal.height = desired.height
            windows[i].normal = windows[i].normal.constrained(width: width, height: height, card: false)
            windows[i].card = windows[i].card.constrained(width: width, height: height, card: true)
        }
    }
    public func resizeContent(_ id: UUID, sizing: WindowSizing) {
        guard let i = windows.firstIndex(where: { $0.id == id }), windows[i].sizing != sizing else { return }
        windows[i].sizing = sizing
        let old = windows[i].normal
        var frame = sizing.initial(width: width, height: height)
        frame.x = old.x + (old.width - frame.width) / 2
        frame.y = old.y + (old.height - frame.height) / 2
        windows[i].normal = frame.constrained(width: width, height: height, card: false)
    }
    public func frame(_ item: WindowPresentation) -> WindowGeometry {
        switch item.mode {
        case .normal: item.normal
        case .minimized: item.card
        case .maximized: maximizedFrame ?? .init(x: 0, y: 0, width: width, height: height)
        }
    }
    public func isCovered(_ id: UUID) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return true }
        return !hasVisibleArea(frame(windows[index]), above: index)
    }
    public func hasVisibleContent(_ id: UUID, topInset: Double, bottomInset: Double) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        var content = frame(windows[index])
        content.y += topInset
        content.height = max(0, content.height - topInset - bottomInset)
        return hasVisibleArea(content, above: index)
    }
    public func hasVisibleBackground() -> Bool {
        hasVisibleArea(.init(x: 0, y: 0, width: width, height: height), above: -1)
    }
    private func hasVisibleArea(_ target: WindowGeometry, above index: Int) -> Bool {
        guard isHostVisible else { return false }
        let safe = CGRect(x: 0, y: 0, width: width, height: height)
        var remaining = [
            CGRect(x: target.x, y: target.y, width: target.width, height: target.height).intersection(safe)
        ]
        for item in windows.suffix(from: index + 1) where item.phase == .settled {
            let f = frame(item)
            let cover = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
            remaining = remaining.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(cover)
                guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
                ].filter { !$0.isEmpty && !$0.isNull }
            }
        }
        return remaining.contains { !$0.isEmpty && !$0.isNull }
    }
    public func find(_ id: UUID) throws -> WindowPresentation {
        guard let item = windows.first(where: { $0.id == id }) else { throw WindowError.missing }
        return item
    }
    public func present(
        content: WindowContent, title: String, icon: WindowIcon? = nil, sizing: WindowSizing = .standard
    ) async throws -> UUID {
        guard available else { throw WindowError.unavailable }
        if content.singleInstance, let item = windows.first(where: { $0.content == content.rawValue }) {
            guard item.phase == .settled else { throw WindowError.busy }
            if item.mode == .minimized { try await change(item.id, command: .restore) }
            try focus(item.id)
            return item.id
        }
        guard windows.count < 4 else { throw WindowError.capacity }
        let icon = try icon?.prepared()
        let cardWidth = WindowCardLayout.width(title: title, viewport: width, fontSize: cardTitleSize)
        let id = UUID()
        windows.append(
            .init(
                id: id, content: content.rawValue, title: title, icon: icon, color: Int.random(in: 0..<6),
                sizing: sizing,
                normal: sizing.initial(width: width, height: height),
                card: .init(
                    x: max(0, width - cardWidth - 16), y: max(0, height - 64 - Double(windows.count) * 56),
                    width: cardWidth, height: 48)
            ))
        focusedID = id
        try await wait(id)
        return id
    }
    public func focus(_ id: UUID) throws {
        guard available else { throw WindowError.unavailable }
        guard let index = windows.firstIndex(where: { $0.id == id }) else { throw WindowError.missing }
        let item = windows.remove(at: index)
        windows.append(item)
        focusedID = id
    }
    public func setActivity(_ id: UUID, label: String?) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[i].activity = label.map { String($0.prefix(64)) }
    }
    public func move(_ id: UUID, x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw WindowError.invalidPosition }
        try focus(id)
        guard let i = windows.firstIndex(where: { $0.id == id }), windows[i].mode != .maximized else { return }
        var frame = frame(windows[i])
        frame.x = x
        frame.y = y
        frame = frame.constrained(width: width, height: height, card: windows[i].mode == .minimized)
        if windows[i].mode == .minimized { windows[i].card = frame } else { windows[i].normal = frame }
    }
    public func position(_ id: UUID, x: Double, y: Double) async throws {
        try move(id, x: x, y: y)
        guard let i = windows.firstIndex(where: { $0.id == id }) else { throw WindowError.missing }
        waiters.removeValue(forKey: id)?.resume(throwing: WindowError.interrupted)
        windows[i].revision += 1
        windows[i].phase = .changing
        try await wait(id)
    }
    public func drag(_ id: UUID, x: Double, y: Double) throws {
        let before = try find(id)
        guard before.phase == .settled, before.mode != .maximized else { return }
        try move(id, x: x, y: y)
    }
    public func endDrag(_ id: UUID) {
        guard let i = windows.firstIndex(where: { $0.id == id }), windows[i].mode == .normal else { return }
        let corrected = windows[i].normal.constrained(width: width, height: height, card: false)
        guard corrected != windows[i].normal else { return }
        windows[i].normal = corrected
        windows[i].revision += 1
        windows[i].phase = .changing
    }
    public func change(_ id: UUID, command: WindowCommand) async throws {
        try focus(id)
        guard let i = windows.firstIndex(where: { $0.id == id }) else { throw WindowError.missing }
        if command == .minimize, windows[i].mode == .minimized, windows[i].phase == .settled { return }
        waiters.removeValue(forKey: id)?.resume(throwing: WindowError.interrupted)
        windows[i].revision += 1
        switch command {
        case .minimize:
            if windows[i].mode != .minimized { windows[i].restoreMode = windows[i].mode }
            windows[i].mode = .minimized
        case .maximize: windows[i].mode = .maximized
        case .restore:
            windows[i].mode = windows[i].mode == .minimized ? windows[i].restoreMode : .normal
        case .close: windows[i].phase = .closing
        }
        if command != .close { windows[i].phase = .changing }
        try await wait(id)
    }
    private func wait(_ id: UUID) async throws {
        let revision = try find(id).revision
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let item = try? self.find(id), item.revision == revision else { return }
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
    public func submit(_ id: UUID, command: WindowCommand) {
        let previous = inputs[id]
        previous?.cancel()
        let token = UUID()
        inputTokens[id] = token
        inputs[id] = Task {
            defer {
                if inputTokens[id] == token {
                    inputs[id] = nil
                    inputTokens[id] = nil
                }
            }
            do {
                await previous?.value
                try Task.checkCancellation()
                if command == .close {
                    try await requests.submitControl(.init(id: id, command: command))
                } else {
                    try await requests.submit(.init(id: id, command: command))
                }
            } catch { if !(error is CancellationError) { report(id, message: error.localizedDescription) } }
        }
    }

    public func report(_ id: UUID, message: String?) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[i].failure = message
    }
    public func ask(_ id: UUID, prompt: WindowPrompt) async throws -> String {
        guard available else { throw WindowError.unavailable }
        guard let i = windows.firstIndex(where: { $0.id == id }) else { throw WindowError.missing }
        guard prompts[id] == nil else { throw WindowError.busy }
        let prompt = WindowPrompt(title: prompt.title, choices: prompt.choices)
        windows[i].prompt = prompt
        defer {
            if let i = windows.firstIndex(where: { $0.id == id }), windows[i].prompt?.id == prompt.id {
                windows[i].prompt = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    prompts[id] = (prompt.id, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.prompts[id]?.token == prompt.id else { return }
                self.prompts.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }
    public func answer(_ id: UUID, promptID: UUID, choice: String) {
        guard let item = try? find(id), item.prompt?.id == promptID, prompts[id]?.token == promptID,
            item.prompt?.choices.contains(where: { $0.id == choice }) == true
        else {
            return
        }
        prompts.removeValue(forKey: id)?.continuation.resume(returning: choice)
    }
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return .init(
            path: "ui.windows",
            business: [
                "focusedID": focusedID.map { .text($0.uuidString) } ?? .unknown,
                "windows": .array(
                    windows.map {
                        .object([
                            "windowID": .text($0.id.uuidString), "title": .text($0.title), "content": .text($0.content),
                            "mode": .text($0.mode.rawValue), "phase": .text($0.phase.rawValue),
                        ])
                    }),
            ], runtime: ["available": .flag(available)])
    }
    public func complete(_ id: UUID, revision: UInt64, generation: UUID, success: Bool) {
        guard self.generation == generation, let i = windows.firstIndex(where: { $0.id == id }),
            windows[i].revision == revision
        else { return }
        if success {
            if windows[i].phase == .closing {
                windows.remove(at: i)
                if focusedID == id { focusedID = windows.last?.id }
            } else {
                windows[i].phase = .settled
                windows[i].presentedRevision = revision
            }
            waiters.removeValue(forKey: id)?.resume()
        } else {
            windows[i].phase = .settled
            waiters.removeValue(forKey: id)?.resume(throwing: WindowError.interrupted)
        }
    }
}
public enum WindowCommand: String, Sendable { case minimize, maximize, restore, close }

public struct WindowContent: RawRepresentable, Sendable, Equatable {
    public let rawValue: String
    public let singleInstance: Bool
    public init(rawValue: String) { self.init(rawValue: rawValue, singleInstance: false) }
    public init(rawValue: String, singleInstance: Bool) {
        self.rawValue = rawValue
        self.singleInstance = singleInstance
    }
    public static let web = Self(rawValue: "web", singleInstance: true)
    public static let camera = Self(rawValue: "camera", singleInstance: true)
}
public struct WindowInput: Sendable {
    public let id: UUID
    public let command: WindowCommand
    public init(id: UUID, command: WindowCommand) {
        self.id = id
        self.command = command
    }
}
public struct WindowPrompt: Sendable {
    public let id = UUID()
    public struct Choice: Sendable, Identifiable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }
    public let title: String
    public let choices: [Choice]
    public init(title: String, choices: [Choice]) {
        self.title = title
        self.choices = choices
    }
}
