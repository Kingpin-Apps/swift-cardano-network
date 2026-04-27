/// Configuration for `DiscoveryBehavior`.
public struct DiscoveryConfig: Sendable {
    /// The maximum number of peers to accumulate in the discovered pool
    /// before pausing further `MsgShareRequest` traffic. Each request asks
    /// for `(highWaterMark - discovered.count)` peers, so the high-water
    /// mark also bounds the per-request `amount`. The default of `100`
    /// matches `pallas-network2`.
    public var highWaterMark: UInt8

    public init(highWaterMark: UInt8 = 100) {
        self.highWaterMark = highWaterMark
    }
}

/// Sub-behavior that discovers new peers via the Peer-Sharing mini-protocol
/// (§3.11). Mirrors `pallas-network2`'s `DiscoveryBehavior`.
///
/// On each housekeeping tick, for any peer that has completed the handshake
/// with `peerSharing == 1` and whose local peer-sharing state machine is in
/// `idle` with no pending response, the visitor emits an outbound
/// `MsgShareRequest(amount)`. On inbound `MsgSharePeers`, the visitor drains
/// the response from `PeerState.peerSharingResponse`, adds the addresses to
/// its discovered pool, and transitions the peer's local peer-sharing state
/// to `.done` so the same peer is not re-requested.
///
/// Use `drainNewPeers(_:)` to take peers out for connecting.
public struct DiscoveryBehavior: PeerVisitor {

    public var config: DiscoveryConfig

    /// Pool of peers we have learned about and are willing to expose to a
    /// downstream connection-management layer (e.g. `PromotionBehavior`).
    public private(set) var discovered: Set<PeerID>

    public init(config: DiscoveryConfig = .init()) {
        self.config = config
        self.discovered = []
    }

    // MARK: - Internal predicates

    private func peerIsAvailable(_ state: PeerState) -> Bool {
        return state.isInitialized
            && state.supportsPeerSharing
            && state.peerSharing == .idle
            && state.peerSharingResponse == nil
    }

    private var needsMorePeers: Bool {
        discovered.count < Int(config.highWaterMark)
    }

    // MARK: - Public API

    /// Drain up to `count` peers from the internal pool, removing them.
    public mutating func drainNewPeers(_ count: Int) -> Set<PeerID> {
        guard count > 0, !discovered.isEmpty else { return [] }
        let take = discovered.prefix(count)
        let selected = Set(take)
        discovered.subtract(selected)
        return selected
    }

    /// Drain a stashed `MsgSharePeers` response from `state` into the pool.
    /// Transitions the peer's local peer-sharing state machine to `.done`
    /// so the same peer is not re-requested later.
    ///
    /// Public so the `OutboundGovernor` can call it from `applyInbound`
    /// before the visitor pass; otherwise visitors would race on the same
    /// `peerSharingResponse` slot if multiple visitors care about it.
    public mutating func tryTakePeers(_ state: inout PeerState) {
        guard let peers = state.peerSharingResponse else { return }
        for addr in peers {
            discovered.insert(PeerID(addr))
        }
        state.peerSharingResponse = nil
        state.peerSharing = .done
    }

    // MARK: - PeerVisitor

    public mutating func housekeeping(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        guard needsMorePeers else { return }
        guard peerIsAvailable(state) else { return }

        let deficit = Int(config.highWaterMark) - discovered.count
        let amount = UInt8(min(deficit, Int(UInt8.max)))
        outbound.push(.send(pid, .peerSharing(.shareRequest(amount: amount))))
    }

    public mutating func inboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        guard state.supportsPeerSharing else { return }
        tryTakePeers(&state)
    }
}
