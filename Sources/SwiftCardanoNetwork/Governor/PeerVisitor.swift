/// A pluggable hook chain that the `OutboundGovernor` invokes at every peer
/// lifecycle transition. Mirrors `pallas-network2`'s `PeerVisitor` trait.
///
/// Each sub-behavior (`DiscoveryBehavior`, `PromotionBehavior`,
/// `ConnectionBehavior`, etc.) is a `PeerVisitor`. The governor holds an
/// ordered array of visitors and, after each event, walks the array calling
/// the corresponding hook on each visitor. Visitors mutate `PeerState` via
/// `inout` and emit commands or events via `OutboundQueue`.
///
/// All hooks have no-op default implementations so concrete visitors only
/// override the ones they care about.
public protocol PeerVisitor: Sendable {

    /// A new peer has just been added to the registry.
    mutating func discovered(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// The TCP connection to the peer has been established (handshake not yet
    /// complete).
    mutating func connected(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// The peer has been disconnected.
    mutating func disconnected(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// An error occurred on the peer's connection.
    mutating func errored(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// A message was received from the peer. The peer's protocol state
    /// machines have already been advanced before this hook fires.
    mutating func inboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// A message has been pushed onto the outbound queue for the peer.
    /// (Visitors rarely override this; useful for instrumentation.)
    mutating func outboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// Periodic housekeeping tick. Called for each tracked peer when the
    /// application invokes `OutboundGovernor.housekeeping()`.
    mutating func housekeeping(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )

    /// The peer's state was modified by an external tag mutation (e.g. manual
    /// `banPeer`, `demotePeer`).
    mutating func tagged(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    )
}

// MARK: - Default no-op implementations

extension PeerVisitor {
    public mutating func discovered(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func connected(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func disconnected(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func errored(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func inboundMessage(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func outboundMessage(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func housekeeping(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
    public mutating func tagged(_: PeerID, _: inout PeerState, _: inout OutboundQueue) {}
}
