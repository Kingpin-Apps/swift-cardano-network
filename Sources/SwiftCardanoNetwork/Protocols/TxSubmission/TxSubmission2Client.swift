import Logging
import Metrics
import NIOCore

/// A provider of transactions that `TxSubmission2Client` calls when the remote
/// node requests IDs or bodies.
///
/// Implement this protocol to integrate your mempool. All methods are called
/// from within the TxSubmission2 serve loop.
public protocol TxSubmissionProvider: Sendable {
    /// Return up to `reqCount` advertised transaction IDs, acknowledging that
    /// the remote has already received `ackCount` previously advertised IDs.
    ///
    /// When `blocking` is `true` the implementation may suspend until at least
    /// one new transaction is available. When `false` it must return immediately
    /// (returning an empty array is valid).
    func requestTxIds(
        blocking: Bool,
        ackCount: UInt16,
        reqCount: UInt16
    ) async throws -> [TxIdWithSize]

    /// Return the raw CBOR bodies for the requested transaction IDs.
    ///
    /// Return a buffer for every ID in `ids`, in the same order.
    func requestTxs(_ ids: [TxId]) async throws -> [ByteBuffer]
}

/// Runs the TxSubmission2 mini-protocol (NtN only, protocol ID 4) in server-driven mode.
///
/// TxSubmission2 is **pull-based**: the remote node controls when it asks for
/// transactions. `TxSubmission2Client` drives the response loop, delegating
/// mempool lookups to a `TxSubmissionProvider`.
///
/// ## Usage
///
/// ```swift
/// struct MyMempool: TxSubmissionProvider {
///     func requestTxIds(blocking: Bool, ackCount: UInt16, reqCount: UInt16) async throws -> [TxIdWithSize] {
///         // return up to reqCount pending tx IDs from your mempool
///     }
///     func requestTxs(_ ids: [TxId]) async throws -> [ByteBuffer] {
///         // return the raw CBOR bodies for the requested IDs
///     }
/// }
///
/// let client = TxSubmission2Client(channel: channel, demux: demux)
/// try await client.run(provider: MyMempool())
/// ```
///
/// `run(provider:)` suspends until the remote node sends `MsgDone` or an error
/// is thrown. Cancel the enclosing `Task` to stop early.
public struct TxSubmission2Client: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger
    /// Eagerly registered inbound stream.
    ///
    /// TxSubmission2 has **server agency** — the remote node sends the very
    /// first message (`requestTxIds`, `requestTxs`, or `done`) immediately
    /// after the handshake, without waiting for any client message.  If the
    /// stream were registered lazily inside `run(provider:)`, that first SDU
    /// can arrive at the `DemuxHandler` before the registration exists and
    /// would be silently dropped, causing `run()` to hang forever.  Registering
    /// eagerly here — at `NodeToNodeConnection` construction time, right after
    /// the handshake — ensures no SDU is missed.
    private let inboundStream: AsyncStream<MuxSDU>

    public init(
        channel: Channel,
        demux: DemuxHandler,
        logger: Logger = LoggerFactory.logger(subsystem: "txsubmission2")
    ) {
        self.channel = channel
        self.demux = demux
        self.logger = logger
        self.inboundStream = demux.register(protocolID: MuxSDU.ProtocolID.txSubmission2)
    }

    // MARK: - Public API

    /// Start the TxSubmission2 serve loop, delegating to `provider` for mempool access.
    ///
    /// Returns when the node sends `MsgDone`. Throws on protocol errors or if
    /// `provider` throws.
    public func run(provider: some TxSubmissionProvider) async throws {
        let driver = makeDriver()

        logger.debug("TxSubmission2: serve loop started")

        while !Task.isCancelled {
            // The protocol starts with server agency: we always receive first.
            let request = try await driver.receive { msg, state in
                guard let s = state as? TxSubmission2State else { return state }
                return try s.afterReceive(msg)
            }

            switch request {
            case .requestTxIds(let blocking, let ackCount, let reqCount):
                logger.debug(
                    "TxSubmission2: requestTxIds",
                    metadata: [
                        "blocking": "\(blocking)",
                        "ackCount": "\(ackCount)",
                        "reqCount": "\(reqCount)",
                    ])

                let entries = try await provider.requestTxIds(
                    blocking: blocking,
                    ackCount: ackCount,
                    reqCount: reqCount
                )

                logger.debug(
                    "TxSubmission2: replyTxIds",
                    metadata: [
                        "count": "\(entries.count)"
                    ])

                try await driver.send(.replyTxIds(entries)) { state in
                    guard let s = state as? TxSubmission2State else { return state }
                    return try s.afterSend(.replyTxIds(entries))
                }

                CardanoMetrics
                    .counter(
                        CardanoMetrics.txSubmissionsTotal,
                        dimensions: [("network", "ntn"), ("result", "advertised")]
                    )
                    .increment(by: entries.count)

            case .requestTxs(let ids):
                logger.debug("TxSubmission2: requestTxs", metadata: ["count": "\(ids.count)"])

                let txs = try await provider.requestTxs(ids)

                logger.debug("TxSubmission2: replyTxs", metadata: ["count": "\(txs.count)"])

                try await driver.send(.replyTxs(txs)) { state in
                    guard let s = state as? TxSubmission2State else { return state }
                    return try s.afterSend(.replyTxs(txs))
                }

                CardanoMetrics
                    .counter(
                        CardanoMetrics.txSubmissionsTotal,
                        dimensions: [("network", "ntn"), ("result", "sent")]
                    )
                    .increment(by: txs.count)

            case .done:
                logger.info("TxSubmission2: protocol done")
                return

            default:
                throw ProtocolError.invalidTransition(
                    protocol: "txSubmission2",
                    state: "idle",
                    message: String(describing: request)
                )
            }
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<TxSubmission2Codec> {
        return ProtocolDriver(
            channel: channel,
            codec: TxSubmission2Codec(),
            protocolID: MuxSDU.ProtocolID.txSubmission2,
            initialState: TxSubmission2State.idle,
            inboundStream: inboundStream,
            protocolName: "txSubmission2",
            logger: logger
        )
    }
}
