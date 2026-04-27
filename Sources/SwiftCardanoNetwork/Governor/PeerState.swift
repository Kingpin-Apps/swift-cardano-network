import Foundation

/// All state the `OutboundGovernor` tracks for one peer, mirroring
/// `pallas-network2`'s `InitiatorState`.
///
/// `PeerState` is a value type. The governor mutates it via `inout` parameters
/// passed to `PeerVisitor` hooks and serialises mutation through actor
/// isolation. Each per-protocol state machine is the same value type already
/// used by the existing `XClient` types — there is no duplication.
public struct PeerState: @unchecked Sendable {

    // MARK: - Connection lifecycle

    public var connection:        ConnectionState
    public var promotion:         PromotionTag
    public var negotiatedVersion: NegotiatedVersion?

    // MARK: - Per-protocol state machines

    public var handshake:    HandshakeState
    public var keepAlive:    KeepAliveState
    public var peerSharing:  PeerSharingState
    public var chainSync:    ChainSyncState
    public var blockFetch:   BlockFetchState
    public var txSubmission: TxSubmission2State

    // MARK: - Governor bookkeeping

    /// Set when a peer commits a wire-protocol violation (illegal transition,
    /// codec error, oversize SDU, etc). The `PromotionBehavior` consumes this
    /// to trigger an immediate ban.
    public var violation: Bool

    /// Number of recoverable errors observed for this peer. `PromotionBehavior`
    /// bans the peer when `errorCount > maxErrorCount`.
    public var errorCount: UInt32

    /// Last time a message was observed from this peer, for diagnostic purposes.
    public var lastSeen: Date?

    /// The most recent un-drained `MsgSharePeers` response from this peer.
    ///
    /// Set by the governor's inbound-apply layer when a `sharePeers` message
    /// arrives; drained by `DiscoveryBehavior` and reset to `nil`. Mirrors
    /// `pallas-network2`'s `peersharing::State::Idle(Response(peers))` —
    /// our wire-codec layer does not carry the response inside the state
    /// machine, so we stash it here.
    public var peerSharingResponse: [PeerAddress]?

    /// Cookie counter used by `KeepAliveBehavior` to issue the next probe.
    /// Wraps at `UInt16.max`. Per-peer so cookies stay predictable in tests.
    public var keepAliveNextCookie: UInt16

    /// The cookie the local side most recently sent and is awaiting a
    /// response for. Set by `KeepAliveBehavior.housekeeping`; cleared by
    /// the governor's inbound-apply layer when a matching response arrives.
    public var keepAliveCookieInFlight: UInt16?

    /// A pending un-answered `MsgShareRequest` from the remote peer (§3.11.6).
    ///
    /// Set by the governor's inbound-apply layer when an inbound
    /// `MsgShareRequest(amount)` arrives. `PeerSharingResponderBehavior`
    /// consumes it on the next visitor pass, emits
    /// `GovernorEvent.peersRequested`, and clears the field — the
    /// application is then responsible for calling
    /// `OutboundGovernor.replyPeerShare(_:peers:)` to send `MsgSharePeers`.
    /// Mirrors the `amount` carried inside pallas's
    /// `peersharing::State::Busy(amount)`.
    public var inboundPeerSharingRequest: UInt8?

    /// The most recent `RefuseReason` carried by an inbound
    /// `MsgRefuse(reason)` during handshake. Set by the apply layer just
    /// before transitioning the handshake state machine; consumed by
    /// `HandshakeBehavior` to construct a typed `HandshakeRefusedError`
    /// rather than a generic sentinel.
    public var lastHandshakeRefusal: RefuseReason?

    // MARK: - Init

    public init(
        connection:        ConnectionState  = .new,
        promotion:         PromotionTag     = .cold,
        negotiatedVersion: NegotiatedVersion? = nil,
        handshake:         HandshakeState   = .start,
        keepAlive:         KeepAliveState   = .idle,
        peerSharing:       PeerSharingState = .idle,
        chainSync:         ChainSyncState   = .idle,
        blockFetch:        BlockFetchState  = .idle,
        txSubmission:      TxSubmission2State = .idle,
        violation:         Bool   = false,
        errorCount:        UInt32 = 0,
        lastSeen:          Date?  = nil,
        peerSharingResponse: [PeerAddress]? = nil,
        keepAliveNextCookie: UInt16 = 0,
        keepAliveCookieInFlight: UInt16? = nil,
        inboundPeerSharingRequest: UInt8? = nil,
        lastHandshakeRefusal: RefuseReason? = nil
    ) {
        self.connection                = connection
        self.promotion                 = promotion
        self.negotiatedVersion         = negotiatedVersion
        self.handshake                 = handshake
        self.keepAlive                 = keepAlive
        self.peerSharing               = peerSharing
        self.chainSync                 = chainSync
        self.blockFetch                = blockFetch
        self.txSubmission              = txSubmission
        self.violation                 = violation
        self.errorCount                = errorCount
        self.lastSeen                  = lastSeen
        self.peerSharingResponse       = peerSharingResponse
        self.keepAliveNextCookie       = keepAliveNextCookie
        self.keepAliveCookieInFlight   = keepAliveCookieInFlight
        self.inboundPeerSharingRequest = inboundPeerSharingRequest
        self.lastHandshakeRefusal      = lastHandshakeRefusal
    }
}

// MARK: - Reset

extension PeerState {
    /// Reinitialise transient per-connection state for a reconnect attempt.
    /// Preserves `promotion`, `errorCount`, `violation`, and `lastSeen` so
    /// reputation persists across connection cycles. The caller is
    /// responsible for setting `connection` (typically to `.disconnected`
    /// or `.new`).
    public mutating func resetForReconnect() {
        handshake                 = .start
        keepAlive                 = .idle
        peerSharing               = .idle
        chainSync                 = .idle
        blockFetch                = .idle
        txSubmission              = .idle
        negotiatedVersion         = nil
        peerSharingResponse       = nil
        keepAliveNextCookie       = 0
        keepAliveCookieInFlight   = nil
        inboundPeerSharingRequest = nil
        lastHandshakeRefusal      = nil
    }
}

// MARK: - Convenience predicates

extension PeerState {
    /// `true` when the handshake has completed and mini-protocols may run.
    public var isInitialized: Bool {
        if case .initialized = connection { return true }
        return false
    }

    /// `true` when the negotiated NtN version data carried `peerSharing == 1`,
    /// per §3.11.5.
    public var supportsPeerSharing: Bool {
        guard let neg = negotiatedVersion else { return false }
        guard neg.version >= NodeToNodeVersion.v14 else { return false }
        if case .nodeToNode(_, _, let flag, _) = neg.versionData, flag == 1 {
            return true
        }
        return false
    }
}
