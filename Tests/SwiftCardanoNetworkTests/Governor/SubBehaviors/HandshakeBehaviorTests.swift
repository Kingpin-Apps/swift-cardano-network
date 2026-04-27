import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let pid = PeerID(host: "10.0.0.1", port: 3001)

private func freshConfig(magic: UInt32 = 764_824_073) -> HandshakeBehaviorConfig {
    HandshakeBehaviorConfig(networkMagic: magic)
}

private func neg(version: UInt16 = NodeToNodeVersion.v14, magic: UInt32 = 764_824_073, peerSharing: UInt8? = 1) -> NegotiatedVersion {
    NegotiatedVersion(
        version: version,
        versionData: .nodeToNode(networkMagic: magic, initiatorOnly: false, peerSharing: peerSharing, query: false)
    )
}

// MARK: - Config

@Suite("HandshakeBehaviorConfig defaults") struct HandshakeBehaviorConfigDefaultsTests {

    @Test func providesDefaultVersionList() {
        let c = HandshakeBehaviorConfig(networkMagic: 1)
        #expect(c.ntnVersions == [14, 13, 12, 11, 10, 9, 8, 7])
        #expect(c.peerSharingFlag == 1)
        #expect(c.initiatorOnly == false)
    }
}

// MARK: - connected hook

@Suite("HandshakeBehavior — connected hook") struct HandshakeBehaviorConnectedTests {

    @Test func emitsProposeVersionsFromStart() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        var q = OutboundQueue()

        b.connected(pid, &s, &q)

        #expect(q.count == 1)
        guard case .command(.send(let p, .handshake(.proposeVersions(let versions)))) = q.items[0] else {
            Issue.record("expected .send(.handshake(.proposeVersions))"); return
        }
        #expect(p == pid)
        #expect(versions.count == 8)   // v7..v14 in default
    }

    @Test func proposedVersionDataIncludesNetworkMagic() {
        var b = HandshakeBehavior(config: freshConfig(magic: 764_824_073))
        var s = PeerState()
        var q = OutboundQueue()
        b.connected(pid, &s, &q)

        guard case .command(.send(_, .handshake(.proposeVersions(let versions)))) = q.items[0] else {
            Issue.record("expected proposeVersions"); return
        }
        guard let v14data = versions[NodeToNodeVersion.v14] else {
            Issue.record("missing v14 entry"); return
        }
        guard case .nodeToNode(let magic, let initOnly, let ps, let query) = v14data else {
            Issue.record("expected NtN version data"); return
        }
        #expect(magic == 764_824_073)
        #expect(initOnly == false)
        #expect(ps == 1)            // default peerSharingFlag
        #expect(query == false)     // v14 ≥ v13 → query field present
    }

    @Test func peerSharingFieldOmittedBelowV11() {
        var b = HandshakeBehavior(config: HandshakeBehaviorConfig(
            networkMagic: 1, ntnVersions: [10, 9], peerSharingFlag: 1
        ))
        var s = PeerState()
        var q = OutboundQueue()
        b.connected(pid, &s, &q)

        guard case .command(.send(_, .handshake(.proposeVersions(let versions)))) = q.items[0] else {
            Issue.record("expected proposeVersions"); return
        }
        guard case .nodeToNode(_, _, let ps10, let q10) = versions[10]! else {
            Issue.record("expected NtN version data"); return
        }
        #expect(ps10 == nil)         // v10 < v11 → no peerSharing field
        #expect(q10 == nil)          // v10 < v13 → no query field
    }

    @Test func skipsWhenAlreadyProposed() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.handshake = .proposed
        var q = OutboundQueue()
        b.connected(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func skipsWhenAlreadyAccepted() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.handshake = .accepted
        var q = OutboundQueue()
        b.connected(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func customVersionList() {
        var b = HandshakeBehavior(config: HandshakeBehaviorConfig(
            networkMagic: 1, ntnVersions: [15, 14]
        ))
        var s = PeerState()
        var q = OutboundQueue()
        b.connected(pid, &s, &q)

        guard case .command(.send(_, .handshake(.proposeVersions(let versions)))) = q.items[0] else {
            Issue.record("expected proposeVersions"); return
        }
        #expect(versions.count == 2)
        #expect(versions[15] != nil)
        #expect(versions[14] != nil)
    }
}

// MARK: - inboundMessage hook

@Suite("HandshakeBehavior — inboundMessage hook") struct HandshakeBehaviorInboundTests {

    @Test func acceptedTransitionsToInitialized() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .accepted
        s.negotiatedVersion = neg()
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)

        if case .initialized = s.connection { /* ok */ } else {
            Issue.record("expected .initialized, got \(s.connection)")
        }
        let events = q.items.compactMap { item -> GovernorEvent? in
            if case .event(let e) = item { return e } else { return nil }
        }
        #expect(events.count == 1)
        guard case .peerConnected(let p, let v) = events[0] else {
            Issue.record("expected .peerConnected"); return
        }
        #expect(p == pid)
        #expect(v.version == NodeToNodeVersion.v14)
    }

    @Test func acceptedNoOpsWithoutNegotiatedVersion() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .accepted
        s.negotiatedVersion = nil   // not yet stashed by apply layer
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        // Connection not promoted, no event emitted.
        if case .connected = s.connection { /* ok */ } else {
            Issue.record("expected .connected (no transition without negotiated version)")
        }
        #expect(q.isEmpty)
    }

    @Test func acceptedDoesNotRefireWhenAlreadyInitialized() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .initialized
        s.handshake = .accepted
        s.negotiatedVersion = neg()
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        // Already initialised — no event re-emit.
        #expect(q.isEmpty)
    }

    @Test func refusedTransitionsToErrored() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .refused
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        guard case .errored(let err) = s.connection else {
            Issue.record("expected .errored, got \(s.connection)"); return
        }
        #expect(err is HandshakeRefusedError)
    }

    @Test func refusedCarriesTypedReason() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .refused
        s.lastHandshakeRefusal = .versionMismatch([14, 13, 12])
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)

        guard case .errored(let err) = s.connection,
              let refused = err as? HandshakeRefusedError
        else {
            Issue.record("expected .errored(HandshakeRefusedError), got \(s.connection)"); return
        }
        guard case .versionMismatch(let versions) = refused.reason else {
            Issue.record("expected .versionMismatch reason, got \(String(describing: refused.reason))"); return
        }
        #expect(versions == [14, 13, 12])
    }

    @Test func refusedWithoutCapturedReasonStillWorks() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .refused
        s.lastHandshakeRefusal = nil   // apply layer not invoked / pre-13.8 path
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        guard case .errored(let err) = s.connection,
              let refused = err as? HandshakeRefusedError
        else {
            Issue.record("expected HandshakeRefusedError"); return
        }
        #expect(refused.reason == nil)
        #expect(refused.description == "handshake refused")
    }

    @Test func startStateIsNoOp() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .start
        var q = OutboundQueue()
        b.inboundMessage(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func proposedStateIsNoOp() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .connected
        s.handshake = .proposed
        var q = OutboundQueue()
        b.inboundMessage(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func acceptedNoOpsWhenNotConnected() {
        var b = HandshakeBehavior(config: freshConfig())
        var s = PeerState()
        s.connection = .disconnected
        s.handshake = .accepted
        s.negotiatedVersion = neg()
        var q = OutboundQueue()
        b.inboundMessage(pid, &s, &q)
        if case .disconnected = s.connection { /* ok */ } else {
            Issue.record("connection should not have changed")
        }
    }
}
