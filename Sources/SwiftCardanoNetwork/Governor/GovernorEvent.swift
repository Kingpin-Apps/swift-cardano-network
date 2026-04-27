/// External events the `OutboundGovernor` emits to the application.
///
/// The application consumes these via the governor's `events` async stream.
/// Some events (`peersRequested`) ask the application to take an action and
/// reply via a governor command; others are passive notifications.
public enum GovernorEvent: Sendable {
    /// A new peer has been added to the registry (either via `includePeer`
    /// or via a peer-sharing reply).
    case peerDiscovered(PeerID)

    /// The peer's NtN handshake has completed successfully.
    case peerConnected(PeerID, NegotiatedVersion)

    /// The peer was disconnected (clean close or error).
    case peerDisconnected(PeerID, reason: String?)

    /// The peer was banned. Banned peers are not re-promoted on rediscovery.
    case peerBanned(PeerID, reason: BanReason)

    /// The peer asked us for a peer-sharing reply (responder side, §3.11.6).
    /// The application picks the peer set and calls
    /// `OutboundGovernor.replyPeerShare(_:peers:)`.
    case peersRequested(PeerID, amount: UInt8)

    /// We received a peer-sharing reply from `from`. The governor adds the
    /// addresses to the discovered set automatically; this event is for the
    /// application's awareness only.
    case shareReplyReceived(from: PeerID, peers: [PeerAddress])
}

/// Reason a peer was moved to the banned set by `PromotionBehavior`.
public enum BanReason: Sendable, Equatable, CustomStringConvertible {
    /// The peer committed a wire-protocol violation.
    case violation
    /// The peer's `errorCount` exceeded `maxErrorCount`.
    case errorThreshold(observed: UInt32, limit: UInt32)
    /// Manual ban via `governor.banPeer(_:)`.
    case manual

    public var description: String {
        switch self {
        case .violation:
            return "violation"
        case .errorThreshold(let o, let l):
            return "errorThreshold(observed=\(o), limit=\(l))"
        case .manual:
            return "manual"
        }
    }
}
