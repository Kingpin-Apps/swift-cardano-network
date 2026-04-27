import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let pid = PeerID(host: "10.0.0.1", port: 3001)

private func initialisedState() -> PeerState {
    var s = PeerState()
    s.connection = .initialized
    return s
}

// MARK: - housekeeping hook

@Suite("KeepAliveBehavior — housekeeping") struct KeepAliveBehaviorHousekeepingTests {

    @Test func emitsProbeWhenIdleAndInitialized() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        var q = OutboundQueue()

        b.housekeeping(pid, &s, &q)

        #expect(q.count == 1)
        guard case .command(.send(let p, .keepAlive(.keepAlive(let cookie)))) = q.items[0] else {
            Issue.record("expected .send(.keepAlive(.keepAlive))"); return
        }
        #expect(p == pid)
        #expect(cookie == 0)        // first cookie
        #expect(s.keepAliveCookieInFlight == 0)
        #expect(s.keepAliveNextCookie == 1)
    }

    @Test func cookieAdvancesAcrossTicks() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        var q = OutboundQueue()

        b.housekeeping(pid, &s, &q)
        // Simulate the apply layer clearing the in-flight cookie on response.
        s.keepAliveCookieInFlight = nil

        b.housekeeping(pid, &s, &q)

        let cookies = q.items.compactMap { item -> UInt16? in
            if case .command(.send(_, .keepAlive(.keepAlive(let c)))) = item { return c }
            return nil
        }
        #expect(cookies == [0, 1])
        #expect(s.keepAliveNextCookie == 2)
    }

    @Test func skipsWhenNotInitialized() {
        var b = KeepAliveBehavior()
        var s = PeerState()
        s.connection = .connected   // handshake not done
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func skipsWhenStateMachineBusy() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        s.keepAlive = .busy
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func skipsWhenStateMachineDone() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        s.keepAlive = .done
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func skipsWhenCookieAlreadyInFlight() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        s.keepAliveCookieInFlight = 5
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)
        #expect(q.isEmpty)
        #expect(s.keepAliveCookieInFlight == 5)   // unchanged
    }

    @Test func cookieWrapsAtUInt16Max() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        s.keepAliveNextCookie = UInt16.max
        var q = OutboundQueue()
        b.housekeeping(pid, &s, &q)

        guard case .command(.send(_, .keepAlive(.keepAlive(let cookie)))) = q.items[0] else {
            Issue.record("expected probe"); return
        }
        #expect(cookie == UInt16.max)
        #expect(s.keepAliveNextCookie == 0)   // wrapped
    }
}

// MARK: - default no-op hooks

@Suite("KeepAliveBehavior — non-housekeeping hooks") struct KeepAliveBehaviorOtherHooksTests {

    @Test func discoveredIsNoOp() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        var q = OutboundQueue()
        b.discovered(pid, &s, &q)
        #expect(q.isEmpty)
    }

    @Test func inboundMessageIsNoOp() {
        var b = KeepAliveBehavior()
        var s = initialisedState()
        var q = OutboundQueue()
        b.inboundMessage(pid, &s, &q)
        #expect(q.isEmpty)
    }
}
