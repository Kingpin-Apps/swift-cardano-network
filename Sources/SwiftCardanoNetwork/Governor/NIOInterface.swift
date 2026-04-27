import Dispatch
import Foundation
import Logging
import NIOCore
import NIOPosix

/// Production `Interface` adapter for the `OutboundGovernor`, backed by
/// SwiftNIO. Maintains one TCP connection per peer and translates governor
/// commands (`connect`/`send`/`disconnect`) into wire-level operations.
///
/// `NIOInterface` does **not** perform handshake on its own — it just opens
/// the TCP connection, sets up the mux pipeline, and shuttles
/// `AnyMiniProtocolMessage` values between the governor and the wire.
/// The governor's `HandshakeBehavior` drives version negotiation by emitting
/// outbound `MsgProposeVersions` commands the same way it would with any
/// other interface.
///
/// Per peer the interface owns:
/// - one `Channel` from `ClientBootstrap`
/// - one `DemuxHandler` routing inbound SDUs by mini-protocol ID
/// - six per-protocol decode pumps that reassemble segmented SDUs and emit
///   decoded `AnyMiniProtocolMessage` values via `messageReceived` events
public final class NIOInterface: Interface, @unchecked Sendable {

    private let group: EventLoopGroup
    private let maxSDUSize: Int
    private let logger: Logger

    private let lock = NSLock()
    private var connections: [PeerID: PeerConnection] = [:]

    private let eventsContinuation: AsyncStream<InterfaceEvent>.Continuation
    public let events: AsyncStream<InterfaceEvent>

    /// - Parameters:
    ///   - group: NIO event-loop group. The interface does not own it; the
    ///     caller is responsible for shutting it down after `close()`.
    ///   - maxSDUSize: Maximum SDU payload size accepted from the wire.
    ///     Defaults to `12_288` to match `ProtocolConfig.ntnMaxSDUSize`.
    ///   - logger: Optional structured log handle.
    public init(
        group: EventLoopGroup,
        maxSDUSize: Int = 12_288,
        logger: Logger = LoggerFactory.logger(subsystem: "governor.nio")
    ) {
        self.group = group
        self.maxSDUSize = maxSDUSize
        self.logger = logger

        var captured: AsyncStream<InterfaceEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.eventsContinuation = captured
    }

    /// Close every tracked connection and finish the public events stream.
    /// Safe to call multiple times.
    public func close() async {
        let conns = lock.withLock { () -> [PeerConnection] in
            let snapshot = Array(connections.values)
            connections.removeAll()
            return snapshot
        }
        for conn in conns {
            for t in conn.inboundTasks { t.cancel() }
            try? await conn.channel.close()
        }
        eventsContinuation.finish()
    }

    // MARK: - Interface

    public func dispatch(_ command: InterfaceCommand) async {
        switch command {
        case .connect(let pid):
            await openConnection(to: pid)
        case .send(let pid, let msg):
            await sendMessage(to: pid, msg)
        case .disconnect(let pid):
            await closeConnection(to: pid)
        }
    }

    // MARK: - Per-peer connection state

    private struct PeerConnection {
        let channel: Channel
        let demux: DemuxHandler
        let inboundTasks: [Task<Void, Never>]
    }

    // MARK: - Connect

