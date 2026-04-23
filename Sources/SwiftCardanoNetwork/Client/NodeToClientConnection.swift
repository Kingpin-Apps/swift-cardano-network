import Logging
import NIOCore

/// A fully-negotiated Node-to-Client (NtC) connection exposing all four NtC
/// mini-protocol clients.
///
/// Obtain an instance via `CardanoNode.connectToClient(config:group:)`.
///
/// ```swift
/// let connection = try await CardanoNode.connectToClient(config: .mainnet)
/// defer { await connection.close() }
///
/// // Stream full blocks from the current tip
/// for try await event in connection.chainSync.follow() {
///     if case .rollForward(let block, _) = event {
///         print("Block era=\(block.era) bytes=\(block.rawCBOR.readableBytes)")
///     }
/// }
///
/// // Submit a transaction
/// try await connection.txSubmission.submit(rawTx)
///
/// // Query ledger state
/// let result = try await connection.stateQuery.query(.raw(myQuery))
///
/// // Inspect the local mempool
/// let (slotNo, txs) = try await connection.txMonitor.snapshot()
/// ```
///
/// - Note: NtC ChainSync streams **full blocks**, unlike NtN which delivers
///   headers only. BlockFetch is not needed over an NtC connection.
public struct NodeToClientConnection: Sendable {

    /// The underlying NIO channel.  Close via `close()` rather than directly.
    public let channel: Channel

    /// The underlying demultiplexer.  Exposed internally so that dummy-protocol
    /// clients (`ReqRespClient`, ad-hoc `PingPongClient`) can be instantiated
    /// on demand via `reqResp(codec:)`.
    let demux: DemuxHandler

    // MARK: - Mini-protocol clients

    /// ChainSync — streams full blocks (NtC delivers complete blocks, not headers).
    public let chainSync: ChainSyncClient

    /// LocalTxSubmission — push-based transaction submission with detailed rejection errors.
    public let txSubmission: LocalTxSubmissionClient

    /// LocalStateQuery — UTxO, protocol parameter, stake, and era queries.
    public let stateQuery: LocalStateQueryClient

    /// LocalTxMonitor — live mempool snapshot and presence checks.
    public let txMonitor: LocalTxMonitorClient

    // MARK: - Init (package-internal; use CardanoNode.connectToClient)

    init(channel: Channel, demux: DemuxHandler) {
        self.channel = channel
        self.demux = demux
        self.chainSync = ChainSyncClient(channel: channel, demux: demux, protocolID: MuxSDU.ProtocolID.ntcChainSync)
        self.txSubmission = LocalTxSubmissionClient(channel: channel, demux: demux)
        self.stateQuery = LocalStateQueryClient(channel: channel, demux: demux)
        self.txMonitor = LocalTxMonitorClient(channel: channel, demux: demux)
    }

    // MARK: - Lifecycle

    /// Close the underlying connection gracefully.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops.
    public func close() async {
        try? await channel.close()
    }
}
