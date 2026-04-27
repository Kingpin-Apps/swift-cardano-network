import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let pid = PeerID(host: "10.0.0.1", port: 3001)

private func state(_ connection: ConnectionState, _ promotion: PromotionTag) -> PeerState {
    var s = PeerState()
    s.connection = connection
    s.promotion = promotion
    return s
}

private struct MockError: Error {}

// MARK: - needsConnection

@Suite("ConnectionBehavior — needsConnection") struct ConnectionBehaviorNeedsConnectionTests {

    @Test func warmNewNeedsConnection() {
        #expect(ConnectionBehavior.needsConnection(state(.new, .warm)))
    }

    @Test func hotDisconnectedNeedsConnection() {
        #expect(ConnectionBehavior.needsConnection(state(.disconnected, .hot)))
    }

    @Test func coldNewDoesNotConnect() {
        #expect(!ConnectionBehavior.needsConnection(state(.new, .cold)))
    }

    @Test func bannedDisconnectedDoesNotConnect() {
        #expect(!ConnectionBehavior.needsConnection(state(.disconnected, .banned)))
    }

    @Test func alreadyConnectedDoesNotReconnect() {
        #expect(!ConnectionBehavior.needsConnection(state(.connected, .warm)))
    }

    @Test func alreadyConnectingDoesNotReconnect() {
        #expect(!ConnectionBehavior.needsConnection(state(.connecting, .warm)))
    }

    @Test func initializedDoesNotReconnect() {
        #expect(!ConnectionBehavior.needsConnection(state(.initialized, .hot)))
    }

    @Test func erroredDoesNotConnect() {
        let s = state(.errored(MockError()), .warm)
        #expect(!ConnectionBehavior.needsConnection(s))
    }
}

// MARK: - needsDisconnect

@Suite("ConnectionBehavior — needsDisconnect") struct ConnectionBehaviorNeedsDisconnectTests {

    @Test func erroredAlwaysNeedsDisconnect() {
        for promo: PromotionTag in [.cold, .warm, .hot, .banned] {
            #expect(ConnectionBehavior.needsDisconnect(state(.errored(MockError()), promo)))
        }
    }

    @Test func coldInitializedNeedsDisconnect() {
        #expect(ConnectionBehavior.needsDisconnect(state(.initialized, .cold)))
    }

    @Test func bannedConnectedNeedsDisconnect() {
        #expect(ConnectionBehavior.needsDisconnect(state(.connected, .banned)))
    }

    @Test func hotInitializedStaysConnected() {
        #expect(!ConnectionBehavior.needsDisconnect(state(.initialized, .hot)))
    }

    @Test func warmConnectedStaysConnected() {
        #expect(!ConnectionBehavior.needsDisconnect(state(.connected, .warm)))
    }

    @Test func newDoesNotDisconnect() {
        #expect(!ConnectionBehavior.needsDisconnect(state(.new, .warm)))
    }

    @Test func connectingDoesNotDisconnect() {
        #expect(!ConnectionBehavior.needsDisconnect(state(.connecting, .warm)))
    }

    @Test func disconnectedDoesNotDisconnect() {
        #expect(!ConnectionBehavior.needsDisconnect(state(.disconnected, .cold)))
    }
}

// MARK: - housekeeping hook

@Suite("ConnectionBehavior — housekeeping hook") struct ConnectionBehaviorHousekeepingTests {

    @Test func emitsConnectAndAdvancesState() {
        var b = ConnectionBehavior()
        var s = state(.new, .warm)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)

        if case .connecting = s.connection { /* ok */ } else {
            Issue.record("expected .connecting, got \(s.connection)")
        }
        #expect(b.connectionAttempts == 1)
        #expect(q.count == 1)
        guard case .command(.connect(let p)) = q.items[0] else {
            Issue.record("expected .connect"); return
        }
        #expect(p == pid)
    }

    @Test func emitsDisconnectForColdInitialized() {
        var b = ConnectionBehavior()
        var s = state(.initialized, .cold)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.count == 1)
        guard case .command(.disconnect(let p)) = q.items[0] else {
            Issue.record("expected .disconnect"); return
        }
        #expect(p == pid)
    }

    @Test func noOpForHotInitialized() {
        var b = ConnectionBehavior()
        var s = state(.initialized, .hot)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
        #expect(b.connectionAttempts == 0)
    }

    @Test func noOpWhileConnecting() {
        var b = ConnectionBehavior()
        var s = state(.connecting, .warm)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func reconnectsOnDisconnectedWarm() {
        var b = ConnectionBehavior()
        var s = state(.disconnected, .warm)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        if case .connecting = s.connection { /* ok */ } else {
            Issue.record("expected .connecting after reconnect")
        }
        #expect(b.connectionAttempts == 1)
        guard case .command(.connect) = q.items[0] else {
            Issue.record("expected .connect"); return
        }
    }

    @Test func erroredDoesNotEmitConnect() {
        var b = ConnectionBehavior()
        var s = state(.errored(MockError()), .warm)
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        // Errored should produce ONE disconnect, no connect.
        #expect(b.connectionAttempts == 0)
        #expect(q.count == 1)
        guard case .command(.disconnect) = q.items[0] else {
            Issue.record("expected .disconnect"); return
        }
    }
}

// MARK: - errored hook

@Suite("ConnectionBehavior — errored hook") struct ConnectionBehaviorErroredHookTests {

    @Test func emitsDisconnectOnError() {
        var b = ConnectionBehavior()
        var s = state(.errored(MockError()), .warm)
        var q = OutboundQueue()
        b.errored(pid, &s, &q)
        #expect(q.count == 1)
        guard case .command(.disconnect(let p)) = q.items[0] else {
            Issue.record("expected .disconnect"); return
        }
        #expect(p == pid)
    }

    @Test func noOpIfNotInDisconnectableState() {
        var b = ConnectionBehavior()
        // Errored visitor hook fires but state hasn't transitioned to errored
        // yet — sub-behavior should not emit disconnect spuriously.
        var s = state(.connecting, .warm)
        var q = OutboundQueue()
        b.errored(pid, &s, &q)
        #expect(q.isEmpty)
    }
}
