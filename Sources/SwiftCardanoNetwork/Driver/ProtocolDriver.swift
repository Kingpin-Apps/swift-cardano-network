import NIOCore
import Logging
import Metrics
import Dispatch

/// Generic state-machine runner for a single Ouroboros mini-protocol.
///
/// Each call to `send(_:)` enforces that the local side holds agency; each call
/// to `receive()` enforces that the remote holds agency. Violations throw
/// `ProtocolError.agencyViolation` or `ProtocolError.unexpectedReceive`.
///
/// The driver is an `actor` so that all state mutations are serialised without
/// external locking. The `AsyncStream.AsyncIterator` is wrapped in a class so
/// that the actor can `await` on it without violating Swift 6's restriction on
/// calling `mutating async` functions on actor-isolated value-type properties.
public actor ProtocolDriver<Codec: ProtocolCodec> {
    private let channel: Channel
    private let codec: Codec
    private let protocolID: UInt16
    private let protocolName: String
    private let logger: Logger

    private(set) public var state: any ProtocolState
    private let inboundIterator: SDUIteratorBox

    public init(
        channel: Channel,
        codec: Codec,
        protocolID: UInt16,
        initialState: any ProtocolState,
        inboundStream: AsyncStream<MuxSDU>,
        protocolName: String,
        logger: Logger
    ) {
        self.channel = channel
        self.codec = codec
        self.protocolID = protocolID
        self.state = initialState
        self.inboundIterator = SDUIteratorBox(stream: inboundStream)
        self.protocolName = protocolName
        self.logger = logger
    }

    // MARK: - Send

    /// Send `message` to the remote. Throws if the local side does not hold agency.
    public func send(
        _ message: Codec.Message,
        transition: @Sendable (any ProtocolState) throws -> any ProtocolState
    ) async throws {
        guard state.agency == .client else {
            let err = ProtocolError.agencyViolation(
                protocol: protocolName,
                state: String(describing: state),
                agency: state.agency
            )
            logger.error("Agency violation on send", metadata: [
                "protocol": "\(protocolName)",
                "state": "\(state)",
                "agency": "\(state.agency)"
            ])
            CardanoMetrics
                .counter(CardanoMetrics.agencyViolationsTotal, dimensions: [("protocol", protocolName)])
                .increment()
            throw err
        }

        let payload = try codec.encode(message, allocator: channel.allocator)
        let sdu = MuxSDU(timestamp: currentTimestamp(), protocolID: protocolID, payload: payload)

        try await channel.writeAndFlush(sdu).get()

        let next = try transition(state)
        logger.trace("State machine transition (send)", metadata: [
            "protocol": "\(protocolName)",
            "from": "\(state)",
            "to": "\(next)",
            "message": "\(message)"
        ])
        state = next
    }

    // MARK: - Receive

    /// Wait for the next message from the remote. Throws if the local side holds agency.
    public func receive(
        transition: @Sendable (Codec.Message, any ProtocolState) throws -> any ProtocolState
    ) async throws -> Codec.Message {
        guard state.agency == .server else {
            throw ProtocolError.unexpectedReceive(
                protocol: protocolName,
                state: String(describing: state)
            )
        }

        guard let sdu = await inboundIterator.next() else {
            // nil from AsyncStream means either the channel closed or the Task
            // was cancelled. Prefer CancellationError so callers can distinguish.
            try Task.checkCancellation()
            throw ProtocolError.connectionClosed
        }

        let message = try codec.decode(sdu.payload)
        let next = try transition(message, state)

        logger.trace("State machine transition (receive)", metadata: [
            "protocol": "\(protocolName)",
            "from": "\(state)",
            "to": "\(next)",
            "message": "\(message)"
        ])
        state = next
        return message
    }

    // MARK: - Helpers

    private func currentTimestamp() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
    }
}

// MARK: - Iterator box

/// Wraps `AsyncStream<MuxSDU>.AsyncIterator` in a reference type so that Swift 6
/// actors can `await` on it without hitting the "cannot call mutating async function
/// on actor-isolated value-type property" restriction.
private final class SDUIteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<MuxSDU>.AsyncIterator

    init(stream: AsyncStream<MuxSDU>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> MuxSDU? {
        await iterator.next()
    }
}
