import NIOCore
import Logging
import Metrics
import Dispatch

/// Runs the KeepAlive mini-protocol (NtN only, protocol ID 8) on a background loop.
///
/// `KeepAliveHandler` sends periodic probes to detect dead NtN connections.
/// If the peer does not respond within `timeoutSeconds`, `run()` throws
/// `KeepAliveError.timeout`. Cancel the enclosing `Task` to stop cleanly.
///
/// ## Usage
///
/// ```swift
/// let handler = KeepAliveHandler(
///     channel: channel,
///     demux: demux,
///     intervalSeconds: 60,
///     timeoutSeconds: 10
/// )
///
/// // Run on a detached Task; cancel to stop
/// let task = Task {
///     try await handler.run()
/// }
/// // …later…
/// task.cancel()
/// ```
///
/// Round-trip times are recorded as `cardano_network_keepalive_rtt_seconds`.
public struct KeepAliveHandler: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let intervalSeconds: Double
    private let timeoutSeconds: Double
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        intervalSeconds: Double = 60.0,
        timeoutSeconds: Double = 10.0,
        logger: Logger = LoggerFactory.logger(subsystem: "keepalive")
    ) {
        self.channel = channel
        self.demux = demux
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger
    }

    // MARK: - Public API

    /// Start the KeepAlive probe loop.
    ///
    /// Sends a `keepAlive` probe every `intervalSeconds`. Throws
    /// `KeepAliveError.timeout` if no response arrives within `timeoutSeconds`.
    /// Returns when the `Task` is cancelled (sends `done` before returning).
    public func run() async throws {
        let driver = makeDriver()
        var cookie: UInt16 = 0

        logger.debug("KeepAlive: loop started", metadata: [
            "intervalSeconds": "\(intervalSeconds)",
            "timeoutSeconds":  "\(timeoutSeconds)"
        ])

        while !Task.isCancelled {
            let intervalNanoseconds = UInt64(intervalSeconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: intervalNanoseconds)

            guard !Task.isCancelled else { break }

            let sentCookie = cookie
            cookie &+= 1

            logger.debug("KeepAlive: sending probe", metadata: ["cookie": "\(sentCookie)"])

            let start = DispatchTime.now()

            try await driver.send(.keepAlive(cookie: sentCookie)) { state in
                guard let s = state as? KeepAliveState else { return state }
                return try s.afterSend(.keepAlive(cookie: sentCookie))
            }

            // Wait for response with timeout
            let response = try await withTimeout(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) {
                try await driver.receive { msg, state in
                    guard let s = state as? KeepAliveState else { return state }
                    return try s.afterReceive(msg)
                }
            } onTimeout: {
                let elapsed = DispatchTime.nanosecondsSince(start)
                logger.error("KeepAlive: timeout", metadata: [
                    "cookie":  "\(sentCookie)",
                    "elapsedNs": "\(elapsed)"
                ])
                throw KeepAliveError.timeout(cookie: sentCookie, elapsedNanoseconds: elapsed)
            }

            guard case .keepAliveResponse(let receivedCookie) = response else {
                throw ProtocolError.invalidTransition(
                    protocol: "keepAlive",
                    state: "busy",
                    message: String(describing: response)
                )
            }

            guard receivedCookie == sentCookie else {
                throw KeepAliveError.cookieMismatch(sent: sentCookie, received: receivedCookie)
            }

            let elapsedNs = DispatchTime.nanosecondsSince(start)

            logger.debug("KeepAlive: response received", metadata: [
                "cookie":    "\(sentCookie)",
                "elapsedNs": "\(elapsedNs)"
            ])

            CardanoMetrics
                .timer(CardanoMetrics.keepAliveRTTSeconds)
                .recordNanoseconds(elapsedNs)
        }

        // Clean shutdown: send done
        logger.debug("KeepAlive: sending done")
        try await driver.send(.done) { state in
            guard let s = state as? KeepAliveState else { return state }
            return try s.afterSend(.done)
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<KeepAliveCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.keepAlive)
        return ProtocolDriver(
            channel: channel,
            codec: KeepAliveCodec(),
            protocolID: MuxSDU.ProtocolID.keepAlive,
            initialState: KeepAliveState.idle,
            inboundStream: stream,
            protocolName: "keepAlive",
            logger: logger
        )
    }

    /// Run `body` with a deadline; call `onTimeout` and throw if it doesn't complete in time.
    private func withTimeout<T: Sendable>(
        nanoseconds: UInt64,
        body: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                return try onTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

