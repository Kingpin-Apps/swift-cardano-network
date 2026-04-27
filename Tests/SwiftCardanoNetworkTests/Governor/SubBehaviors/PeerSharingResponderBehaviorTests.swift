import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let pid = PeerID(host: "10.0.0.1", port: 3001)

private func initialisedState() -> PeerState {
    var s = PeerState()
    s.connection = .initialized
    return s
}

// MARK: - inboundMessage hook

@Suite("PeerSharingResponderBehavior — inboundMessage") struct PeerSharingResponderTests {

    @Test func emitsPeersRequestedAndClearsField() {
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = 5
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)

        let events = q.items.compactMap { item -> GovernorEvent? in
            if case .event(let e) = item { return e } else { return nil }
        }
        #expect(events.count == 1)
        guard case .peersRequested(let p, let amount) = events[0] else {
            Issue.record("expected .peersRequested"); return
        }
        #expect(p == pid)
        #expect(amount == 5)
        #expect(s.inboundPeerSharingRequest == nil)
        #expect(b.requestsHandled == 1)
    }

    @Test func noEventWhenNoPendingRequest() {
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = nil
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        #expect(q.isEmpty)
        #expect(b.requestsHandled == 0)
    }

    @Test func noEmitWhenNotInitialized() {
        // Even if a stray request value is set, we should not surface it
        // until the connection is fully initialised.
        var b = PeerSharingResponderBehavior()
        var s = PeerState()
        s.connection = .connected
        s.inboundPeerSharingRequest = 7
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)
        #expect(q.isEmpty)
        #expect(s.inboundPeerSharingRequest == 7)   // preserved
        #expect(b.requestsHandled == 0)
    }

    @Test func doesNotReEmitOnSubsequentInbound() {
        // First inbound delivers MsgShareRequest; second inbound is some
        // other message (e.g. blockfetch) — the responder should NOT
        // re-fire the event.
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = 3
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)   // emits, clears
        b.inboundMessage(pid, &s, &q)   // should be a no-op now

        let events = q.items.compactMap { item -> GovernorEvent? in
            if case .event(let e) = item { return e } else { return nil }
        }
        #expect(events.count == 1)
        #expect(b.requestsHandled == 1)
    }

    @Test func handlesMultipleSequentialRequests() {
        // Real flow: app receives event, replies, peer sends another
        // request → field is set again → another event.
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        var q = OutboundQueue()

        s.inboundPeerSharingRequest = 4
        b.inboundMessage(pid, &s, &q)
        // App replies; some time later peer asks again.
        s.inboundPeerSharingRequest = 8
        b.inboundMessage(pid, &s, &q)

        let amounts = q.items.compactMap { item -> UInt8? in
            if case .event(.peersRequested(_, let a)) = item { return a }
            return nil
        }
        #expect(amounts == [4, 8])
        #expect(b.requestsHandled == 2)
    }

    @Test func amountZeroIsValid() {
        // Edge case: peer asks for zero peers. Pass it through unchanged.
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = 0
        var q = OutboundQueue()

        b.inboundMessage(pid, &s, &q)

        guard case .event(.peersRequested(_, let amount)) = q.items[0] else {
            Issue.record("expected .peersRequested"); return
        }
        #expect(amount == 0)
        #expect(b.requestsHandled == 1)
    }
}

// MARK: - non-inbound hooks

@Suite("PeerSharingResponderBehavior — other hooks") struct PeerSharingResponderOtherHooksTests {

    @Test func housekeepingIsNoOp() {
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = 5   // pending
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        // Responder fires only on inbound — housekeeping should not surface
        // a pending request.
        #expect(q.isEmpty)
        #expect(s.inboundPeerSharingRequest == 5)
    }

    @Test func discoveredIsNoOp() {
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        var q = OutboundQueue()
        b.discovered(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func erroredIsNoOp() {
        var b = PeerSharingResponderBehavior()
        var s = initialisedState()
        s.inboundPeerSharingRequest = 5
        var q = OutboundQueue()
        b.errored(pid, &s, &q)
        #expect(q.isEmpty)
    }
}
