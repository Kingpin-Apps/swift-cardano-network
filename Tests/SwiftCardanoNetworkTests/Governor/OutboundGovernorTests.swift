import Foundation
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private func pid(_ i: Int) -> PeerID {
    PeerID(host: "10.0.0.\(i)", port: 3001)
}

private func makeGovernor(
    discovery: DiscoveryConfig = .init(),
    promotion: PromotionConfig = .init()
) -> (OutboundGovernor, EmulatedInterface) {
    let iface = EmulatedInterface()
    let g = OutboundGovernor(
        interface: iface,
        handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
        discoveryConfig: discovery,
        promotionConfig: promotion
    )
    return (g, iface)
}

private func acceptVersionVD() -> NegotiatedVersion {
    NegotiatedVersion(
        version: NodeToNodeVersion.v14,
        versionData: .nodeToNode(networkMagic: 764_824_073, initiatorOnly: false, peerSharing: 1, query: false)
    )
}

private func acceptVersionMessage() -> AnyMiniProtocolMessage {
    .handshake(.acceptVersion(NodeToNodeVersion.v14, .nodeToNode(
        networkMagic: 764_824_073, initiatorOnly: false, peerSharing: 1, query: false
    )))
}

// MARK: - Registration

@Suite("OutboundGovernor — registration") struct OutboundGovernorRegistrationTests {

    @Test func includePeerAddsToRegistryAsCold() async {
        let (g, _) = makeGovernor()
        await g.includePeer(pid(1))
        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)] != nil)
        #expect(snapshot[pid(1)]?.promotion == .cold)
        let counts = await g.promotionCounts()
        #expect(counts.cold == 1)
        #expect(counts.warm == 0)
        #expect(counts.hot == 0)
    }

    @Test func excludePeerRemovesAndDispatchesDisconnect() async {
        let (g, iface) = makeGovernor()
        await g.includePeer(pid(1))
        await g.excludePeer(pid(1))
        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)] == nil)

        let cmds = iface.drainCommands()
        let hasDisconnect = cmds.contains { if case .disconnect(let p) = $0, p == pid(1) { return true } else { return false } }
        #expect(hasDisconnect)
    }

    @Test func banPeerRemovesFromAllSetsAndEmitsEvent() async {
        let (g, _) = makeGovernor()
        await g.includePeer(pid(1))

        let collector = Task<[GovernorEvent], Never> {
            var events: [GovernorEvent] = []
            for await e in g.events {
                events.append(e)
                if events.count >= 1 { break }
            }
            return events
        }
        await Task.yield()

        await g.banPeer(pid(1))
        let events = await collector.value

        let counts = await g.promotionCounts()
        #expect(counts.banned == 1)
        #expect(counts.cold == 0)

        guard case .peerBanned(let bp, let reason) = events[0] else {
            Issue.record("expected .peerBanned"); return
        }
        #expect(bp == pid(1))
        #expect(reason == .manual)
    }
}

// MARK: - Housekeeping → connect

@Suite("OutboundGovernor — housekeeping promotes and dispatches connect") struct OutboundGovernorConnectTests {

    @Test func warmPeerGetsConnectCommand() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 0))
        await g.includePeer(pid(1))   // cold
        await g.housekeeping()        // promote cold → warm; ConnectionBehavior emits connect

        let counts = await g.promotionCounts()
        #expect(counts.warm == 1)
        #expect(counts.cold == 0)

        let cmds = iface.drainCommands()
        let connect = cmds.first { if case .connect = $0 { return true } else { return false } }
        #expect(connect != nil)
    }
}

// MARK: - Handshake flow

@Suite("OutboundGovernor — handshake flow") struct OutboundGovernorHandshakeTests {

