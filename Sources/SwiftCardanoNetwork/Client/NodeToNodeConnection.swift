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

    /// The underlying demultiplexer.  Exposed internally so that dummy-protocol
    /// clients (`ReqRespClient`, ad-hoc `PingPongClient`) can be instantiated
    /// on demand via `reqResp(codec:)`.
    let demux: DemuxHandler

    /// The result of the NtN Handshake, when the connection was negotiated.
    /// `nil` for `connectToNodeWithoutHandshake` sessions. Used by
    /// `peerSharing()` to gate availability per §3.11.5.
    public let negotiatedVersion: NegotiatedVersion?

    // MARK: - Mini-protocol clients

    /// ChainSync — streams block headers (fetch bodies separately via `blockFetch`).
    public let chainSync: ChainSyncClient

    /// BlockFetch — downloads complete block bodies for a requested point range.
    public let blockFetch: BlockFetchClient

    /// TxSubmission2 — pull-based transaction propagation with the remote peer.
    public let txSubmission2: TxSubmission2Client

    // MARK: - Internal state

    /// The background KeepAlive probe task. `nil` when the connection was
    /// created with `startKeepAlive: false` (for example, for dummy-protocol
    /// sessions that do not negotiate the full NtN suite).
    private let _keepAliveTask: Task<Void, Error>?

    // MARK: - Init (package-internal; use CardanoNode.connectToNode)

    /// - Parameters:
    ///   - startKeepAlive: When `true` (the default) a KeepAlive probe loop
    ///     is started in the background. Set to `false` for connections that
    ///     only speak dummy protocols — the remote will not have a KeepAlive
    ///     responder and the probes would error.
    init(
        channel: Channel,
        demux: DemuxHandler,
        protocolConfig: ProtocolConfig,
        negotiatedVersion: NegotiatedVersion? = nil,
        startKeepAlive: Bool = true
    ) {
        self.channel = channel
        self.demux = demux
        self.negotiatedVersion = negotiatedVersion
        self.chainSync = ChainSyncClient(channel: channel, demux: demux)
        self.blockFetch = BlockFetchClient(channel: channel, demux: demux)
        self.txSubmission2 = TxSubmission2Client(channel: channel, demux: demux)

        if startKeepAlive {
            let handler = KeepAliveHandler(
                channel: channel,
                demux: demux,
                intervalSeconds: protocolConfig.keepAliveIntervalSeconds,
                timeoutSeconds: protocolConfig.keepAliveTimeoutSeconds
            )
            self._keepAliveTask = Task { try await handler.run() }
        } else {
            self._keepAliveTask = nil
        }
    }

    // MARK: - Peer Sharing (§3.11)

    /// Construct a `PeerSharingClient` for this connection.
    ///
    /// Per §3.11.5, peer sharing is only available when:
    /// * the negotiated NtN version is ≥ 14, **and**
    /// * the remote advertised `peerSharing == 1` (`PeerSharingEnabled`)
    ///   in its handshake reply.
    ///
    /// When either precondition fails this method throws
    /// `PeerSharingError.unsupported`. It also throws if the connection was
    /// created via `CardanoNode.connectToNodeWithoutHandshake` (no negotiated
    /// version is available).
    ///
    /// To make outbound peer-sharing requests succeed against a real
    /// `cardano-node`, set `config.protocol.peerSharing = 1` in the
    /// `CardanoNetworkConfiguration` before calling `connectToNode` so the
    /// remote sees the local side advertising willingness.
    public func peerSharing() throws -> PeerSharingClient {
        guard let negotiated = negotiatedVersion else {
            throw PeerSharingError.unsupported(version: 0, peerSharingFlag: nil)
        }
        return try PeerSharingClient(
            channel: channel,
            demux: demux,
            negotiatedVersion: negotiated
        )
    }

    // MARK: - Lifecycle

    /// Close the underlying connection gracefully.
    ///
    /// Cancels the KeepAlive probe loop (if running) and then closes the NIO
    /// channel. Safe to call multiple times.
    public func close() async {
        _keepAliveTask?.cancel()
        try? await channel.close()
    }
}
