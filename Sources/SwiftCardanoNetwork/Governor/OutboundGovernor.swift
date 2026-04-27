import Foundation

/// Multi-peer outbound governor.
///
/// `OutboundGovernor` is the §3.11.5-style controller that sits above the
/// per-protocol clients. It tracks `[PeerID: PeerState]` for every peer the
/// application has registered, drives Cold→Warm→Hot transitions through the
/// configured `PromotionConfig`, runs peer-sharing requests via
/// `DiscoveryBehavior`, manages handshake + keepalive lifecycles, and emits
/// connect/disconnect commands through a pluggable `Interface`.
///
/// The governor is **additive**: the existing `CardanoNode.connectToNode`
/// facade remains the right tool for single-peer flows. Use the governor
/// when you need to hold many peers concurrently and reason about peer
/// quality across the set.
///
/// ## Usage
///
/// ```swift
/// let interface = NIOInterface(...)            // or EmulatedInterface in tests
/// let governor = OutboundGovernor(
///     interface: interface,
///     handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073)
/// )
/// await governor.start()
///
/// for seed in seedPeers { await governor.includePeer(seed) }
///
/// Task.detached {
///     while !Task.isCancelled {
///         try? await Task.sleep(nanoseconds: 60_000_000_000)
///         await governor.housekeeping()
///     }
/// }
///
/// for await event in governor.events {
///     // ... react to peer lifecycle ...
/// }
/// ```
///
/// ## Architectural notes (vs. pallas-network2)
///
/// - The governor is an `actor`, so external mutations (`includePeer`,
///   `banPeer`, etc.) and Interface event consumption are serialised
///   without explicit locking. Pallas's `Manager` impls `Stream`; we expose
///   `events: AsyncStream<GovernorEvent>` instead.
/// - Sub-behaviors are stored as concrete properties (not `[any
///   PeerVisitor]`) to avoid existential-mutation friction in Swift 6.
/// - The visitor pipeline order — Handshake → KeepAlive →
///   PeerSharingResponder → Discovery → Promotion → Connection — is fixed.
/// - Inbound `MsgShareRequest` (responder side) is recorded in
///   `state.inboundPeerSharingRequest` instead of being applied to the
///   shared `PeerSharingState` machine so it cannot collide with our own
///   outbound requests.
public actor OutboundGovernor {

    // MARK: - State

    private var peers: [PeerID: PeerState] = [:]
    private let interface: any Interface

    // Sub-behaviors (concrete to dodge existential `mutating` friction)
    private var handshakeBehavior:    HandshakeBehavior
    private var keepAliveBehavior:    KeepAliveBehavior
    private var peerSharingResponder: PeerSharingResponderBehavior
    private var discoveryBehavior:    DiscoveryBehavior
    private var promotionBehavior:    PromotionBehavior
    private var connectionBehavior:   ConnectionBehavior

    private var outboundQueue = OutboundQueue()
    private let eventsContinuation: AsyncStream<GovernorEvent>.Continuation

    /// Public stream of governor events. Consume from a single task — the
    /// stream's continuation is shared across the whole governor lifetime.
    public nonisolated let events: AsyncStream<GovernorEvent>

    private var eventLoopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        interface: any Interface,
        handshakeConfig: HandshakeBehaviorConfig,
        discoveryConfig: DiscoveryConfig = .init(),
        promotionConfig: PromotionConfig = .init()
    ) {
        self.interface = interface
        self.handshakeBehavior    = HandshakeBehavior(config: handshakeConfig)
        self.keepAliveBehavior    = KeepAliveBehavior()
        self.peerSharingResponder = PeerSharingResponderBehavior()
        self.discoveryBehavior    = DiscoveryBehavior(config: discoveryConfig)
        self.promotionBehavior    = PromotionBehavior(config: promotionConfig)
        self.connectionBehavior   = ConnectionBehavior()

        var captured: AsyncStream<GovernorEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.eventsContinuation = captured
    }

    // MARK: - Lifecycle

    /// Start the inbound-event consumer. Idempotent.
    public func start() {
        guard eventLoopTask == nil else { return }
        eventLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runInboundLoop()
        }
    }

    /// Stop the inbound-event consumer and finish the public events stream.
    public func stop() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        eventsContinuation.finish()
    }

    private func runInboundLoop() async {
        for await event in interface.events {
            await handleInterfaceEvent(event)
        }
    }

    // MARK: - Public API

    /// Register a peer with the governor. If unknown, it enters the
    /// registry as `.cold/.new` and `PromotionBehavior` may promote it on
    /// the next housekeeping tick. If banned, it stays banned.
    public func includePeer(_ pid: PeerID) async {
        if peers[pid] == nil {
            peers[pid] = PeerState()
        }
        runVisitorsForPeer(pid) { v, state, queue in
            v.discovered(pid, &state, &queue)
        }
        await flushOutbound()
    }

    /// Remove a peer from the registry. Issues a disconnect if currently
    /// connected. The peer's `errorCount` is dropped; subsequent
    /// `includePeer` will start fresh.
    public func excludePeer(_ pid: PeerID) async {
        if peers[pid] != nil {
            await interface.dispatch(.disconnect(pid))
            peers.removeValue(forKey: pid)
        }
    }

    /// Manually ban a peer. The peer will be disconnected and never
    /// re-promoted on rediscovery.
    public func banPeer(_ pid: PeerID) async {
        guard var state = peers[pid] else { return }
        promotionBehavior.banPeer(pid, &state)
        peers[pid] = state
        outboundQueue.push(.peerBanned(pid, reason: .manual))
        CardanoMetrics
            .counter(
                CardanoMetrics.governorPeersBannedTotal,
                dimensions: [(CardanoMetrics.Dimension.reason, "manual")]
            )
            .increment()
        runVisitorsForPeer(pid) { v, st, q in v.tagged(pid, &st, &q) }
        await flushOutbound()
    }

    /// Demote a peer back to cold. No-op if banned.
    public func demotePeer(_ pid: PeerID) async {
        guard var state = peers[pid] else { return }
        promotionBehavior.demotePeer(pid, &state)
        peers[pid] = state
        runVisitorsForPeer(pid) { v, st, q in v.tagged(pid, &st, &q) }
        await flushOutbound()
    }

    /// Application's response to a `peersRequested` event. Sends
    /// `MsgSharePeers(peers)` on the responder side of the peer-sharing
    /// mini-protocol. No-op if the peer is unknown.
    public func replyPeerShare(_ pid: PeerID, peers: [PeerAddress]) async {
        guard self.peers[pid] != nil else { return }
        outboundQueue.push(.send(pid, .peerSharing(.sharePeers(peers))))
        await flushOutbound()
    }

    /// Run a single housekeeping pass over every tracked peer. The
    /// application is expected to call this periodically — there is no
    /// internal timer.
    public func housekeeping() async {
        for pid in peers.keys {
            runVisitorsForPeer(pid) { v, state, queue in
                v.housekeeping(pid, &state, &queue)
            }
        }
        await flushOutbound()
    }

    /// Snapshot of the entire peer registry. Useful for tests and dashboards.
    public func peerSnapshot() -> [PeerID: PeerState] { peers }

    /// Number of peers currently in the cold/warm/hot/banned sets.
    public func promotionCounts() -> (cold: Int, warm: Int, hot: Int, banned: Int) {
        (
            promotionBehavior.coldPeers.count,
            promotionBehavior.warmPeers.count,
            promotionBehavior.hotPeers.count,
            promotionBehavior.bannedPeers.count
        )
    }

    /// Snapshot of the peer-sharing discovery pool — peers we have learned
    /// about via `MsgSharePeers` and not yet drained for connection.
    public func discoveredPeers() -> Set<PeerID> {
        discoveryBehavior.discovered
    }

    // MARK: - Visitor invocation

    /// Run a hook on every visitor for one peer, in the canonical order:
    /// Handshake → KeepAlive → PeerSharingResponder → Discovery → Promotion
    /// → Connection. Visitors share the governor's `outboundQueue`.
    private func runVisitorsForPeer(
        _ pid: PeerID,
        _ hook: (inout any PeerVisitor, inout PeerState, inout OutboundQueue) -> Void
    ) {
        guard var state = peers[pid] else { return }

        var v1: any PeerVisitor = handshakeBehavior
        hook(&v1, &state, &outboundQueue)
        handshakeBehavior = v1 as! HandshakeBehavior

        var v2: any PeerVisitor = keepAliveBehavior
        hook(&v2, &state, &outboundQueue)
        keepAliveBehavior = v2 as! KeepAliveBehavior

        var v3: any PeerVisitor = peerSharingResponder
        hook(&v3, &state, &outboundQueue)
        peerSharingResponder = v3 as! PeerSharingResponderBehavior

        var v4: any PeerVisitor = discoveryBehavior
        hook(&v4, &state, &outboundQueue)
        discoveryBehavior = v4 as! DiscoveryBehavior

        var v5: any PeerVisitor = promotionBehavior
        hook(&v5, &state, &outboundQueue)
        promotionBehavior = v5 as! PromotionBehavior

        var v6: any PeerVisitor = connectionBehavior
        hook(&v6, &state, &outboundQueue)
        connectionBehavior = v6 as! ConnectionBehavior

        peers[pid] = state
    }

    // MARK: - Interface events

    private func handleInterfaceEvent(_ event: InterfaceEvent) async {
        switch event {
        case .connected(let pid):
            guard var state = peers[pid] else { return }
            state.connection = .connected
            peers[pid] = state
            runVisitorsForPeer(pid) { v, s, q in v.connected(pid, &s, &q) }

        case .initialized(let pid, let neg):
            // Defensive: if the interface auto-handshakes (it shouldn't), let
            // the governor reflect that.
            guard var state = peers[pid] else { return }
            state.connection = .initialized
            state.negotiatedVersion = neg
            state.handshake = .accepted
            peers[pid] = state

        case .messageReceived(let pid, let msg):
            applyInbound(pid, msg)
            runVisitorsForPeer(pid) { v, s, q in v.inboundMessage(pid, &s, &q) }

        case .errored(let pid, let err):
            guard var state = peers[pid] else { return }
            state.connection = .errored(err)
            peers[pid] = state
            runVisitorsForPeer(pid) { v, s, q in v.errored(pid, &s, &q) }

        case .disconnected(let pid):
            guard var state = peers[pid] else { return }
            state.connection = .disconnected
            state.resetForReconnect()
            peers[pid] = state
            runVisitorsForPeer(pid) { v, s, q in v.disconnected(pid, &s, &q) }
            outboundQueue.push(.peerDisconnected(pid, reason: nil))
        }

        await flushOutbound()
    }

    // MARK: - Apply layer (inbound)

    /// Advance the appropriate per-protocol state machine and populate the
    /// bookkeeping fields visitors expect to see.
    private func applyInbound(_ pid: PeerID, _ message: AnyMiniProtocolMessage) {
        guard var state = peers[pid] else { return }
        state.lastSeen = Date()

        switch message {
        case .handshake(let m):
            applyInboundHandshake(m, state: &state)
        case .keepAlive(let m):
            applyInboundKeepAlive(m, state: &state)
        case .peerSharing(let m):
            applyInboundPeerSharing(m, state: &state)
        case .chainSync(let m):
            do { state.chainSync = try state.chainSync.afterReceive(m) }
            catch { state.violation = true }
        case .blockFetch(let m):
            do { state.blockFetch = try state.blockFetch.afterReceive(m) }
            catch { state.violation = true }
        case .txSubmission2(let m):
            do { state.txSubmission = try state.txSubmission.afterReceive(m) }
            catch { state.violation = true }
        }

        peers[pid] = state
    }

    private func applyInboundHandshake(_ m: HandshakeMessage, state: inout PeerState) {
        // Capture the reason BEFORE advancing the state machine so
        // `HandshakeBehavior.inboundMessage` can read it in the same pass.
        if case .refuse(let reason) = m {
            state.lastHandshakeRefusal = reason
        }
        do {
            state.handshake = try state.handshake.afterReceive(m)
            if case .acceptVersion(let v, let vd) = m {
                state.negotiatedVersion = NegotiatedVersion(version: v, versionData: vd)
            }
        } catch {
            state.violation = true
        }
    }

    private func applyInboundKeepAlive(_ m: KeepAliveMessage, state: inout PeerState) {
        do {
            state.keepAlive = try state.keepAlive.afterReceive(m)
            if case .keepAliveResponse(let cookie) = m {
                if let inFlight = state.keepAliveCookieInFlight {
                    if cookie != inFlight {
                        state.violation = true
                    } else {
                        state.keepAliveCookieInFlight = nil
                    }
                }
            }
        } catch {
            state.violation = true
        }
    }

    private func applyInboundPeerSharing(_ m: PeerSharingMessage, state: inout PeerState) {
        switch m {
        case .shareRequest(let amount):
            // Responder side: the remote is asking us. Stash the amount; do
            // NOT advance our local (initiator) state machine.
            state.inboundPeerSharingRequest = amount
        case .sharePeers(let peers):
            do {
                state.peerSharing = try state.peerSharing.afterReceive(m)
                state.peerSharingResponse = peers
            } catch {
                state.violation = true
            }
        case .done:
            do {
                state.peerSharing = try state.peerSharing.afterReceive(m)
            } catch {
                state.violation = true
            }
        }
    }

    // MARK: - Apply layer (outbound)

    /// Advance the appropriate state machine for an outbound message.
    /// Called by `flushOutbound` before dispatching each `.send` command.
    private func applyOutbound(_ pid: PeerID, _ message: AnyMiniProtocolMessage) {
        guard var state = peers[pid] else { return }

        switch message {
        case .handshake(let m):
            do { state.handshake = try state.handshake.afterSend(m) }
            catch { state.violation = true }

        case .keepAlive(let m):
            do { state.keepAlive = try state.keepAlive.afterSend(m) }
            catch { state.violation = true }

        case .peerSharing(let m):
            switch m {
            case .sharePeers:
                // Responder reply — we're answering a remote request, so
                // we do NOT advance our own initiator state machine.
                break
            default:
                do { state.peerSharing = try state.peerSharing.afterSend(m) }
                catch { state.violation = true }
            }

        case .chainSync(let m):
            do { state.chainSync = try state.chainSync.afterSend(m) }
            catch { state.violation = true }

        case .blockFetch(let m):
            do { state.blockFetch = try state.blockFetch.afterSend(m) }
            catch { state.violation = true }

        case .txSubmission2(let m):
            do { state.txSubmission = try state.txSubmission.afterSend(m) }
            catch { state.violation = true }
        }

        peers[pid] = state
    }

    // MARK: - Outbound flush

    /// Drain the outbound queue, dispatching commands to the Interface and
    /// yielding events on the public stream. For each `.send` command we
    /// `applyOutbound` first so the peer's state machine reflects the
    /// transmission. Visitors invoked during `applyOutbound`'s
    /// `outboundMessage` hook may push additional items, so we loop until
    /// the queue is empty.
    private func flushOutbound() async {
        while !outboundQueue.isEmpty {
            let items = outboundQueue.drain()
            for item in items {
                switch item {
                case .command(let cmd):
                    if case .send(let pid, let msg) = cmd {
                        applyOutbound(pid, msg)
                        runVisitorsForPeer(pid) { v, s, q in
                            v.outboundMessage(pid, &s, &q)
                        }
                    }
                    await interface.dispatch(cmd)
                case .event(let event):
                    eventsContinuation.yield(event)
                }
            }
        }
    }
}
