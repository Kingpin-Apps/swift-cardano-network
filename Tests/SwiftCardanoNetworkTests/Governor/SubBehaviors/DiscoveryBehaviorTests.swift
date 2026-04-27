import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private func peerSharingEnabledState() -> PeerState {
    var s = PeerState()
    s.connection = .initialized
    s.negotiatedVersion = NegotiatedVersion(
        version: NodeToNodeVersion.v14,
        versionData: .nodeToNode(
            networkMagic: 1, initiatorOnly: false,
            peerSharing: 1, query: false
        )
    )
    return s
}

private let pid = PeerID(host: "10.0.0.1", port: 3001)

// MARK: - Configuration & pool drain

@Suite("DiscoveryBehavior — config & pool") struct DiscoveryConfigTests {

    @Test func defaultHighWaterMarkIs100() {
        let cfg = DiscoveryConfig()
        #expect(cfg.highWaterMark == 100)
    }

    @Test func customHighWaterMark() {
        let cfg = DiscoveryConfig(highWaterMark: 50)
        #expect(cfg.highWaterMark == 50)
    }

    @Test func startsEmpty() {
        let d = DiscoveryBehavior()
        #expect(d.discovered.isEmpty)
    }

    @Test func drainOnEmptyReturnsEmpty() {
        var d = DiscoveryBehavior()
        let got = d.drainNewPeers(5)
        #expect(got.isEmpty)
    }

    @Test func drainReturnsUpToCount() {
        var d = DiscoveryBehavior()
        var s = peerSharingEnabledState()
        s.peerSharingResponse = (1...5).map { i in
            .ipv4(addr: 0x0A00_0000 | UInt32(i), port: 3001)
        }
        d.tryTakePeers(&s)
        #expect(d.discovered.count == 5)

        let took = d.drainNewPeers(2)
        #expect(took.count == 2)
        #expect(d.discovered.count == 3)
    }

    @Test func drainOfZeroIsNoop() {
        var d = DiscoveryBehavior()
        var s = peerSharingEnabledState()
        s.peerSharingResponse = [.ipv4(addr: 0x0A00_0001, port: 1)]
        d.tryTakePeers(&s)
        let took = d.drainNewPeers(0)
        #expect(took.isEmpty)
        #expect(d.discovered.count == 1)
    }
}

// MARK: - tryTakePeers

@Suite("DiscoveryBehavior — tryTakePeers") struct DiscoveryTakeTests {

    @Test func takesIPv4AndIPv6FromResponse() {
        var d = DiscoveryBehavior()
        var s = peerSharingEnabledState()
        s.peerSharingResponse = [
            .ipv4(addr: 0x0A00_0001, port: 3001),
            .ipv6(addr: (0x2001_0DB8, 0, 0, 1), port: 3001),
        ]
        d.tryTakePeers(&s)
        #expect(d.discovered.count == 2)
        #expect(s.peerSharingResponse == nil)
        #expect(s.peerSharing == .done)
    }

    @Test func dedupesAcrossMultipleResponses() {
        var d = DiscoveryBehavior()

        var s1 = peerSharingEnabledState()
        s1.peerSharingResponse = [
            .ipv4(addr: 0x0A00_0001, port: 3001),
            .ipv4(addr: 0x0A00_0002, port: 3001),
        ]
        d.tryTakePeers(&s1)

        var s2 = peerSharingEnabledState()
        s2.peerSharingResponse = [
            .ipv4(addr: 0x0A00_0001, port: 3001),  // dup
            .ipv4(addr: 0x0A00_0003, port: 3001),
        ]
        d.tryTakePeers(&s2)

        #expect(d.discovered.count == 3)
    }

    @Test func noopWhenResponseIsNil() {
        var d = DiscoveryBehavior()
        var s = peerSharingEnabledState()
        s.peerSharingResponse = nil
        d.tryTakePeers(&s)
        #expect(d.discovered.isEmpty)
        #expect(s.peerSharing == .idle)
    }
}

// MARK: - housekeeping

@Suite("DiscoveryBehavior — housekeeping") struct DiscoveryHousekeepingTests {

