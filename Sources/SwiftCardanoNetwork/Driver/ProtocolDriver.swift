import Dispatch
import Logging
import Metrics
import NIOCore

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
    /// Bytes left over from a previous SDU that weren't consumed by the last decode.
    /// The Ouroboros mux may coalesce multiple protocol messages in a single SDU payload;
    /// these leftover bytes are the start of the next message.
    private var receiveLeftover: ByteBuffer

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
        self.receiveLeftover = channel.allocator.buffer(capacity: 0)
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
            logger.error(
                "Agency violation on send",
                metadata: [
                    "protocol": "\(protocolName)",
                    "state": "\(state)",
                    "agency": "\(state.agency)",
                ])
            CardanoMetrics
                .counter(
                    CardanoMetrics.agencyViolationsTotal, dimensions: [("protocol", protocolName)]
                )
                .increment()
            throw err
        }

        let payload = try codec.encode(message, allocator: channel.allocator)
        let sdu = MuxSDU(timestamp: currentTimestamp(), protocolID: protocolID, payload: payload)

        try await channel.writeAndFlush(sdu).get()

        let next = try transition(state)
        logger.trace(
            "State machine transition (send)",
            metadata: [
                "protocol": "\(protocolName)",
                "from": "\(state)",
                "to": "\(next)",
                "message": "\(message)",
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

        // Accumulate SDU payloads until the CBOR message is complete.
        // Large blocks (e.g. Conway) are segmented across multiple SDU frames
        // by the Ouroboros mux layer and must be reassembled here.
        //
        // Seed with any bytes left over from the previous receive() call:
        // the mux may coalesce multiple protocol messages into a single SDU,
        // so we must not discard bytes that follow a successfully decoded message.
        var accumulated = receiveLeftover
        receiveLeftover = channel.allocator.buffer(capacity: 0)
        let message: Codec.Message = try await {
            while true {
                // Only fetch a new SDU if the accumulated buffer is empty.
                if accumulated.readableBytes == 0 {
                    guard let sdu = await inboundIterator.next() else {
                        try Task.checkCancellation()
                        throw ProtocolError.connectionClosed
                    }
                    accumulated.writeImmutableBuffer(sdu.payload)
                }
                do {
                    // codec.decode takes a value-type ByteBuffer; pass a copy so
                    // we can measure how many bytes it consumed by diffing readerIndex.
                    var probe = accumulated
                    let decoded = try codec.decode(&probe)
                    // Advance accumulated by exactly the bytes probe consumed.
                    let consumed = probe.readerIndex - accumulated.readerIndex
                    accumulated.moveReaderIndex(forwardBy: consumed)
                    // Save any bytes that weren't consumed by the decode.
                    if accumulated.readableBytes > 0 {
                        receiveLeftover = accumulated
                    }
                    return decoded
                } catch CBORError.truncated {
                    // Incomplete CBOR — fetch the next SDU segment and append it.
                    guard let sdu = await inboundIterator.next() else {
                        try Task.checkCancellation()
                        throw ProtocolError.connectionClosed
                    }
                    accumulated.writeImmutableBuffer(sdu.payload)
                    continue
                }
            }
        }()

        let next = try transition(message, state)

        logger.trace(
            "State machine transition (receive)",
            metadata: [
                "protocol": "\(protocolName)",
                "from": "\(state)",
                "to": "\(next)",
                "message": "\(message)",
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
