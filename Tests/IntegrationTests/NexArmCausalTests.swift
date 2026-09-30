import Foundation
import PlatformKit
import Testing

#if os(macOS)
    /// Supervised, opt-in comparisons only. Never selected by ordinary repository checks.
    private enum CausalTrial: String {
        case preflight, home, baseline, queries, wait, extra, legacy
        var waitsForEachPose: Bool { self == .wait || self == .legacy }
        var queriesDuringMotion: Bool { self == .queries || self == .legacy }
        var addsLegacyFrames: Bool { self == .extra || self == .legacy }
    }

    private struct CausalFrame {
        let packet: NexArmPacket
        let milliseconds: Int
        var pose: [Int] {
            let values = stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
            return [values[1], values[2], values[3], values[0], values[4], values[5]]
        }
        func retimed(_ duration: Int) throws -> Self {
            let payload = Array(packet.payload.prefix(12)) + [UInt8(duration & 255), UInt8(duration >> 8)]
            return Self(packet: try NexArmPacket(command: 8, payload: payload), milliseconds: duration)
        }
    }

    private func causalFrames(_ gesture: NexArmGesture, trial: CausalTrial) throws -> [CausalFrame] {
        guard gesture == .dance || gesture == .celebrate else { throw NexArmError.invalidMotion }
        let frames = try gesture.settingsTestFrames().map {
            CausalFrame(packet: $0.packet, milliseconds: $0.milliseconds)
        }
        guard let ready = frames.first, let home = frames.last else { throw NexArmError.invalidMotion }
        if trial.addsLegacyFrames {
            return try [home.retimed(3000), ready.retimed(800)] + frames.dropFirst().dropLast()
                + [ready.retimed(800), home.retimed(1200)]
        }
        return frames
    }

    /// USB polling drains existing input only. It does not inject position requests.
    /// Logs are capped at 4096 rows per trial; telemetry remains latest-only in NexArmSerial.
    private actor CausalSerialTrace: NexArmObservableLink {
        private let serial: NexArmSerial
        private let began = ContinuousClock.now
        private var sampler: Task<Void, Never>?
        private var sampleFailure: (any Error)?
        private var loggedSequence: UInt64 = 0
        private var rows = 0
        private var leg = 0
        init(path: String) throws { serial = try NexArmSerial(path: path) }
        private struct Row: Encodable {
            let event: String
            let seconds: Double
            let leg: Int
            let values: [Int]
        }
        private func record(_ event: String, values: [Int] = []) throws {
            guard rows < 4096 else { throw NexArmError.overflow }
            rows += 1
            let elapsed = ContinuousClock.now - began
            let row = Row(
                event: event,
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                leg: leg, values: values)
            print("CAUSAL " + String(decoding: try JSONEncoder().encode(row), as: UTF8.self))
        }
        private func packetValues(_ packet: NexArmPacket) -> [Int] {
            stride(from: 0, to: packet.payload.count - 1, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
        }
        func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
            -> NexArmPacket
        {
            let result = try await serial.exchange(
                packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount)
            if result.command == 11 { try record("preflight", values: packetValues(result)) }
            return result
        }
        func write(_ packet: NexArmPacket) async throws {
            try await serial.write(packet)
            if packet.command == 8 {
                leg += 1
                try record("motion", values: packetValues(packet))
            }
        }
        func beginObservation() async throws -> UUID {
            guard sampler == nil else { throw NexArmError.busy }
            let token = try await serial.beginObservation()
            loggedSequence = 0
            sampleFailure = nil
            sampler = Task {
                while !Task.isCancelled {
                    do {
                        _ = try await latestObservation(after: 0, session: token)
                        try await Task.sleep(for: .milliseconds(20))
                    } catch is CancellationError {
                        return
                    } catch {
                        sampleFailure = error
                        return
                    }
                }
            }
            return token
        }
        func sendObserved(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
            if let sampleFailure { throw sampleFailure }
            let admitted = try await serial.sendObserved(packet, session: session)
            if admitted {
                if packet.command == 8 {
                    leg += 1
                    try record("motion", values: packetValues(packet))
                } else if packet.command == 11 {
                    try record("query")
                }
            }
            return admitted
        }
        func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry? {
            if let sampleFailure { throw sampleFailure }
            let sample = try await serial.latestObservation(after: sequence, session: session)
            if let sample, sample.sequence > loggedSequence {
                loggedSequence = sample.sequence
                try record("sample", values: packetValues(sample.packet))
            }
            return sample
        }
        func endObservation(_ session: UUID) async {
            sampler?.cancel()
            await sampler?.value
            sampler = nil
            await serial.endObservation(session)
        }
        func close() async {
            sampler?.cancel()
            await sampler?.value
            sampler = nil
            await serial.close()
        }
    }

    private func runCausalVariant(_ trial: CausalTrial, gesture: NexArmGesture, link: CausalSerialTrace) async throws {
        let frames = try causalFrames(gesture, trial: trial)
        let overallDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let session = try await link.beginObservation()
            do {
                var sequence = try await link.latestObservation(after: 0, session: session)?.sequence ?? 0
                let start = ContinuousClock.now
                guard try await link.sendObserved(frame.packet, session: session) else { throw NexArmError.busy }
                let final = index == frames.count - 1
                let nominalEnd = start.advanced(by: .milliseconds(frame.milliseconds))
                var tracker = NexArmArrivalTracker(
                    target: frame.pose, final: final, started: start, durationMilliseconds: frame.milliseconds,
                    actionDeadline: overallDeadline)
                var lastReceipt = start.advanced(by: .seconds(-1))
                var nextQuery = start
                // Fixed timing and feedback-gated timing share the same read-only sampler.
                while true {
                    let now = ContinuousClock.now
                    guard now < overallDeadline else { throw NexArmError.timeout }
                    if !trial.waitsForEachPose && now >= nominalEnd { break }
                    if trial.waitsForEachPose {
                        switch tracker.outcome(at: now) {
                        case .arrived: break
                        case .feedbackTimeout, .completionTimeout: throw NexArmError.timeout
                        case .waiting: break
                        }
                        if tracker.outcome(at: now) == .arrived { break }
                    }
                    if let sample = try await link.latestObservation(after: sequence, session: session) {
                        sequence = sample.sequence
                        lastReceipt = sample.receivedAt
                        let bytes = sample.packet.payload
                        let values = stride(from: 0, to: 24, by: 2).map {
                            Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
                        }
                        tracker.observe(
                            pose: Array(values.prefix(6)), joints: Array(values.suffix(6)), at: sample.receivedAt)
                    }
                    if trial.queriesDuringMotion && now >= nextQuery && now - lastReceipt >= .milliseconds(200) {
                        _ = try await link.sendObserved(NexArmPacket(command: 11), session: session)
                        nextQuery = .now.advanced(by: .milliseconds(200))
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                await link.endObservation(session)
            } catch {
                await link.endObservation(session)
                throw error  // Never retry, return home automatically, or continue later segments after uncertainty.
            }
        }
    }

    @Test func nexArmCausalPlansChangeOnlyTheirDeclaredFactors() throws {
        for gesture in [NexArmGesture.dance, .celebrate] {
            let baseline = try causalFrames(gesture, trial: .baseline)
            for trial in [CausalTrial.queries, .wait] {
                #expect(try causalFrames(gesture, trial: trial).map(\.packet) == baseline.map(\.packet))
            }
            let extra = try causalFrames(gesture, trial: .extra)
            #expect(extra.count == baseline.count + 2)
            #expect(try causalFrames(gesture, trial: .legacy).map(\.packet) == extra.map(\.packet))
            #expect(extra.map(\.milliseconds) == [3000] + Array(repeating: 800, count: extra.count - 2) + [1200])
            #expect(extra.dropFirst(2).dropLast(2).map(\.packet) == baseline.dropFirst().dropLast().map(\.packet))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_CAUSAL_TEST"] == "1"))
    func nexArmUSBPhysicalCausalTrial() async throws {
        let env = ProcessInfo.processInfo.environment
        let trialName = try #require(env["NEXARM_CAUSAL_TRIAL"])
        let trial = try #require(CausalTrial(rawValue: trialName))
        let gesture: NexArmGesture
        switch env["NEXARM_CAUSAL_GESTURE"] {
        case "dance": gesture = .dance
        case "celebrate": gesture = .celebrate
        default: throw NexArmError.invalidMotion
        }
        let link = try CausalSerialTrace(path: #require(env["NEXARM_PORT"]))
        let controller = NexArmController(link: link)
        print("CAUSAL BEGIN trial=\(trial.rawValue) gesture=\(gesture)")
        do {
            _ = try await controller.verifyCompatibility()
            let first = try await controller.readState()
            try await Task.sleep(for: .milliseconds(200))
            let second = try await controller.readState()
            // A separately selected, supervised home command may leave a hunting pose.
            // A failed comparison never selects this mode automatically.
            if trial != .home {
                try #require(zip(first.joints, second.joints).allSatisfy { abs($0 - $1) <= 2 })
            }
            try #require(
                hypot(Double(second.pose[0]), Double(second.pose[1])) <= 450 && (50...600).contains(second.pose[2]))
            if trial == .home {
                let home = try #require(causalFrames(gesture, trial: .baseline).last).retimed(3000)
                try await link.write(home.packet)
                try await Task.sleep(for: .milliseconds(3200))
            } else if trial == .baseline {
                try await controller.performGesture(gesture, repetitions: 1)
            } else if trial != .preflight {
                try await runCausalVariant(trial, gesture: gesture, link: link)
            }
            if trial != .preflight {
                // A finite target duration does not guarantee that the next serial receipt
                // is fresh or already settled. Observe final home for up to three seconds.
                // These read-only queries occur after playback and never replay movement.
                let start = ContinuousClock.now
                var finalTracker = NexArmArrivalTracker(
                    target: [200, 0, 200, 0, 0, 0], final: true, started: start,
                    durationMilliseconds: 0, actionDeadline: start.advanced(by: .seconds(3)))
                while true {
                    let sample = try await controller.readState()
                    finalTracker.observe(pose: sample.pose, joints: sample.joints, at: .now)
                    switch finalTracker.outcome(at: .now) {
                    case .arrived: break
                    case .feedbackTimeout, .completionTimeout: throw NexArmError.timeout
                    case .waiting: break
                    }
                    if finalTracker.outcome(at: .now) == .arrived { break }
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            await link.close()
            print("CAUSAL END trial=\(trial.rawValue) result=PASS")
        } catch {
            await link.close()
            print("CAUSAL END trial=\(trial.rawValue) result=STOP error=\(error)")
            throw error
        }
    }
#endif