    @Test func connectedEventTriggersProposeVersions() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5))
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        _ = iface.drainCommands()  // discard the connect

        // Simulate the interface reporting TCP up
        iface.emit(.connected(pid(1)))
        // Yield to let the actor process the event
        try? await Task.sleep(nanoseconds: 50_000_000)

        let cmds = iface.drainCommands()
        let proposeSent = cmds.contains { item in
            if case .send(_, .handshake(.proposeVersions)) = item { return true }
            return false
        }
        #expect(proposeSent)

        let snapshot = await g.peerSnapshot()
        if case .connected = snapshot[pid(1)]?.connection { /* ok */ } else {
            Issue.record("expected .connected, got \(String(describing: snapshot[pid(1)]?.connection))")
        }
        // The handshake state machine should have advanced from .start to .proposed via applyOutbound
        #expect(snapshot[pid(1)]?.handshake == .proposed)

        await g.stop()
    }

    @Test func acceptVersionPromotesToInitializedAndEmitsPeerConnected() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5))
        await g.start()

        let collector = Task<GovernorEvent?, Never> {
            for await e in g.events {
                if case .peerConnected = e { return e }
            }
            return nil
        }

        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)

        let snapshot = await g.peerSnapshot()
        if case .initialized = snapshot[pid(1)]?.connection { /* ok */ } else {
            Issue.record("expected .initialized, got \(String(describing: snapshot[pid(1)]?.connection))")
        }
        #expect(snapshot[pid(1)]?.handshake == .accepted)
        #expect(snapshot[pid(1)]?.negotiatedVersion?.version == NodeToNodeVersion.v14)

        // Drain the peerConnected event without leaving the consumer task hanging.
        iface.finish()
        await g.stop()
        let event = await collector.value
        guard case .peerConnected(let p, let v) = event else {
            Issue.record("expected .peerConnected"); return
        }
        #expect(p == pid(1))
        #expect(v.version == NodeToNodeVersion.v14)
    }
}

// MARK: - KeepAlive flow

@Suite("OutboundGovernor — keepalive flow") struct OutboundGovernorKeepAliveTests {

    @Test func housekeepingEmitsProbeOnceInitialized() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = iface.drainCommands()   // discard handshake traffic

        await g.housekeeping()      // KeepAliveBehavior should emit a probe now
        let cmds = iface.drainCommands()

        let probeFound = cmds.contains { item in
            if case .send(_, .keepAlive(.keepAlive(let cookie))) = item, cookie == 0 { return true }
            return false
        }
        #expect(probeFound)

        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.keepAliveCookieInFlight == 0)
        #expect(snapshot[pid(1)]?.keepAlive == .busy)
        await g.stop()
    }

    @Test func matchingResponseClearsInFlightCookie() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await g.housekeeping()      // emits cookie=0
        try? await Task.sleep(nanoseconds: 30_000_000)

        iface.emit(.messageReceived(pid(1), .keepAlive(.keepAliveResponse(cookie: 0))))
        try? await Task.sleep(nanoseconds: 30_000_000)

        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.keepAliveCookieInFlight == nil)
        #expect(snapshot[pid(1)]?.keepAlive == .idle)
        #expect(snapshot[pid(1)]?.violation == false)
        await g.stop()
    }

    @Test func cookieMismatchFlagsViolation() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await g.housekeeping()      // sent cookie=0
        try? await Task.sleep(nanoseconds: 30_000_000)

        iface.emit(.messageReceived(pid(1), .keepAlive(.keepAliveResponse(cookie: 999))))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.violation == true)

        // PromotionBehavior should ban on the next housekeeping tick.
        await g.housekeeping()
        let counts = await g.promotionCounts()
        #expect(counts.banned == 1)
        await g.stop()
    }
}

// MARK: - PeerSharing flows

@Suite("OutboundGovernor — peer-sharing initiator") struct OutboundGovernorPeerSharingInitiatorTests {

    @Test func discoveryDrainsResponseAndAddsToPool() async {
        let (g, iface) = makeGovernor(
            discovery: DiscoveryConfig(highWaterMark: 50),
            promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5)
        )
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Driver emits MsgShareRequest on the next housekeeping
        await g.housekeeping()
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Server replies with sharePeers
        let peers: [PeerAddress] = [
            .ipv4(addr: 0x0A00_0011, port: 3001),
            .ipv4(addr: 0x0A00_0012, port: 3001),
        ]
        iface.emit(.messageReceived(pid(1), .peerSharing(.sharePeers(peers))))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.peerSharing == .done)         // one-shot transition
        #expect(snapshot[pid(1)]?.peerSharingResponse == nil)   // drained by visitor
        await g.stop()
    }
}

