import NIOCore
import Logging
import Metrics

/// Runs the LocalTxSubmission mini-protocol (NtC, protocol ID 6) and exposes a
/// single `submit(_:)` call.
///
/// ## Usage
///
/// ```swift
/// let client = LocalTxSubmissionClient(channel: channel, demux: demux)
///
/// // Build your transaction with swift-cardano-core, then submit:
/// let tx = RawTransaction(era: .conway, rawCBOR: signedTxCBOR)
/// do {
///     try await client.submit(tx)
///     print("Transaction accepted")
/// } catch LocalTxSubmissionError.rejected(let rejection) {
///     print("Rejected era=\(rejection.era) reason=\(rejection.reasonCBOR.readableBytes) bytes")
/// }
/// ```
///
/// Each call to `submit` creates a fresh `ProtocolDriver` on a new inbound stream
/// registered with the demultiplexer. The protocol always returns to `Idle` after
/// a single submit/response exchange, so multiple sequential calls are safe.
public struct LocalTxSubmissionClient: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        logger: Logger = LoggerFactory.logger(subsystem: "localtxsubmission")
    ) {
        self.channel = channel
        self.demux = demux
        self.logger = logger
    }

    // MARK: - Public API

    /// Submit a pre-CBOR-encoded era-tagged transaction to the node.
    ///
    /// - Returns: `Void` on success (node accepted the transaction).
    /// - Throws: `LocalTxSubmissionError.rejected(_:)` if the node rejected the
    ///   transaction, or a `ProtocolError` on protocol violations.
    public func submit(_ tx: RawTransaction) async throws {
        let driver = makeDriver()

        logger.debug("LocalTxSubmission: submitting tx", metadata: [
            "era":   "\(tx.era)",
            "bytes": "\(tx.rawCBOR.readableBytes)"
        ])

        try await driver.send(.submitTx(tx)) { state in
            guard let s = state as? LocalTxSubmissionState else { return state }
            return try s.afterSend(.submitTx(tx))
        }

        let response = try await driver.receive { msg, state in
            guard let s = state as? LocalTxSubmissionState else { return state }
            return try s.afterReceive(msg)
        }

        switch response {
        case .acceptTx:
            logger.info("LocalTxSubmission: tx accepted", metadata: ["era": "\(tx.era)"])
            CardanoMetrics
                .counter(CardanoMetrics.txSubmissionsTotal,
                         dimensions: [("network", "ntc"), ("result", "accepted")])
                .increment()

        case .rejectTx(let rejection):
            logger.warning("LocalTxSubmission: tx rejected", metadata: [
                "era":         "\(rejection.era)",
                "reasonBytes": "\(rejection.reasonCBOR.readableBytes)"
            ])
            CardanoMetrics
                .counter(CardanoMetrics.txSubmissionsTotal,
                         dimensions: [("network", "ntc"), ("result", "rejected")])
                .increment()
            throw LocalTxSubmissionError.rejected(rejection)

        default:
            throw ProtocolError.invalidTransition(
                protocol: "localTxSubmission",
                state: "busy",
                message: String(describing: response)
            )
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<LocalTxSubmissionCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.localTxSubmission)
        return ProtocolDriver(
            channel: channel,
            codec: LocalTxSubmissionCodec(),
            protocolID: MuxSDU.ProtocolID.localTxSubmission,
            initialState: LocalTxSubmissionState.idle,
            inboundStream: stream,
            protocolName: "localTxSubmission",
            logger: logger
        )
    }
}