    private func openConnection(to pid: PeerID) async {
        // Idempotent: if we already have a live connection, do nothing.
        let existing = lock.withLock { connections[pid] }
        if existing != nil { return }

        let demux = DemuxHandler(logger: LoggerFactory.logger(subsystem: "mux"))
        let maxSDU = self.maxSDUSize

        do {
            let channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { ch in
                    do {
                        try ch.pipeline.syncOperations.addHandlers([
                            MessageToByteHandler(MuxFrameEncoder()),
                            ByteToMessageHandler(
                                MuxFrameDecoder(
                                    maxPayloadSize: maxSDU,
                                    logger: LoggerFactory.logger(subsystem: "mux")
                                )
                            ),
                            demux,
                        ])
                        return ch.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: pid.host, port: Int(pid.port))
                .get()

            // Register every protocol stream synchronously, before any data
            // can arrive. DemuxHandler's lock means register() is safe from
            // outside the event loop, but doing it now guarantees no SDU is
            // routed to a missing continuation.
            let handshakeStream     = demux.register(protocolID: MuxSDU.ProtocolID.handshake)
            let keepAliveStream     = demux.register(protocolID: MuxSDU.ProtocolID.keepAlive)
            let peerSharingStream   = demux.register(protocolID: MuxSDU.ProtocolID.peerSharing)
            let chainSyncStream     = demux.register(protocolID: MuxSDU.ProtocolID.chainSync)
            let blockFetchStream    = demux.register(protocolID: MuxSDU.ProtocolID.blockFetch)
            let txSubmission2Stream = demux.register(protocolID: MuxSDU.ProtocolID.txSubmission2)

            let alloc = channel.allocator
            let tasks: [Task<Void, Never>] = [
                makeDecodePump(
                    pid: pid, codec: HandshakeCodec(mode: .nodeToNode),
                    stream: handshakeStream, allocator: alloc,
                    wrap: { .handshake($0) }
                ),
                makeDecodePump(
                    pid: pid, codec: KeepAliveCodec(),
                    stream: keepAliveStream, allocator: alloc,
                    wrap: { .keepAlive($0) }
                ),
                makeDecodePump(
                    pid: pid, codec: PeerSharingCodec(),
                    stream: peerSharingStream, allocator: alloc,
                    wrap: { .peerSharing($0) }
                ),
                makeDecodePump(
                    pid: pid, codec: ChainSyncCodec(),
                    stream: chainSyncStream, allocator: alloc,
                    wrap: { .chainSync($0) }
                ),
                makeDecodePump(
                    pid: pid, codec: BlockFetchCodec(),
                    stream: blockFetchStream, allocator: alloc,
                    wrap: { .blockFetch($0) }
                ),
                makeDecodePump(
                    pid: pid, codec: TxSubmission2Codec(),
                    stream: txSubmission2Stream, allocator: alloc,
                    wrap: { .txSubmission2($0) }
                ),
            ]

            // Translate channel close into a `disconnected` event. The
            // governor's `disconnected` visitor hook is responsible for any
            // state cleanup; the interface just notifies.
            let conn = PeerConnection(channel: channel, demux: demux, inboundTasks: tasks)
            lock.withLock { connections[pid] = conn }

            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    if let still = self.connections[pid] {
                        for t in still.inboundTasks { t.cancel() }
                        self.connections.removeValue(forKey: pid)
                    }
                }
                self.eventsContinuation.yield(.disconnected(pid))
            }

            eventsContinuation.yield(.connected(pid))
        } catch {
            logger.error(
                "TCP connect failed",
                metadata: ["peer": "\(pid)", "error": "\(error)"]
            )
            eventsContinuation.yield(.errored(pid, wrapError(error)))
            eventsContinuation.yield(.disconnected(pid))
        }
    }

    // MARK: - Send

    private func sendMessage(to pid: PeerID, _ message: AnyMiniProtocolMessage) async {
        let conn = lock.withLock { connections[pid] }
        guard let conn else {
            logger.warning(
                "send to unknown/closed peer dropped",
                metadata: ["peer": "\(pid)", "protocol": "\(message.protocolName)"]
            )
            return
        }

        do {
            let payload = try encodeOutbound(message, allocator: conn.channel.allocator)
            let sdu = MuxSDU(
                timestamp: currentTimestamp(),
                protocolID: message.protocolID,   // mode bit = 0 (initiator)
                payload: payload
            )
            try await conn.channel.writeAndFlush(sdu).get()
        } catch {
            logger.error(
                "outbound send failed",
                metadata: ["peer": "\(pid)", "protocol": "\(message.protocolName)", "error": "\(error)"]
            )
            eventsContinuation.yield(.errored(pid, wrapError(error)))
        }
    }

    private func encodeOutbound(
        _ message: AnyMiniProtocolMessage,
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        switch message {
        case .handshake(let m):
            return try HandshakeCodec(mode: .nodeToNode).encode(m, allocator: allocator)
        case .keepAlive(let m):
            return try KeepAliveCodec().encode(m, allocator: allocator)
        case .peerSharing(let m):
            return try PeerSharingCodec().encode(m, allocator: allocator)
        case .chainSync(let m):
            return try ChainSyncCodec().encode(m, allocator: allocator)
        case .blockFetch(let m):
            return try BlockFetchCodec().encode(m, allocator: allocator)
        case .txSubmission2(let m):
            return try TxSubmission2Codec().encode(m, allocator: allocator)
        }
    }

    // MARK: - Disconnect

    private func closeConnection(to pid: PeerID) async {
        let conn = lock.withLock { connections.removeValue(forKey: pid) }
        guard let conn else { return }
        for t in conn.inboundTasks { t.cancel() }
        try? await conn.channel.close()
        // The closeFuture handler installed in openConnection will yield
        // the `.disconnected(pid)` event.
    }

    // MARK: - Inbound decode pump

    /// Spawn a `Task` that pulls `MuxSDU`s off `stream`, reassembles segmented
    /// CBOR messages by accumulating payloads, decodes complete messages via
    /// `codec`, and yields them as `messageReceived` events through `wrap`.
    ///
    /// On `CBORError.truncated` the pump waits for more SDUs. On any other
    /// codec error the pump yields an `.errored(pid, ...)` event and exits.
    private func makeDecodePump<C: ProtocolCodec>(
        pid: PeerID,
        codec: C,
        stream: AsyncStream<MuxSDU>,
        allocator: ByteBufferAllocator,
        wrap: @escaping @Sendable (C.Message) -> AnyMiniProtocolMessage
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var accumulated = allocator.buffer(capacity: 0)
            for await sdu in stream {
                guard !Task.isCancelled else { return }
                accumulated.writeImmutableBuffer(sdu.payload)

                while accumulated.readableBytes > 0 {
                    do {
                        var probe = accumulated
                        let decoded = try codec.decode(&probe)
                        let consumed = probe.readerIndex - accumulated.readerIndex
                        accumulated.moveReaderIndex(forwardBy: consumed)
                        self?.eventsContinuation.yield(.messageReceived(pid, wrap(decoded)))
                    } catch CBORError.truncated {
                        // Need more bytes; wait for the next SDU.
                        break
                    } catch {
                        self?.logger.error(
                            "codec decode failed; closing pump",
                            metadata: ["peer": "\(pid)", "error": "\(error)"]
                        )
                        if let self {
                            self.eventsContinuation.yield(.errored(pid, self.wrapError(error)))
                        }
                        return
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func currentTimestamp() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
    }

    /// Coerces any thrown `Error` to the `Error & Sendable` shape required by
    /// `InterfaceEvent.errored`. In Swift 6 every `Error` is implicitly
    /// `Sendable`, so the cast is total — but if a future change relaxes
    /// that guarantee, the helper still gives us a single place to wrap.
    private func wrapError(_ error: Error) -> any Error & Sendable {
        error as any Error & Sendable
    }
}

/// Sendable wrapper used when an underlying error is not `Sendable`-bound at
/// the type system level. Carries only the error description.
public struct NIOInterfaceError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}
