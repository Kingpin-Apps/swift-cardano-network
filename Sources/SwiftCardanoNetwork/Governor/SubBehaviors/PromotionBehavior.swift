/// Configuration for `PromotionBehavior`.
public struct PromotionConfig: Sendable {
    /// Maximum total tracked peers (cold + warm + hot).
    public var maxPeers: Int
    /// Maximum number of warm peers (connected, handshake done, basic protocols).
    public var maxWarmPeers: Int
    /// Maximum number of hot peers (fully active, all wired protocols).
    public var maxHotPeers: Int
    /// Threshold above which `errorCount` triggers a ban — banning fires
    /// when `state.errorCount > maxErrorCount` (strictly greater than).
    public var maxErrorCount: UInt32

    public init(
        maxPeers: Int = 100,
        maxWarmPeers: Int = 50,
        maxHotPeers: Int = 10,
        maxErrorCount: UInt32 = 1
    ) {
        self.maxPeers = maxPeers
        self.maxWarmPeers = maxWarmPeers
        self.maxHotPeers = maxHotPeers
        self.maxErrorCount = maxErrorCount
    }
}

/// Sub-behavior that manages peer promotion between cold, warm, hot, and
/// banned states. Mirrors `pallas-network2`'s `PromotionBehavior`.
///
/// On `discovered`, a peer enters the cold set if room remains under
/// `maxPeers` (or is rejected outright if banned).
///
/// On every `housekeeping` tick and `inboundMessage`, `categorizePeer`
/// re-evaluates each peer in this order:
/// 1. If `state.violation` is set → ban
/// 2. If `state.errorCount > maxErrorCount` → ban
/// 3. If room in warm and peer is in cold → promote cold→warm
/// 4. If room in hot, peer is in warm and `state.isInitialized` → promote
///    warm→hot
///
/// Banning is permanent — banned peers are not re-promoted on rediscovery
/// and `demotePeer` is a no-op once banned.
public struct PromotionBehavior: PeerVisitor {

    public var config: PromotionConfig

    /// Known but not connected.
    public private(set) var coldPeers:   Set<PeerID> = []
    /// Connected, handshake done; basic protocols only.
    public private(set) var warmPeers:   Set<PeerID> = []
    /// Fully active; all wired mini-protocols.
    public private(set) var hotPeers:    Set<PeerID> = []
    /// Banned — never connected, never re-discovered.
    public private(set) var bannedPeers: Set<PeerID> = []

    public init(config: PromotionConfig = .init()) {
        self.config = config
    }

    // MARK: - Counts and deficits

    /// Total tracked peers (cold + warm + hot). Banned peers are excluded.
    public var totalPeers: Int {
        coldPeers.count + warmPeers.count + hotPeers.count
    }

    /// How many more peers can still be tracked before reaching `maxPeers`.
    public var peerDeficit: Int {
        max(0, config.maxPeers - totalPeers)
    }

    private var requiredColdPeers: Int { peerDeficit }
    private var requiredWarmPeers: Int { max(0, config.maxWarmPeers - warmPeers.count) }
    private var requiredHotPeers:  Int { max(0, config.maxHotPeers  - hotPeers.count)  }

    // MARK: - Public mutations

    /// Add a newly-discovered peer to the cold set if capacity remains and
    /// the peer is not banned.
    public mutating func onPeerDiscovered(_ pid: PeerID, _ state: inout PeerState) {
        if bannedPeers.contains(pid) { return }
        guard requiredColdPeers > 0 else { return }
        coldPeers.insert(pid)
        state.promotion = .cold
    }

    /// Ban a peer permanently. Removes from cold/warm/hot.
    public mutating func banPeer(_ pid: PeerID, _ state: inout PeerState) {
        coldPeers.remove(pid)
        warmPeers.remove(pid)
        hotPeers.remove(pid)
        bannedPeers.insert(pid)
        state.promotion = .banned
        recordGaugeSnapshot()
    }

    /// Demote a peer back to cold (no-op if banned).
    public mutating func demotePeer(_ pid: PeerID, _ state: inout PeerState) {
        if bannedPeers.contains(pid) { return }
        warmPeers.remove(pid)
        hotPeers.remove(pid)
        coldPeers.insert(pid)
        state.promotion = .cold
        CardanoMetrics
            .counter(CardanoMetrics.governorPeersDemotedTotal)
            .increment()
        recordGaugeSnapshot()
    }

    // MARK: - Internal promotions

    private mutating func promoteColdPeer(_ pid: PeerID, _ state: inout PeerState) {
        guard coldPeers.remove(pid) != nil else { return }
        warmPeers.insert(pid)
        state.promotion = .warm
        CardanoMetrics
            .counter(
                CardanoMetrics.governorPeersPromotedTotal,
                dimensions: [(CardanoMetrics.Dimension.transition, "cold_to_warm")]
            )
            .increment()
        recordGaugeSnapshot()
    }

    private mutating func promoteWarmPeer(_ pid: PeerID, _ state: inout PeerState) {
        guard warmPeers.remove(pid) != nil else { return }
        hotPeers.insert(pid)
        state.promotion = .hot
        CardanoMetrics
            .counter(
                CardanoMetrics.governorPeersPromotedTotal,
                dimensions: [(CardanoMetrics.Dimension.transition, "warm_to_hot")]
            )
            .increment()
        recordGaugeSnapshot()
    }

    /// Push the current set sizes onto the corresponding gauges. Called on
    /// every membership change so dashboards reflect a live view.
    private func recordGaugeSnapshot() {
        CardanoMetrics.gauge(CardanoMetrics.governorPeersCold).record(coldPeers.count)
        CardanoMetrics.gauge(CardanoMetrics.governorPeersWarm).record(warmPeers.count)
        CardanoMetrics.gauge(CardanoMetrics.governorPeersHot).record(hotPeers.count)
        CardanoMetrics.gauge(CardanoMetrics.governorPeersBanned).record(bannedPeers.count)
    }

    /// Single-pass re-categorisation, used by `housekeeping` and
    /// `inboundMessage`. Mirrors pallas's `categorize_peer`.
    private mutating func categorizePeer(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        if state.violation, !bannedPeers.contains(pid) {
            banPeer(pid, &state)
            outbound.push(.peerBanned(pid, reason: .violation))
            CardanoMetrics
                .counter(
                    CardanoMetrics.governorPeersBannedTotal,
                    dimensions: [(CardanoMetrics.Dimension.reason, "violation")]
                )
                .increment()
            return
        }
        if state.errorCount > config.maxErrorCount, !bannedPeers.contains(pid) {
            let observed = state.errorCount
            let limit = config.maxErrorCount
            banPeer(pid, &state)
            outbound.push(.peerBanned(pid, reason: .errorThreshold(observed: observed, limit: limit)))
            CardanoMetrics
                .counter(
                    CardanoMetrics.governorPeersBannedTotal,
                    dimensions: [(CardanoMetrics.Dimension.reason, "error_threshold")]
                )
                .increment()
            return
        }
        if requiredWarmPeers > 0, coldPeers.contains(pid) {
            promoteColdPeer(pid, &state)
            return
        }
        if requiredHotPeers > 0, warmPeers.contains(pid), state.isInitialized {
            promoteWarmPeer(pid, &state)
        }
    }

    // MARK: - PeerVisitor

    public mutating func discovered(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        onPeerDiscovered(pid, &state)
    }

    public mutating func housekeeping(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        categorizePeer(pid, &state, &outbound)
    }

    public mutating func inboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        categorizePeer(pid, &state, &outbound)
    }
}
