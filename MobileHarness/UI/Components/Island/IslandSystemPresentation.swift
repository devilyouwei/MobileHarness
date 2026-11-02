import Foundation

public enum IslandSystemStatus: String, Sendable {
    case unsupported, idle, pending, active, disabled, dismissed, failed, ended
}

@MainActor protocol IslandSystemDriving: AnyObject {
    var onStatus: (@MainActor (UUID, IslandSystemStatus) -> Void)? { get set }
    func apply(_ snapshot: IslandSystemSnapshot?) async throws -> IslandSystemStatus
}

/// One in-flight native request and one replaceable latest value; no replay queue.
@MainActor final class IslandSystemPresentation {
    private let driver: any IslandSystemDriving
    private let report: @MainActor (IslandSystemStatus, String?) -> Void
    private var desired: IslandSystemSnapshot?
    private var serial: UInt64 = 0
    private var applied: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var closed = false

    init(driver: any IslandSystemDriving, report: @escaping @MainActor (IslandSystemStatus, String?) -> Void) {
        self.driver = driver
        self.report = report
        driver.onStatus = { [weak self] id, status in
            guard let self, self.desired?.activityID == id else { return }
            if status == .dismissed { self.cancelHeartbeat() }
            self.report(status, nil)
        }
    }
    func submit(_ snapshot: IslandSystemSnapshot?, refresh: Bool = false) {
        guard !closed else { return }
        if !refresh, var comparable = snapshot, let desired {
            comparable.updatedAt = desired.updatedAt
            if comparable == desired { return }
        }
        guard desired != snapshot || refresh else { return }
        desired = snapshot
        serial &+= 1
        report(.pending, nil)
        if snapshot == nil || snapshot?.paused == true {
            heartbeat?.cancel()
            heartbeat = nil
        } else if heartbeat == nil {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, var next = self.desired else { return }
                    next.updatedAt = Date()
                    self.submit(next, refresh: true)
                }
            }
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        while applied != serial {
            let ticket = serial
            let value = desired
            do {
                _ = try value?.validatedPayload()
                let status = try await driver.apply(value)
                if ticket == serial {
                    if status == .disabled || status == .dismissed { cancelHeartbeat() }
                    report(status, nil)
                }
            } catch {
                if ticket == serial {
                    cancelHeartbeat()
                    report(.failed, String(error.localizedDescription.prefix(240)))
                }
            }
            applied = ticket
        }
        worker = nil
    }
    private func cancelHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
    func flush() async { await worker?.value }
    func stop() async {
        let timer = heartbeat
        heartbeat?.cancel()
        heartbeat = nil
        submit(nil, refresh: true)
        closed = true
        await timer?.value
        await flush()
        driver.onStatus = nil
    }
}

extension IslandSystemSnapshot {
    init(activity: IslandActivity, status: IslandActivity? = nil, generation: UUID, now: Date) {
        let value = activity.content
        let indicators = status?.content ?? value
        self.init(
            generation: generation, activityID: activity.id, title: value.title, subtitle: value.subtitle,
            primary: indicators.primary, secondary: indicators.secondary, tone: indicators.tone.rawValue,
            startedAt: indicators.startedAt, deadline: indicators.deadline, updatedAt: now, endedAt: nil,
            attentionID: value.expansionID.map { generation.uuidString + ":" + activity.id.uuidString + ":" + $0 },
            detailText: value.detail?.text,
            detailPrimary: value.detail == nil ? nil : value.primary,
            detailTone: value.detail == nil ? nil : value.tone.rawValue,
            hasStatus: status != nil || value.detail == nil)
    }
}

/// One alert per stage, not per progress/heartbeat update. Bounded per root generation.
struct IslandAttentionLedger {
    private var generation: UUID?
    private var seen: Set<String> = []
    mutating func take(_ snapshot: IslandSystemSnapshot) throws -> Bool {
        if generation != snapshot.generation {
            generation = snapshot.generation
            seen.removeAll()
        }
        guard !snapshot.paused, let token = snapshot.attentionID, !seen.contains(token) else { return false }
        guard seen.count < 256 else { throw IslandError.capacity }
        seen.insert(token)
        return true
    }
}

/// Only for UIKit's synchronous process-exit callback, never for scene/background transitions.
/// The cleanup must not depend on the calling actor: UIKit exits as soon as its callback returns.
enum IslandTerminationCleanup {
    static func perform(timeout: TimeInterval = 1, cleanup: @escaping @Sendable () async -> Void) -> Bool {
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .high) {
            await cleanup()
            completion.signal()
        }
        let completed = completion.wait(timeout: .now() + timeout) == .success
        if !completed { task.cancel() }
        return completed
    }
}

#if os(iOS)
    // ActivityKit handles are not Sendable in the SDK; one main-actor driver serializes all writes.
    @preconcurrency import ActivityKit

    /// Best effort only: iOS may kill a suspended process without delivering a termination callback.
    public enum IslandProcessLifecycle {
        public static func endBeforeTermination() -> Bool {
            IslandTerminationCleanup.perform {
                for activity in Activity<IslandActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    /// ActivityKit owns system rendering; completion here means the native request completed.
    @MainActor final class IslandLiveActivityDriver: IslandSystemDriving {
        var onStatus: (@MainActor (UUID, IslandSystemStatus) -> Void)?
        private var activity: Activity<IslandActivityAttributes>?
        private var observation: Task<Void, Never>?
        private var snapshot: IslandSystemSnapshot?
        private var alerts = IslandAttentionLedger()
        private var prepared = false
        private var dismissedUntilIdle = false

        func apply(_ value: IslandSystemSnapshot?) async throws -> IslandSystemStatus {
            if !prepared {
                prepared = true
                for old in Activity<IslandActivityAttributes>.activities {
                    await old.end(nil, dismissalPolicy: .immediate)
                }
            }
            guard let value else {
                await finish()
                dismissedUntilIdle = false
                return .ended
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                await finish()
                return .disabled
            }
            if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
                dismissedUntilIdle = true
                await finish()
            }
            guard !dismissedUntilIdle else { return .dismissed }
            if let activity, activity.attributes.sessionID != value.generation { await finish() }
            let content = ActivityContent(state: value, staleDate: value.updatedAt.addingTimeInterval(60))
            var nextAlerts = alerts
            let needsAlert = try nextAlerts.take(value)
            let alert: AlertConfiguration? =
                needsAlert
                ? .init(title: "\(value.title)", body: "\(value.subtitle)", sound: .default) : nil
            if let activity {
                snapshot = value
                await activity.update(content, alertConfiguration: alert)
            } else {
                let next = try Activity.request(
                    attributes: IslandActivityAttributes(sessionID: value.generation), content: content, pushType: nil)
                activity = next
                snapshot = value
                if let alert { await next.update(content, alertConfiguration: alert) }
                observation = Task { [weak self] in
                    for await state in next.activityStateUpdates {
                        guard !Task.isCancelled, let self, self.activity?.id == next.id else { return }
                        if state == .dismissed || state == .ended {
                            self.dismissedUntilIdle = true
                            if let id = self.snapshot?.activityID { self.onStatus?(id, .dismissed) }
                        }
                    }
                }
            }
            alerts = nextAlerts
            return .active
        }
        private func finish() async {
            let old = activity
            activity = nil
            let task = observation
            observation = nil
            task?.cancel()
            await task?.value
            if let old { await old.end(nil, dismissalPolicy: .immediate) }
            snapshot = nil
        }
    }
#endif