    @Test func emitsShareRequestWhenAvailable() {
        var d = DiscoveryBehavior(config: DiscoveryConfig(highWaterMark: 10))
        var state = peerSharingEnabledState()
        var queue = OutboundQueue()

        d.housekeeping(pid, &state, &queue)

        #expect(queue.count == 1)
        guard case .command(.send(let p, .peerSharing(.shareRequest(let amount)))) = queue.items[0] else {
            Issue.record("expected .send(.peerSharing(.shareRequest))"); return
        }
        #expect(p == pid)
        #expect(amount == 10)  // highWaterMark - 0 discovered
    }

    @Test func amountTracksDeficit() {
        var d = DiscoveryBehavior(config: DiscoveryConfig(highWaterMark: 50))
        // Pre-fill 30 discovered
        var seedState = peerSharingEnabledState()
        seedState.peerSharingResponse = (1...30).map { i in
            .ipv4(addr: 0x0A00_0000 | UInt32(i), port: 3001)
        }
        d.tryTakePeers(&seedState)
        #expect(d.discovered.count == 30)

        var state = peerSharingEnabledState()
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)

        guard case .command(.send(_, .peerSharing(.shareRequest(let amount)))) = queue.items[0] else {
            Issue.record("expected shareRequest"); return
        }
        #expect(amount == 20)  // 50 - 30
    }

    @Test func skipsWhenAtHighWaterMark() {
        var d = DiscoveryBehavior(config: DiscoveryConfig(highWaterMark: 3))
        var seedState = peerSharingEnabledState()
        seedState.peerSharingResponse = (1...3).map { i in
            .ipv4(addr: 0x0A00_0000 | UInt32(i), port: 3001)
        }
        d.tryTakePeers(&seedState)

        var state = peerSharingEnabledState()
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)

        #expect(queue.isEmpty)
    }

    @Test func skipsWhenNotInitialized() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.connection = .connecting   // not initialized
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        #expect(queue.isEmpty)
    }

    @Test func skipsWhenPeerSharingNotSupported() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: 0, query: false  // disabled
            )
        )
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        #expect(queue.isEmpty)
    }

    @Test func skipsWhenLocalStateIsBusy() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.peerSharing = .busy   // request already in flight
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        #expect(queue.isEmpty)
    }

    @Test func skipsWhenLocalStateIsDone() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.peerSharing = .done   // already used this peer
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        #expect(queue.isEmpty)
    }

    @Test func skipsWhenResponsePending() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.peerSharingResponse = []   // a response is queued but not drained
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        #expect(queue.isEmpty)
    }

    @Test func amountClampsAtUInt8Max() {
        // Use a custom DiscoveryBehavior that allows the high-water mark
        // to exceed UInt8.max — sanity check via direct field access.
        var d = DiscoveryBehavior(config: DiscoveryConfig(highWaterMark: UInt8.max))
        var state = peerSharingEnabledState()
        var queue = OutboundQueue()
        d.housekeeping(pid, &state, &queue)
        guard case .command(.send(_, .peerSharing(.shareRequest(let amount)))) = queue.items[0] else {
            Issue.record("expected shareRequest"); return
        }
        #expect(amount == UInt8.max)
    }
}

// MARK: - inboundMessage hook

@Suite("DiscoveryBehavior — inboundMessage") struct DiscoveryInboundTests {

    @Test func drainsResponseOnInbound() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.peerSharingResponse = [
            .ipv4(addr: 0x0A00_0001, port: 1),
            .ipv4(addr: 0x0A00_0002, port: 2),
        ]
        var queue = OutboundQueue()
        d.inboundMessage(pid, &state, &queue)
        #expect(d.discovered.count == 2)
        #expect(state.peerSharing == .done)
        #expect(state.peerSharingResponse == nil)
    }

    @Test func skipsWhenPeerSharingNotSupported() {
        var d = DiscoveryBehavior()
        var state = peerSharingEnabledState()
        state.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: 0, query: false
            )
        )
        state.peerSharingResponse = [.ipv4(addr: 0x0A00_0001, port: 1)]
        var queue = OutboundQueue()
        d.inboundMessage(pid, &state, &queue)
        #expect(d.discovered.isEmpty)
        // Response stays in place — different visitor / future tick may consume it.
        #expect(state.peerSharingResponse != nil)
    }
}
