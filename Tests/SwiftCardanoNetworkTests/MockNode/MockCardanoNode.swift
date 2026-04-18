import Logging
import NIOCore
import NIOExtras
import NIOPosix

@testable import SwiftCardanoNetwork

// MARK: - MockNodeConfig

/// Controls how `MockCardanoNode` responds to each mini-protocol.
struct MockNodeConfig: Sendable {

    // MARK: Handshake
    /// Network magic to accept during the Handshake.
    var networkMagic: UInt32 = 764_824_073
    /// Handshake mode (NtN or NtC) the server operates in.
    var handshakeMode: HandshakeCodec.Mode = .nodeToNode

    // MARK: ChainSync
    /// Blocks to stream via ChainSync (`rollForward`), in order.
    var chainSyncBlocks: [RawBlock] = []
    /// Tip reported alongside every ChainSync response.
    var chainSyncTip: Tip = Tip(point: .origin, blockNo: 0)

    // MARK: LocalTxSubmission
    /// Whether `submitTx` is acknowledged (`acceptTx`) or rejected.
    var acceptTransactions: Bool = true

    // MARK: LocalStateQuery
    /// Fixed result returned for every ledger query.
    var queryResult: RawResult = {
        var buf = ByteBufferAllocator().buffer(capacity: 1)
        buf.writeBytes([0x80])  // CBOR empty array
        return RawResult(era: 6, rawCBOR: buf)
    }()

    // MARK: LocalTxMonitor
    /// Slot number reported in the mempool snapshot.
    var mempoolSlot: UInt64 = 1_000
    /// Transactions returned by sequential `nextTx` requests.
    var mempoolTxs: [MempoolTx] = []
    /// Capacity metrics returned by `getCapacity`.
    var mempoolCapacity: MempoolCapacity = MempoolCapacity(
        capacityInBytes: 65_536,
        sizeInBytes: 0,
        numberOfTxs: 0
    )

    // MARK: BlockFetch
    /// Block bodies returned per `requestRange`. If empty the server sends `noBlocks`.
    var blockFetchBlocks: [ByteBuffer] = []

    // MARK: TxSubmission2
    /// Controls the message sequence the mock server sends as a TxSubmission2 NtN peer.
    var txSubmission2Behavior: TxSubmission2MockBehavior = .doneImmediately
}

// MARK: - TxSubmission2MockBehavior

/// Controls how `MockCardanoNode` behaves as the TxSubmission2 NtN peer.
enum TxSubmission2MockBehavior: Sendable {
    /// Send `MsgDone` immediately; client returns after one receive.
    case doneImmediately
    /// Send one `requestTxIds`, wait for `replyTxIds`, then send `MsgDone`.
    case requestTxIdsAndDone(blocking: Bool, ackCount: UInt16, reqCount: UInt16)
    /// Send one `requestTxs`, wait for `replyTxs`, then send `MsgDone`.
    case requestTxsAndDone(ids: [TxId])
}

// MARK: - MockCardanoNode

/// Lightweight in-process Cardano node stub for integration tests.
///
/// Binds a TCP server on a random local port and handles one connection at a
/// time. Protocol responses are fully controlled by `MockNodeConfig`.
///
/// ```swift
/// let node = try await MockCardanoNode(config: config, group: group)
/// defer { Task { try? await node.stop() } }
///
/// let port = await node.port
/// ```
actor MockCardanoNode {

    let port: Int
    private let serverChannel: Channel

    init(config: MockNodeConfig = MockNodeConfig(), group: EventLoopGroup) async throws {
        let logger = Logger(label: "test.mock-node")

        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                let demux = DemuxHandler(logger: logger)
                let handler = MockServerChannelHandler(config: config, demux: demux, logger: logger)
                do {
                    try ch.pipeline.syncOperations.addHandlers([
                        MessageToByteHandler(MuxFrameEncoder()),
                        ByteToMessageHandler(
                            MuxFrameDecoder(maxPayloadSize: 65_535, logger: logger)
                        ),
                        demux,
                        handler,
                    ])
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        self.serverChannel = channel
        self.port = channel.localAddress!.port!
    }

    func stop() async throws {
        try await serverChannel.close()
    }
}

// MARK: - MockServerChannelHandler

/// NIO handler that spawns the async serve loop when the channel becomes active.
private final class MockServerChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Never
    typealias OutboundOut = MuxSDU

    private let config: MockNodeConfig
    private let demux: DemuxHandler
    private let logger: Logger

    init(config: MockNodeConfig, demux: DemuxHandler, logger: Logger) {
        self.config = config
        self.demux = demux
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let runner = MockServerRunner(
            config: config, demux: demux, channel: channel, logger: logger)
        Task {
            do {
                try await runner.run()
            } catch {
                logger.error("Mock server error", metadata: ["error": "\(error)"])
                channel.close(promise: nil)
            }
        }
        context.fireChannelActive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Mock channel error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }
}