@Suite("OutboundGovernor — peer-sharing responder") struct OutboundGovernorPeerSharingResponderTests {

    @Test func inboundShareRequestEmitsPeersRequested() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        await g.start()

        let collector = Task<GovernorEvent?, Never> {
            for await e in g.events {
                if case .peersRequested = e { return e }
            }
            return nil
        }

        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Remote asks us for peers
        iface.emit(.messageReceived(pid(1), .peerSharing(.shareRequest(amount: 10))))
        try? await Task.sleep(nanoseconds: 50_000_000)

        iface.finish()
        await g.stop()
        let event = await collector.value
        guard case .peersRequested(let p, let amount) = event else {
            Issue.record("expected .peersRequested"); return
        }
        #expect(p == pid(1))
        #expect(amount == 10)
    }

    @Test func replyPeerShareDispatchesSharePeersWithoutAdvancingInitiatorMachine() async {
        let (g, iface) = makeGovernor()
        await g.includePeer(pid(1))
        _ = iface.drainCommands()

        let peers: [PeerAddress] = [.ipv4(addr: 0x0A00_0001, port: 3001)]
        await g.replyPeerShare(pid(1), peers: peers)

        let cmds = iface.drainCommands()
        let sharePeersFound = cmds.contains { item in
            if case .send(_, .peerSharing(.sharePeers(let p))) = item, p == peers { return true }
            return false
        }
        #expect(sharePeersFound)

        // Initiator-side peerSharing state must not have advanced.
        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.peerSharing == .idle)
    }
}

// MARK: - Disconnect lifecycle

@Suite("OutboundGovernor — disconnect lifecycle") struct OutboundGovernorDisconnectTests {

    @Test func disconnectedEventResetsTransientState() async {
        let (g, iface) = makeGovernor(promotion: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        await g.start()
        await g.includePeer(pid(1))
        await g.housekeeping()
        iface.emit(.connected(pid(1)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        iface.emit(.messageReceived(pid(1), acceptVersionMessage()))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await g.housekeeping()  // sends keepalive cookie=0

        iface.emit(.disconnected(pid(1)))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await g.peerSnapshot()
        #expect(snapshot[pid(1)]?.handshake == .start)
        #expect(snapshot[pid(1)]?.keepAliveCookieInFlight == nil)
        #expect(snapshot[pid(1)]?.negotiatedVersion == nil)
        await g.stop()
    }
}

// MARK: - PeerState.resetForReconnect

@Suite("PeerState.resetForReconnect") struct PeerStateResetTests {

    @Test func resetsTransientFieldsAndPreservesReputation() {
        var s = PeerState()
        s.connection = .errored(NSError(domain: "x", code: 1))
        s.promotion = .warm
        s.handshake = .accepted
        s.keepAlive = .busy
        s.peerSharing = .busy
        s.negotiatedVersion = NegotiatedVersion(
            version: 14, versionData: .nodeToNode(networkMagic: 1, initiatorOnly: false, peerSharing: 1, query: false)
        )
        s.peerSharingResponse = [.ipv4(addr: 1, port: 1)]
        s.keepAliveCookieInFlight = 42
        s.keepAliveNextCookie = 100
        s.inboundPeerSharingRequest = 7
        s.errorCount = 3
        s.violation = true

        s.resetForReconnect()

        #expect(s.handshake == .start)
        #expect(s.keepAlive == .idle)
        #expect(s.peerSharing == .idle)
        #expect(s.negotiatedVersion == nil)
        #expect(s.peerSharingResponse == nil)
        #expect(s.keepAliveCookieInFlight == nil)
        #expect(s.keepAliveNextCookie == 0)
        #expect(s.inboundPeerSharingRequest == nil)
        // Preserved
        #expect(s.errorCount == 3)
        #expect(s.violation == true)
        #expect(s.promotion == .warm)
    }
}
