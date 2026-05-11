import NIOCore
import Logging
import Metrics
import Dispatch

/// Runs the BlockFetch mini-protocol (NtN only, protocol ID 3) and downloads
/// complete block bodies for a requested range of points.
///
/// ## Usage
///
/// ```swift
/// let client = BlockFetchClient(channel: channel, demux: demux)
///
/// let blocks = try await client.fetch(
///     from: .blockPoint(slot: 1_000_000, hash: startHash),
///     to:   .blockPoint(slot: 1_001_000, hash: endHash)
/// )
///
/// for block in blocks {
///     print("Block body: \(block.readableBytes) bytes")
/// }
/// ```
///
/// Each call to `fetch` creates a fresh `ProtocolDriver` on a new inbound stream.
/// After `batchDone` the driver is discarded; the client returns to idle and is
/// ready to issue another range request.
///
/// - Note: BlockFetch is NtN-only. For NtC connections use ChainSync with
///   `mode: .nodeToClient`, which delivers full blocks directly.
public struct BlockFetchClient: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        logger: Logger = LoggerFactory.logger(subsystem: "blockfetch")
    ) {
        self.channel = channel
        self.demux = demux
        self.logger = logger
    }

    // MARK: - Public API

    /// Download all block bodies in the half-open range `[from, to]`.
    ///
    /// - Returns: An array of raw CBOR `ByteBuffer`s, one per block. The
    ///   ordering matches the chain order from `from` to `to`.
    /// - Throws: `BlockFetchError.emptyBatch` if the node reports `noBlocks`
    ///   for the requested range, or a `ProtocolError` on protocol violations.
    public func fetch(from startPoint: Point, to endPoint: Point) async throws -> [ByteBuffer] {
        let driver = makeDriver()
        let start  = DispatchTime.now()

        logger.debug("BlockFetch: requesting range", metadata: [
            "from": "\(startPoint)",
            "to":   "\(endPoint)"
        ])

        try await driver.send(.requestRange(from: startPoint, to: endPoint)) { state in
            guard let s = state as? BlockFetchState else { return state }
            return try s.afterSend(.requestRange(from: startPoint, to: endPoint))
        }

        // First server response: startBatch or noBlocks.
        let first = try await driver.receive { msg, state in
            guard let s = state as? BlockFetchState else { return state }
            return try s.afterReceive(msg)
        }

        switch first {
        case .noBlocks:
            logger.warning("BlockFetch: no blocks in range", metadata: [
                "from": "\(startPoint)",
                "to":   "\(endPoint)"
            ])
            throw BlockFetchError.emptyBatch

        case .startBatch:
            logger.debug("BlockFetch: batch started")

        default:
            throw ProtocolError.invalidTransition(
                protocol: "blockFetch",
                state: "busy",
                message: String(describing: first)
            )
        }

        // Collect block bodies until batchDone.
        var blocks: [ByteBuffer] = []

        while true {
            let msg = try await driver.receive { msg, state in
                guard let s = state as? BlockFetchState else { return state }
                return try s.afterReceive(msg)
            }

            switch msg {
            case .block(let body):
                blocks.append(body)

            case .batchDone:
                logger.info("BlockFetch: batch complete", metadata: [
                    "blockCount": "\(blocks.count)",
                    "from": "\(startPoint)",
                    "to":   "\(endPoint)"
                ])
                CardanoMetrics
                    .counter(CardanoMetrics.blocksReceivedTotal, dimensions: [("network", "ntn")])
                    .increment(by: blocks.count)
                CardanoMetrics
                    .timer(CardanoMetrics.blockFetchDurationSeconds)
                    .recordNanoseconds(DispatchTime.nanosecondsSince(start))
                return blocks

            default:
                throw ProtocolError.invalidTransition(
                    protocol: "blockFetch",
                    state: "streaming",
                    message: String(describing: msg)
                )
            }
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<BlockFetchCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.blockFetch)
        return ProtocolDriver(
            channel: channel,
            codec: BlockFetchCodec(),
            protocolID: MuxSDU.ProtocolID.blockFetch,
            initialState: BlockFetchState.idle,
            inboundStream: stream,
            protocolName: "blockFetch",
            logger: logger
        )
    }
}