// MARK: - MockServerRunner

/// Runs all mini-protocol server loops for a single accepted connection.
///
/// All `AsyncStream` registrations happen synchronously inside `init`, which is
/// called on the NIO event-loop thread from `channelActive`. This guarantees
/// that every protocol stream is registered before the first `channelRead`
/// fires, preventing the data race between `DemuxHandler.register()` (Swift
/// Concurrency task) and `DemuxHandler.channelRead()` (event-loop thread) that
/// previously caused a SIGSEGV.
private struct MockServerRunner: Sendable {
    let config: MockNodeConfig
    let channel: Channel
    let logger: Logger

    // Pre-registered inbound streams — written once in init (event-loop thread),
    // read thereafter only from async handler tasks.
    private let handshakeStream: AsyncStream<MuxSDU>
    private let chainSyncStream: AsyncStream<MuxSDU>
    private let localTxSubmissionStream: AsyncStream<MuxSDU>
    private let localStateQueryStream: AsyncStream<MuxSDU>
    private let localTxMonitorStream: AsyncStream<MuxSDU>
    private let keepAliveStream: AsyncStream<MuxSDU>
    private let blockFetchStream: AsyncStream<MuxSDU>
    private let txSubmission2Stream: AsyncStream<MuxSDU>

    /// Must be called synchronously on the NIO event-loop thread (e.g. from
    /// `channelActive`) so that all registrations complete before any
    /// `channelRead` can fire.
    init(config: MockNodeConfig, demux: DemuxHandler, channel: Channel, logger: Logger) {
        self.config = config
        self.channel = channel
        self.logger = logger
        // Register every protocol synchronously — no data has arrived yet.
        self.handshakeStream = demux.register(protocolID: MuxSDU.ProtocolID.handshake)
        self.chainSyncStream = demux.register(protocolID: MuxSDU.ProtocolID.chainSync)
        self.localTxSubmissionStream = demux.register(
            protocolID: MuxSDU.ProtocolID.localTxSubmission)
        self.localStateQueryStream = demux.register(protocolID: MuxSDU.ProtocolID.localStateQuery)
        self.localTxMonitorStream = demux.register(protocolID: MuxSDU.ProtocolID.localTxMonitor)
        self.keepAliveStream = demux.register(protocolID: MuxSDU.ProtocolID.keepAlive)
        self.blockFetchStream = demux.register(protocolID: MuxSDU.ProtocolID.blockFetch)
        self.txSubmission2Stream = demux.register(protocolID: MuxSDU.ProtocolID.txSubmission2)
    }

