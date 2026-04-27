import Logging
import Metrics
import NIOCore

/// Runs the Peer-Sharing mini-protocol (NtN, protocol ID 10, §3.11) and
/// exposes a single `request(amount:)` call.
///
/// ## Usage
///
/// ```swift
/// let negotiated = try await HandshakeClient(...).negotiate(networkMagic: ...)
///
/// // The protocol is only valid on NtN ≥ 14 with a peer that advertised
/// // PeerSharingEnabled (flag value == 1).  The initialiser throws
/// // `PeerSharingError.unsupported` otherwise.
/// let client = try PeerSharingClient(
///     channel: channel,
///     demux: demux,
///     negotiatedVersion: negotiated
/// )
///
/// let peers = try await client.request(amount: 5)
/// try await client.done()
/// ```
///
/// ## Scope
///
/// This type is a thin wrapper over a single request/reply on the Peer-Sharing
/// wire protocol. The §3.11.5 outbound-governor concerns — per-peer mailbox
/// registries, rate limiting, target-driven request sizing, and PRNG-stable
/// sampling — are intentionally out of scope: those are diffusion-level policy
/// decisions and belong to the caller.
public struct PeerSharingClient: Sendable {

    /// Minimum NtN protocol version that supports peer sharing.
    /// The CDDL specification in §3.11.7 is gated on NtN ≥ 14.
    public static let minSupportedVersion: UInt16 = NodeToNodeVersion.v14
    /// Wire flag value for `PeerSharingEnabled` (see §3.11.5).
    public static let peerSharingEnabled: UInt8 = 1

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger

    /// Construct a client and verify the remote supports peer sharing.
    ///
    /// Throws `PeerSharingError.unsupported` when:
    /// * the negotiated NtN version is below `minSupportedVersion`, or
    /// * the negotiated version data is not NtN, or
    /// * the remote's `peerSharing` flag is missing or not `peerSharingEnabled`.
    public init(
        channel: Channel,
        demux: DemuxHandler,
        negotiatedVersion: NegotiatedVersion,
        logger: Logger = LoggerFactory.logger(subsystem: "peersharing")
    ) throws {
        guard negotiatedVersion.version >= Self.minSupportedVersion else {
            throw PeerSharingError.unsupported(
                version: negotiatedVersion.version,
                peerSharingFlag: nil
            )
        }
        guard case .nodeToNode(_, _, let peerSharing, _) = negotiatedVersion.versionData else {
            throw PeerSharingError.unsupported(
                version: negotiatedVersion.version,
                peerSharingFlag: nil
            )
        }
        guard peerSharing == Self.peerSharingEnabled else {
            throw PeerSharingError.unsupported(
                version: negotiatedVersion.version,
                peerSharingFlag: peerSharing
            )
        }

        self.channel = channel
        self.demux = demux
        self.logger = logger
    }

    /// Construct a client without performing the negotiated-version precondition
    /// check. Intended for tests and for callers who have already validated
    /// support out-of-band.
    public init(
        channel: Channel,
        demux: DemuxHandler,
        logger: Logger = LoggerFactory.logger(subsystem: "peersharing")
    ) {
        self.channel = channel
        self.demux = demux
        self.logger = logger
    }

    // MARK: - Public API

    /// Send a single `MsgShareRequest(amount)` and return the server's reply.
    ///
    /// - Parameter amount: Maximum number of peers to receive (`UInt8`, so
    ///   the wire-level cap is 255). Per §3.11.2 the application should
    ///   pick an amount well below this to discourage abuse.
    /// - Returns: The peers the server chose to share. May be empty.
    /// - Throws: `PeerSharingError.tooManyPeers` if the server returned more
    ///   peers than `amount`, or any `ProtocolError` on protocol violations.
    public func request(amount: UInt8) async throws -> [PeerAddress] {
        let driver = makeDriver()

        logger.debug("PeerSharing: requesting peers", metadata: ["amount": "\(amount)"])

        try await driver.send(.shareRequest(amount: amount)) { state in
            guard let s = state as? PeerSharingState else { return state }
            return try s.afterSend(.shareRequest(amount: amount))
        }

        let response = try await driver.receive { msg, state in
            guard let s = state as? PeerSharingState else { return state }
            return try s.afterReceive(msg)
        }

        guard case .sharePeers(let peers) = response else {
            throw ProtocolError.invalidTransition(
                protocol: "peerSharing",
                state: "busy",
                message: String(describing: response)
            )
        }

        guard peers.count <= Int(amount) else {
            logger.error("PeerSharing: server returned more peers than requested", metadata: [
                "requested": "\(amount)",
                "received":  "\(peers.count)"
            ])
            throw PeerSharingError.tooManyPeers(requested: amount, received: peers.count)
        }

        logger.info("PeerSharing: received peers", metadata: [
            "requested": "\(amount)",
            "received":  "\(peers.count)"
        ])

        CardanoMetrics
            .counter(CardanoMetrics.peerSharingRequestsTotal,
                     dimensions: [("network", "ntn"), ("result", "ok")])
            .increment()
        CardanoMetrics
            .counter(CardanoMetrics.peerSharingPeersReceivedTotal,
                     dimensions: [("network", "ntn")])
            .increment(by: peers.count)

        return peers
    }

    /// Send `MsgDone` to terminate the protocol cleanly.
    public func done() async throws {
        let driver = makeDriver()
        logger.debug("PeerSharing: sending done")
        try await driver.send(.done) { state in
            guard let s = state as? PeerSharingState else { return state }
            return try s.afterSend(.done)
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<PeerSharingCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.peerSharing)
        return ProtocolDriver(
            channel: channel,
            codec: PeerSharingCodec(),
            protocolID: MuxSDU.ProtocolID.peerSharing,
            initialState: PeerSharingState.idle,
            inboundStream: stream,
            protocolName: "peerSharing",
            logger: logger
        )
    }
}
