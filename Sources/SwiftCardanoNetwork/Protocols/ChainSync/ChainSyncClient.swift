import NIOCore
import Logging
import Metrics

/// Runs the ChainSync mini-protocol and exposes chain events as an
/// `AsyncThrowingStream`.
///
/// ## Typical NtC usage
///
/// ```swift
/// let client = ChainSyncClient(channel: channel, demux: demux, config: config, mode: .nodeToClient)
///
/// // Stream from a known point (or origin)
/// for try await event in client.follow(from: [.blockPoint(slot: 1_000_000, hash: knownHash)]) {
///     switch event {
///     case .rollForward(let block, let tip):
///         print("New block era=\(block.era) tip=\(tip.blockNo)")
///     case .rollBackward(let point, _):
///         print("Rollback to \(point)")
///     }
/// }
/// ```
///
/// ## Intersection finding
///
/// When `points` is non-empty the client first sends `FindIntersect` and waits
/// for `IntersectFound` (or `IntersectNotFound`, which throws
/// `ChainSyncError.intersectionNotFound`). Pass an empty array to start from
/// the node's current tip.
public struct ChainSyncClient: Sendable {

    public enum Mode: Sendable { case nodeToNode, nodeToClient }

    private let channel: Channel
    private let demux: DemuxHandler
    private let protocolID: UInt16
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        protocolID: UInt16 = MuxSDU.ProtocolID.chainSync,
        logger: Logger = LoggerFactory.logger(subsystem: "chainsync")
    ) {
        self.channel = channel
        self.demux = demux
        self.protocolID = protocolID
        self.logger = logger
    }

    // MARK: - Public API

    /// Begin streaming chain events from the first intersection in `points`.
    ///
    /// Cancelling the outer `Task` (or breaking out of the `for try await` loop)
    /// terminates the underlying driver task cleanly.
    public func follow(from points: [Point] = []) -> AsyncThrowingStream<ChainEvent, Error> {
        let channel = self.channel
        let demux   = self.demux
        let logger  = self.logger

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let driver = makeDriver(channel: channel, demux: demux, logger: logger)

                    // ── Intersection negotiation ─────────────────────────────────
                    if !points.isEmpty {
                        try await driver.send(.findIntersect(points)) { state in
                            guard let s = state as? ChainSyncState else { return state }
                            return try s.afterSend(.findIntersect(points))
                        }

                        let response = try await driver.receive { msg, state in
                            guard let s = state as? ChainSyncState else { return state }
                            return try s.afterReceive(msg)
                        }

                        switch response {
                        case .intersectFound(let pt, let tip):
                            logger.info("ChainSync intersection found", metadata: [
                                "slot": "\(slotOf(pt))",
                                "hash": "\(hashOf(pt))",
                                "tipBlockNo": "\(tip.blockNo)"
                            ])
                        case .intersectNotFound(let tip):
                            logger.warning("ChainSync intersection not found", metadata: [
                                "requestedPoints": "\(points.count)",
                                "tipBlockNo": "\(tip.blockNo)"
                            ])
                            throw ChainSyncError.intersectionNotFound(tip)
                        default:
                            throw ProtocolError.invalidTransition(
                                protocol: "chainSync", state: "intersect",
                                message: String(describing: response)
                            )
                        }
                    }

                    // ── RequestNext loop ─────────────────────────────────────────
                    while !Task.isCancelled {
                        let event = try await requestNextEvent(driver: driver, logger: logger)
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private helpers

    private func makeDriver(channel: Channel, demux: DemuxHandler, logger: Logger) -> ProtocolDriver<ChainSyncCodec> {
        let stream = demux.register(protocolID: protocolID)
        return ProtocolDriver(
            channel: channel,
            codec: ChainSyncCodec(),
            protocolID: protocolID,
            initialState: ChainSyncState.idle,
            inboundStream: stream,
            protocolName: "chainSync",
            logger: logger
        )
    }
}

// MARK: - RequestNext / event extraction

/// Send `RequestNext`, then consume server responses until a `RollForward` or
/// `RollBackward` is available (transparently handling `AwaitReply`).
private func requestNextEvent(
    driver: ProtocolDriver<ChainSyncCodec>,
    logger: Logger
) async throws -> ChainEvent {

    try await driver.send(.requestNext) { state in
        guard let s = state as? ChainSyncState else { return state }
        return try s.afterSend(.requestNext)
    }

    return try await receiveChainEvent(driver: driver, logger: logger)
}

/// Receive a `RollForward` or `RollBackward`, transparently passing through
/// any `AwaitReply` (which just means the server will reply *later* — we wait).
private func receiveChainEvent(
    driver: ProtocolDriver<ChainSyncCodec>,
    logger: Logger
) async throws -> ChainEvent {

    let message = try await driver.receive { msg, state in
        guard let s = state as? ChainSyncState else { return state }
        return try s.afterReceive(msg)
    }

    switch message {
    case .rollForward(let block, let tip):
        logger.debug("ChainSync new tip", metadata: [
            "era": "\(block.era)",
            "tipBlockNo": "\(tip.blockNo)",
            "tipSlot": "\(slotOf(tip.point))"
        ])
        emitForwardMetrics(tip: tip)
        return .rollForward(block: block, tip: tip)

    case .rollBackward(let point, let tip):
        logger.warning("ChainSync rollback", metadata: [
            "toSlot": "\(slotOf(point))",
            "toHash": "\(hashOf(point))",
            "tipBlockNo": "\(tip.blockNo)"
        ])
        CardanoMetrics
            .counter(CardanoMetrics.rollbacksTotal, dimensions: [("network", "ntc")])
            .increment()
        return .rollBackward(to: point, tip: tip)

    case .awaitReply:
        // Server has no new data yet but will send an unsolicited reply when it does.
        // Just wait for the follow-up without sending another RequestNext.
        return try await receiveChainEvent(driver: driver, logger: logger)

    default:
        throw ProtocolError.invalidTransition(
            protocol: "chainSync",
            state: "canAwait/mustReply",
            message: String(describing: message)
        )
    }
}

// MARK: - Metrics

private func emitForwardMetrics(tip: Tip) {
    CardanoMetrics
        .counter(CardanoMetrics.blocksReceivedTotal, dimensions: [("network", "ntc")])
        .increment()
    CardanoMetrics
        .gauge(CardanoMetrics.chainTipSlot, dimensions: [("network", "ntc")])
        .record(Double(slotOf(tip.point)))
    CardanoMetrics
        .gauge(CardanoMetrics.chainTipBlock, dimensions: [("network", "ntc")])
        .record(Double(tip.blockNo))
}

// MARK: - Point helpers

private func slotOf(_ point: Point) -> UInt64 {
    switch point {
    case .origin:              return 0
    case .blockPoint(let s, _): return s
    }
}

private func hashOf(_ point: Point) -> String {
    switch point {
    case .origin:              return "origin"
    case .blockPoint(_, let h): return h.prefix(4).map { String(format: "%02x", $0) }.joined() + "…"
    }
}