    func run() async throws {
        // Handshake must complete before anything else.
        try await handleHandshake()

        // All other protocols run concurrently; errors are ignored per-protocol
        // so that one stalled handler doesn't block the others.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await self.handleChainSync() }
            group.addTask { try? await self.handleLocalTxSubmission() }
            group.addTask { try? await self.handleLocalStateQuery() }
            group.addTask { try? await self.handleLocalTxMonitor() }
            group.addTask { try? await self.handleKeepAlive() }
            group.addTask { try? await self.handleBlockFetch() }
            group.addTask { try? await self.handleTxSubmission2() }
        }
    }

    // MARK: - Write helper

    private func send<Codec: ProtocolCodec>(
        _ message: Codec.Message,
        codec: Codec,
        protocolID: UInt16
    ) async throws {
        let payload = try codec.encode(message, allocator: channel.allocator)
        // Responder side sets the mode bit (0x8000).
        let sdu = MuxSDU(timestamp: 0, protocolID: protocolID | 0x8000, payload: payload)
        try await channel.writeAndFlush(sdu)
    }

    // MARK: - Handshake

    private func handleHandshake() async throws {
        var iter = handshakeStream.makeAsyncIterator()

        guard let sdu = await iter.next() else { return }

        let codec = HandshakeCodec(mode: config.handshakeMode)
        guard case .proposeVersions(let proposals) = try codec.decode(sdu.payload) else { return }

        // Accept the highest mutually supported version.
        let supported: Set<UInt16> = [7, 8, 9, 10, 11, 12, 13, 14]
        let chosen = proposals.keys.filter { supported.contains($0) }.max() ?? 14

        let vd: HandshakeVersionData =
            config.handshakeMode == .nodeToNode
            ? .nodeToNode(networkMagic: config.networkMagic, initiatorOnly: false, peerSharing: nil, query: nil)
            : .nodeToClient(networkMagic: config.networkMagic)

        try await send(
            .acceptVersion(chosen, vd), codec: codec, protocolID: MuxSDU.ProtocolID.handshake)
        logger.debug("Mock: handshake accepted", metadata: ["version": "\(chosen)"])
    }

    // MARK: - ChainSync

    private func handleChainSync() async throws {
        let codec = ChainSyncCodec()
        var iter = chainSyncStream.makeAsyncIterator()
        var blockIdx = 0

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .findIntersect:
                try await send(
                    .intersectNotFound(config.chainSyncTip),
                    codec: codec,
                    protocolID: MuxSDU.ProtocolID.chainSync
                )

            case .requestNext:
                if blockIdx < config.chainSyncBlocks.count {
                    let block = config.chainSyncBlocks[blockIdx]
                    blockIdx += 1
                    try await send(
                        .rollForward(block, config.chainSyncTip),
                        codec: codec,
                        protocolID: MuxSDU.ProtocolID.chainSync
                    )
                } else {
                    try await send(
                        .awaitReply,
                        codec: codec,
                        protocolID: MuxSDU.ProtocolID.chainSync
                    )
                }

            case .done:
                return

            default:
                break
            }
        }
    }

    // MARK: - LocalTxSubmission

    private func handleLocalTxSubmission() async throws {
        let codec = LocalTxSubmissionCodec()
        var iter = localTxSubmissionStream.makeAsyncIterator()

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .submitTx:
                if config.acceptTransactions {
                    try await send(
                        .acceptTx, codec: codec, protocolID: MuxSDU.ProtocolID.localTxSubmission)
                } else {
                    var buf = channel.allocator.buffer(capacity: 1)
                    buf.writeBytes([0x80])
                    let rejection = TxRejection(era: .conway, reasonCBOR: buf)
                    try await send(
                        .rejectTx(rejection), codec: codec,
                        protocolID: MuxSDU.ProtocolID.localTxSubmission)
                }

            case .done:
                return

            default:
                break
            }
        }
    }

    // MARK: - LocalStateQuery

    private func handleLocalStateQuery() async throws {
        let codec = LocalStateQueryCodec()
        var iter = localStateQueryStream.makeAsyncIterator()

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .acquire, .acquireVolatileTip, .reAcquire:
                try await send(
                    .acquired, codec: codec, protocolID: MuxSDU.ProtocolID.localStateQuery)

            case .query:
                try await send(
                    .result(config.queryResult), codec: codec,
                    protocolID: MuxSDU.ProtocolID.localStateQuery)

            case .release:
                break  // client returns to acquired-idle; no server response

            case .done:
                return

            default:
                break
            }
        }
    }

    // MARK: - LocalTxMonitor

    private func handleLocalTxMonitor() async throws {
        let codec = LocalTxMonitorCodec()
        var iter = localTxMonitorStream.makeAsyncIterator()
        var txIdx = 0
        var acquired = false

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .acquire:
                txIdx = 0
                acquired = true
                try await send(
                    .acquired(slotNo: config.mempoolSlot),
                    codec: codec,
                    protocolID: MuxSDU.ProtocolID.localTxMonitor
                )

            case .nextTx:
                if acquired, txIdx < config.mempoolTxs.count {
                    let tx = config.mempoolTxs[txIdx]
                    txIdx += 1
                    try await send(
                        .replyNextTx(tx), codec: codec, protocolID: MuxSDU.ProtocolID.localTxMonitor
                    )
                } else {
                    try await send(
                        .replyNextTx(nil), codec: codec,
                        protocolID: MuxSDU.ProtocolID.localTxMonitor)
                }

            case .hasTx(let txId):
                let found = config.mempoolTxs.contains { tx in
                    let stored =
                        tx.rawCBOR.getBytes(
                            at: tx.rawCBOR.readerIndex,
                            length: tx.rawCBOR.readableBytes
                        ) ?? []
                    return Array(txId.prefix(stored.count)) == stored
                }
                try await send(
                    .replyHasTx(found), codec: codec, protocolID: MuxSDU.ProtocolID.localTxMonitor)

            case .getSizes:
                try await send(
                    .replyGetSizes(config.mempoolCapacity),
                    codec: codec,
                    protocolID: MuxSDU.ProtocolID.localTxMonitor
                )

            case .release:
                acquired = false

            case .done:
                return

            default:
                break
            }
        }
    }

    // MARK: - BlockFetch

    private func handleBlockFetch() async throws {
        let codec = BlockFetchCodec()
        var iter = blockFetchStream.makeAsyncIterator()

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .requestRange:
                if config.blockFetchBlocks.isEmpty {
                    try await send(
                        .noBlocks, codec: codec, protocolID: MuxSDU.ProtocolID.blockFetch)
                } else {
                    try await send(
                        .startBatch, codec: codec, protocolID: MuxSDU.ProtocolID.blockFetch)
                    for block in config.blockFetchBlocks {
                        try await send(
                            .block(block), codec: codec, protocolID: MuxSDU.ProtocolID.blockFetch)
                    }
                    try await send(
                        .batchDone, codec: codec, protocolID: MuxSDU.ProtocolID.blockFetch)
                }

            case .clientDone:
                return

            default:
                break
            }
        }
    }

    // MARK: - TxSubmission2

    private func handleTxSubmission2() async throws {
        let codec = TxSubmission2Codec()
        var iter = txSubmission2Stream.makeAsyncIterator()

        switch config.txSubmission2Behavior {
        case .doneImmediately:
            try await send(.done, codec: codec, protocolID: MuxSDU.ProtocolID.txSubmission2)

        case .requestTxIdsAndDone(let blocking, let ackCount, let reqCount):
            try await send(
                .requestTxIds(blocking: blocking, ackCount: ackCount, reqCount: reqCount),
                codec: codec,
                protocolID: MuxSDU.ProtocolID.txSubmission2
            )
            _ = await iter.next()  // consume replyTxIds
            try await send(.done, codec: codec, protocolID: MuxSDU.ProtocolID.txSubmission2)

        case .requestTxsAndDone(let ids):
            try await send(
                .requestTxs(ids),
                codec: codec,
                protocolID: MuxSDU.ProtocolID.txSubmission2
            )
            _ = await iter.next()  // consume replyTxs
            try await send(.done, codec: codec, protocolID: MuxSDU.ProtocolID.txSubmission2)
        }
    }

    // MARK: - KeepAlive

    private func handleKeepAlive() async throws {
        let codec = KeepAliveCodec()
        var iter = keepAliveStream.makeAsyncIterator()

        while let sdu = await iter.next() {
            switch try codec.decode(sdu.payload) {
            case .keepAlive(let cookie):
                try await send(
                    .keepAliveResponse(cookie: cookie),
                    codec: codec,
                    protocolID: MuxSDU.ProtocolID.keepAlive
                )

            case .done:
                return

            default:
                break
            }
        }
    }
}
