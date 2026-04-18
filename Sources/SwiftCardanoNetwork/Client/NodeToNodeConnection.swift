import Logging
import NIOCore

/// A fully-negotiated Node-to-Node (NtN) connection exposing all four NtN
/// mini-protocol clients.
///
/// Obtain an instance via `CardanoNode.connectToNode(config:group:)`.
///
/// A KeepAlive probe loop is automatically started on construction and runs in
/// the background until `close()` is called.
///
/// ```swift
/// let connection = try await CardanoNode.connectToNode(config: .mainnet)
/// defer { await connection.close() }
///
/// // Stream block headers from the current tip
/// for try await event in connection.chainSync.follow() {
///     if case .rollForward(let block, _) = event {
///         // Download the full body if needed
///         let bodies = try await connection.blockFetch.fetch(
///             from: .blockPoint(slot: block.era, hash: block.rawCBOR.getBytes(at: 0, length: 32)!),
///             to:   .blockPoint(slot: block.era, hash: block.rawCBOR.getBytes(at: 0, length: 32)!)
///         )
///     }
/// }
///
/// // Serve pending transactions to the remote peer
/// try await connection.txSubmission2.run(provider: myMempool)
/// ```
///
/// - Note: NtN ChainSync streams **block headers** only.  Use `blockFetch` to
///   retrieve full block bodies.  LocalTxSubmission, LocalStateQuery, and
///   LocalTxMonitor are NtC-only; use `NodeToClientConnection` for those.
public struct NodeToNodeConnection: Sendable {

    /// The underlying NIO channel.  Close via `close()` rather than directly.
    public let channel: Channel

    // MARK: - Mini-protocol clients

    /// ChainSync — streams block headers (fetch bodies separately via `blockFetch`).
    public let chainSync: ChainSyncClient

    /// BlockFetch — downloads complete block bodies for a requested point range.
    public let blockFetch: BlockFetchClient

    /// TxSubmission2 — pull-based transaction propagation with the remote peer.
    public let txSubmission2: TxSubmission2Client

    // MARK: - Internal state

    private let _keepAliveTask: Task<Void, Error>

    // MARK: - Init (package-internal; use CardanoNode.connectToNode)

    init(channel: Channel, demux: DemuxHandler, protocolConfig: ProtocolConfig) {
        self.channel = channel
        self.chainSync = ChainSyncClient(channel: channel, demux: demux)
        self.blockFetch = BlockFetchClient(channel: channel, demux: demux)
        self.txSubmission2 = TxSubmission2Client(channel: channel, demux: demux)

        let handler = KeepAliveHandler(
            channel: channel,
            demux: demux,
            intervalSeconds: protocolConfig.keepAliveIntervalSeconds,
            timeoutSeconds: protocolConfig.keepAliveTimeoutSeconds
        )
        self._keepAliveTask = Task { try await handler.run() }
    }

    // MARK: - Lifecycle

    /// Close the underlying connection gracefully.
    ///
    /// Cancels the KeepAlive probe loop (causing it to send `done` to the
    /// peer) and then closes the NIO channel.  Safe to call multiple times.
    public func close() async {
        _keepAliveTask.cancel()
        try? await channel.close()
    }
}
