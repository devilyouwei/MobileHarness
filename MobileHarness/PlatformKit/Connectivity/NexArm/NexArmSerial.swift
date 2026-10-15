#if os(macOS)
    import Darwin
    import Foundation

    /// One exclusively opened serial device; no write retries, no pending request queue.
    public actor NexArmSerial: NexArmObservableLink {
        private var fd: Int32
        private var busy = false
        private var observationID: String?
        private var telemetry = NexArmTelemetryCache()
        public func beginObservation() throws -> String {
            guard fd >= 0 else { throw NexArmError.disconnected }
            guard !busy, observationID == nil else { throw NexArmError.busy }
            guard tcflush(fd, TCIFLUSH) == 0 else { throw NexArmError.io(errno) }
            telemetry = NexArmTelemetryCache()
            let token = UUID().uuidString
            observationID = token
            return token
        }
        public func endObservation(_ session: String) { if observationID == session { observationID = nil } }
        public func sendObserved(_ packet: NexArmPacket, session: String) throws -> Bool {
            try Task.checkCancellation()
            guard observationID == session else { throw NexArmError.disconnected }
            guard fd >= 0 else { throw NexArmError.disconnected }
            guard packet.isObservedControl
            else { throw NexArmError.invalidPacket }
            try send(packet)
            return true
        }
        public func latestObservation(after sequence: UInt64, session: String) throws -> NexArmTelemetry? {
            try Task.checkCancellation()
            guard observationID == session else { throw NexArmError.disconnected }
            guard fd >= 0 else { throw NexArmError.disconnected }
            var consumed = 0
            while true {
                var bytes = [UInt8](repeating: 0, count: 512)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    consumed += count
                    guard consumed <= 16_384 else { throw NexArmError.overflow }
                    try telemetry.receive(Array(bytes.prefix(count)))
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw NexArmError.io(errno)
                } else {
                    break
                }
            }
            guard let latest = telemetry.latest, latest.sequence > sequence else { return nil }
            return latest
        }

        public init(path: String) throws {
            guard path.hasPrefix("/dev/cu.usbserial-") || path.hasPrefix("/dev/tty.usbserial-") else {
                throw NexArmError.disconnected
            }
            let opened = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard opened >= 0 else { throw NexArmError.io(errno) }
            do {
                guard ioctl(opened, TIOCEXCL) == 0 else { throw NexArmError.io(errno) }
                var settings = termios()
                guard tcgetattr(opened, &settings) == 0 else { throw NexArmError.io(errno) }
                cfmakeraw(&settings)
                settings.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS)
                settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
                cfsetspeed(&settings, speed_t(B9600))
                guard tcsetattr(opened, TCSANOW, &settings) == 0 else { throw NexArmError.io(errno) }
                var speed: speed_t = 1_000_000
                guard ioctl(opened, 0x8008_5402, &speed) == 0 else { throw NexArmError.io(errno) }
            } catch {
                Darwin.close(opened)
                throw error
            }
            fd = opened
        }
        deinit { if fd >= 0 { Darwin.close(fd) } }

        public func close() {
            observationID = nil
            telemetry = NexArmTelemetryCache()
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }

        /// Serial admission only, matching BLE write semantics; physical completion is queried separately.
        public func write(_ packet: NexArmPacket) throws {
            try Task.checkCancellation()
            guard !busy, observationID == nil else { throw NexArmError.busy }
            guard fd >= 0 else { throw NexArmError.disconnected }
            try send(packet)
        }

        private func send(_ packet: NexArmPacket) throws {
            let bytes = packet.bytes
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == bytes.count else { throw NexArmError.io(written < 0 ? errno : EIO) }
        }

        public func exchange(
            _ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int
        ) async throws -> NexArmPacket {
            try Task.checkCancellation()
            guard !busy, observationID == nil else { throw NexArmError.busy }
            guard fd >= 0 else { throw NexArmError.disconnected }
            busy = true
            defer { busy = false }
            // Discard only stale incoming telemetry/logs before a fresh query. Never discard outgoing commands.
            guard tcflush(fd, TCIFLUSH) == 0 else { throw NexArmError.io(errno) }
            try send(packet)
            var decoder = NexArmDecoder()
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            var consumed = 0
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard fd >= 0 else { throw NexArmError.disconnected }
                var bytes = [UInt8](repeating: 0, count: 512)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    consumed += count
                    guard consumed <= 16_384 else { throw NexArmError.overflow }
                    try decoder.append(Array(bytes.prefix(count)))
                    while let response = try decoder.next() {
                        if response.id == replyID, response.command == replyCommand,
                            response.payload.count == replyCount
                        {
                            return response
                        }
                    }
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw NexArmError.io(errno)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NexArmError.timeout
        }
    }
#endif
