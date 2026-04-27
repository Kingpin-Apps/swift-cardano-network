/// Sub-behavior that handles **inbound** Peer-Sharing requests on outbound
/// connections (§3.11.6). Mirrors `pallas-network2`'s `PeerSharingResponder`.
///
/// `swift-cardano-network` does not accept incoming TCP connections, but
/// peer-sharing is bidirectional once both sides advertise willingness.
/// When a remote peer sends `MsgShareRequest` to us on a connection we
/// initiated, the governor's inbound-apply layer stashes the requested
/// amount in `state.inboundPeerSharingRequest`. This visitor consumes
/// that field on the next visitor pass and emits
/// `GovernorEvent.peersRequested(pid, amount)`.
///
/// The application is responsible for replying — typically by calling
/// `OutboundGovernor.replyPeerShare(_:peers:)` — which sends
/// `MsgSharePeers(peers)` back to the remote and transitions the local
/// peer-sharing state machine. This visitor does **not** call back into
/// the network itself; it just surfaces the request as an external event.
public struct PeerSharingResponderBehavior: PeerVisitor {

    /// Total inbound `MsgShareRequest`s observed (lifetime). Useful for
    /// tests and observability — pallas uses an OpenTelemetry counter; we
    /// expose a plain integer so callers can wire whatever metric backend
    /// they prefer.
    public private(set) var requestsHandled: Int = 0

    public init() {}

    // MARK: - PeerVisitor

    public mutating func inboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        guard state.isInitialized else { return }
        guard let amount = state.inboundPeerSharingRequest else { return }

        outbound.push(.peersRequested(pid, amount: amount))
        state.inboundPeerSharingRequest = nil
        requestsHandled += 1
        CardanoMetrics
            .counter(CardanoMetrics.peerSharingResponderRequestsTotal)
            .increment()
    }
}
