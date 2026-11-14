import Actions

#if os(iOS)

    import UIKit
    import UI
    import OSLog
    import Agents
    import BackgroundTasks

    /// Native callbacks are forwarded to the registered domain handler without interpreting payloads.
    @MainActor final class ApplicationSystemDelegate: NSObject, UIApplicationDelegate {
        private let handler = ModelDownloadBackgroundService()
        func connect(prepare: @escaping @MainActor () async throws -> Void) { handler.connect(prepare: prepare) }
        func applicationWillTerminate(_ application: UIApplication) {
            if !IslandProcessLifecycle.endBeforeTermination() {
                Logger(subsystem: "dev.mobileharness.app", category: "termination")
                    .error("Live Activity cleanup did not complete before the termination deadline")
            }
        }
        func applicationDidEnterBackground(_ application: UIApplication) {
            handler.applicationDidEnterBackground(application)
        }
        func applicationWillEnterForeground(_ application: UIApplication) {
            handler.applicationWillEnterForeground(application)
        }
        func application(
            _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            handler.application(
                application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
        }
    }

    /// Owns the system allowance, while Writer owns the work and joins its cleanup.
    @MainActor final class WriterContinuedProcessing {
        private struct Work {
            let id: String
            let expire: @Sendable () async -> Void
            let failed: @Sendable (String) async -> Void
            var task: BGContinuedProcessingTask?
            var steps: Int64 = 0
            var expired = false
        }
        private var work: Work?
        private var submitting: String?
        private let language: @Sendable () -> AppLanguage

        init(language: @escaping @Sendable () -> AppLanguage = { .english }) { self.language = language }

        func start(
            expire: @escaping @Sendable () async -> Void, failed: @escaping @Sendable (String) async -> Void
        ) -> WriterBackgroundExecution? {
            guard UIApplication.shared.applicationState == .active else { return nil }
            guard work == nil, submitting == nil, let bundle = Bundle.main.bundleIdentifier else {
                Task { await failed("Writer background execution is unavailable.") }
                return nil
            }
            let id = bundle + ".writer." + UUID().uuidString
            work = Work(id: id, expire: expire, failed: failed)
            guard
                BGTaskScheduler.shared.register(
                    forTaskWithIdentifier: id, using: .main,
                    launchHandler: {
                        [weak self] task in
                        MainActor.assumeIsolated {
                            if let self { self.attach(task, id: id) } else { task.setTaskCompleted(success: false) }
                        }
                    })
            else {
                work = nil
                Task { await failed("The Writer background task identifier is not registered.") }
                return nil
            }
            submitting = id
            let copy = language()
            Task.detached { [self] in
                let request = BGContinuedProcessingTaskRequest(
                    identifier: id, title: copy.text("Writer"), subtitle: copy.text("Working on your project"))
                request.strategy = .fail
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                    await submitted(id, failure: nil)
                } catch {
                    let cause = error as NSError
                    await submitted(
                        id, failure: "Writer background execution was denied (\(cause.domain) \(cause.code)).")
                }
            }
            return WriterBackgroundExecution(
                advance: { [weak self] in self?.advance(id) },
                finish: { [weak self] success in self?.finish(id, success: success) })
        }

        private func submitted(_ id: String, failure: String?) async {
            guard submitting == id else { return }
            submitting = nil
            guard let current = work, current.id == id else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
                return
            }
            if let failure {
                finish(id, success: false)
                await current.failed(failure)
            }
        }

        private func attach(_ task: BGTask, id: String) {
            guard let task = task as? BGContinuedProcessingTask, work?.id == id, work?.task == nil else {
                task.setTaskCompleted(success: false)
                return
            }
            work?.task = task
            task.expirationHandler = { [weak self] in
                Task { @MainActor in await self?.expire(id) }
            }
            updateProgress()
        }

        private func expire(_ id: String) async {
            guard let current = work, current.id == id, !current.expired else { return }
            work?.expired = true
            await current.expire()
        }

        private func advance(_ id: String) {
            guard work?.id == id, work?.expired == false else { return }
            work?.steps += 1
            updateProgress()
        }

        private func updateProgress() {
            guard let current = work, let task = current.task else { return }
            task.progress.totalUnitCount = -1
            task.progress.completedUnitCount = current.steps
            let copy = language()
            task.updateTitle(copy.text("Writer"), subtitle: copy.format("Completed %lld steps", current.steps))
        }

        private func finish(_ id: String, success: Bool) {
            guard let current = work, current.id == id else { return }
            work = nil
            if let task = current.task {
                task.expirationHandler = nil
                let completed = success && !current.expired
                if completed {
                    task.progress.totalUnitCount = max(1, current.steps)
                    task.progress.completedUnitCount = task.progress.totalUnitCount
                }
                task.setTaskCompleted(success: completed)
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
            }
        }
    }
#endif
