import Dispatch
import Logging
import NIOCore

/// Runs the Ping-Pong mini-protocol (dummy protocol, §3.5.1) from the client
/// (initiator) side.
///
/// Ping-Pong is a trivial liveness/demo protocol in which the client sends a
/// `ping` and the server echoes back a `pong`. It is not part of the
/// Node-to-Node or Node-to-Client protocol suites.
///
/// ## Usage
///
/// ```swift
/// let client = PingPongClient(channel: channel, demux: demux)
/// try await client.ping()      // single round-trip
/// try await client.run(count: 5) // five round-trips then done
/// ```
public struct PingPongClient: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        logger: Logger = LoggerFactory.logger(subsystem: "pingPong")
    ) {
        self.channel = channel
        self.demux = demux
        self.logger = logger
    }

    // MARK: - Public API

    /// Send one `ping` and wait for the matching `pong`.
    ///
    /// State transitions: `idle → busy → idle`.
    public func ping() async throws {
        let driver = makeDriver()
        try await sendPing(driver: driver)
        try await awaitPong(driver: driver)
    }

    /// Send `count` pings (each awaiting its `pong`) then terminate with `done`.
    ///
    /// State transitions: `idle → busy → idle → … → idle → done`.
    public func run(count: Int) async throws {
        precondition(count >= 0, "count must be non-negative")
        let driver = makeDriver()
        for _ in 0..<count {
            try await sendPing(driver: driver)
            try await awaitPong(driver: driver)
        }
        try await sendDone(driver: driver)
    }

    /// Terminate the protocol without sending any further pings.
    ///
    /// Must be called while the local side holds agency (state `idle`).
    public func done() async throws {
        let driver = makeDriver()
        try await sendDone(driver: driver)
    }

    // MARK: - Private

    private func sendPing(driver: ProtocolDriver<PingPongCodec>) async throws {
        logger.debug("PingPong: sending ping")
        try await driver.send(.ping) { state in
            guard let s = state as? PingPongState else { return state }
            return try s.afterSend(.ping)
        }
    }

    private func awaitPong(driver: ProtocolDriver<PingPongCodec>) async throws {
        let msg = try await driver.receive { msg, state in
            guard let s = state as? PingPongState else { return state }
            return try s.afterReceive(msg)
        }
        guard case .pong = msg else {
            throw ProtocolError.invalidTransition(
                protocol: "pingPong",
                state: "busy",
                message: String(describing: msg)
            )
        }
        logger.debug("PingPong: received pong")
    }

    private func sendDone(driver: ProtocolDriver<PingPongCodec>) async throws {
        logger.debug("PingPong: sending done")
        try await driver.send(.done) { state in
            guard let s = state as? PingPongState else { return state }
            return try s.afterSend(.done)
        }
    }

    private func makeDriver() -> ProtocolDriver<PingPongCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.pingPong)
        return ProtocolDriver(
            channel: channel,
            codec: PingPongCodec(),
            protocolID: MuxSDU.ProtocolID.pingPong,
            initialState: PingPongState.idle,
            inboundStream: stream,
            protocolName: "pingPong",
            logger: logger
        )
    }
}
