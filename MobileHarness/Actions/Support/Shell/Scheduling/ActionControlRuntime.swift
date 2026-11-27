import Foundation
import FunctionContracts

/// The scheduled execution owns this state and joins it before terminal delivery.
actor ActionControlRuntime {
    let owner: ExecutionOwner
    private let envelope: ExecutionEnvelope
    private let capabilities: Set<String>
    private let deliver: @Sendable (ActionControlFeedback) async -> ActionResultDelivery
    private var pauseControl: (any ActionPauseControl)?
    private let cancelExecution: @Sendable () async -> Void
    private var active: (control: ActionControl, task: Task<Void, Never>)?
    private var pendingControl: ActionControl?
    private var receipts: [ActionControlReceipt] = []
    private var feedbackQueue: [(event: ActionControlFeedback.Event, expiresAt: ContinuousClock.Instant)] = []
    private var feedbackWorker: Task<Void, Never>?
    private var undeliveredReceipts = 0
    private var controlSequence: UInt64 = 0
    private var stateVersion: UInt64 = 0
    private var confirmedState: ActionExecutionStateChange.State = .running
    private var state: ActionExecutionStateChange.State = .running
    private var closing = false

    init(
        owner: ExecutionOwner, envelope: ExecutionEnvelope, capabilities: Set<String>,
        deliver: @escaping @Sendable (ActionControlFeedback) async -> ActionResultDelivery,
        cancelExecution: @escaping @Sendable () async -> Void
    ) {
        self.owner = owner
        self.envelope = envelope
        self.capabilities = capabilities
        self.deliver = deliver
        self.cancelExecution = cancelExecution
    }

    func register(_ pauseControl: any ActionPauseControl) throws {
        try Task.checkCancellation()
        guard !closing, self.pauseControl == nil else { throw ActionHostError.scopeClosed }
        guard
            capabilities.contains(ActionControl.Command.pause.rawValue)
                || capabilities.contains(ActionControl.Command.resume.rawValue)
        else { throw ActionExecutionError.invalidInvocation }
        self.pauseControl = pauseControl
    }

    func submit(_ control: ActionControl) async -> ActionControlReceipt? {
        if let receipt = receipts.first(where: { $0.controlID == control.controlID }) { return receipt }
        guard !closing else { return .init(control, status: .alreadyFinished) }
        if active?.control.controlID == control.controlID || pendingControl?.controlID == control.controlID {
            return nil
        }
        guard capabilities.contains(control.command.rawValue) else { return .init(control, status: .unsupported) }
        guard control.controlSequence > controlSequence else { return .init(control, status: .superseded) }
        if control.command == .cancel {
            controlSequence = control.controlSequence
            close()
            let receipt = recordReceipt(control, status: .accepted)
            await cancelExecution()
            return receipt
        }
        guard let pauseControl else { return .init(control, status: .invalidState) }
        guard undeliveredReceipts < 16 else { return .init(control, status: .busy) }
        undeliveredReceipts += 1
        controlSequence = control.controlSequence
        guard let active else {
            start(control, pauseControl: pauseControl)
            return nil
        }
        let replacedControl = pendingControl
        pendingControl = control
        switch (active.control.command, control.command) {
        case (.pause, .resume), (.resume, .pause):
            active.task.cancel()
        default: break
        }
        if let replacedControl {
            sendReceipt(replacedControl, status: .superseded)
        }
        return nil
    }

    private func start(_ control: ActionControl, pauseControl: any ActionPauseControl) {
        active = (control, Task { await perform(control, pauseControl: pauseControl) })
    }

    private func perform(_ control: ActionControl, pauseControl: any ActionPauseControl) async {
        var outcome: ActionControlReceipt.Status = .applied
        var failure: String?
        do {
            try Task.checkCancellation()
            switch control.command {
            case .pause where state == .paused, .resume where state == .running:
                outcome = .alreadyInState
            case .pause:
                changeState(.pausing, executionID: control.executionID)
                try Task.checkCancellation()
                try await pauseControl.pause()
                try Task.checkCancellation()
                confirmedState = .paused
                changeState(.paused, executionID: control.executionID)
            case .resume:
                if state != .running { changeState(.resuming, executionID: control.executionID) }
                try Task.checkCancellation()
                try await pauseControl.resume()
                try Task.checkCancellation()
                confirmedState = .running
                changeState(.running, executionID: control.executionID)
            case .cancel:
                throw ActionHostError.invalidPayload
            }
        } catch is CancellationError {
            outcome = closing ? .alreadyFinished : .superseded
        } catch {
            outcome = .failed
            failure = String(describing: error)
            if !closing { changeState(confirmedState, executionID: control.executionID) }
        }
        sendReceipt(control, status: outcome, failure: failure)
        active = nil
        if !closing, let next = pendingControl {
            pendingControl = nil
            start(next, pauseControl: pauseControl)
        }
    }

    private func changeState(_ next: ActionExecutionStateChange.State, executionID: String) {
        guard !closing, state != next else { return }
        state = next
        stateVersion &+= 1
        if feedbackQueue.count >= 16 {
            feedbackQueue.removeAll { if case .stateChanged = $0.event { true } else { false } }
        }
        enqueueFeedback(.stateChanged(.init(executionID: executionID, stateVersion: stateVersion, state: next)))
    }

    private func recordReceipt(
        _ control: ActionControl, status: ActionControlReceipt.Status, failure: String? = nil
    ) -> ActionControlReceipt {
        let receipt = ActionControlReceipt(control, status: status, stateVersion: stateVersion, failure: failure)
        if receipts.count == 16 { receipts.removeFirst() }
        receipts.append(receipt)
        return receipt
    }

    private func sendReceipt(
        _ control: ActionControl, status: ActionControlReceipt.Status, failure: String? = nil
    ) {
        enqueueFeedback(.receipt(recordReceipt(control, status: status, failure: failure)))
    }

    private func enqueueFeedback(_ event: ActionControlFeedback.Event) {
        feedbackQueue.append((event, .now + .seconds(5)))
        guard feedbackWorker == nil else { return }
        // The runtime owns and joins delivery independently of the cancellable native operation.
        feedbackWorker = Task.detached { await self.flushFeedback() }
    }

    private func flushFeedback() async {
        while !feedbackQueue.isEmpty {
            let item = feedbackQueue.removeFirst()
            let feedback = ActionControlFeedback(event: item.event, owner: owner, envelope: envelope)
            while ContinuousClock.now < item.expiresAt, await deliver(feedback) == .retry {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if case .receipt = item.event { undeliveredReceipts -= 1 }
        }
        feedbackWorker = nil
    }

    func close() {
        guard !closing else { return }
        closing = true
        active?.task.cancel()
        if let pendingControl {
            self.pendingControl = nil
            sendReceipt(pendingControl, status: .alreadyFinished)
        }
    }

    func finish() async {
        close()
        await active?.task.value
        await feedbackWorker?.value
        pauseControl = nil
    }
}
