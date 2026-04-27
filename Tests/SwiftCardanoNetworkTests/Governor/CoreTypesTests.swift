import Foundation
import Testing

@testable import SwiftCardanoNetwork

// MARK: - PeerID

@Suite("PeerID") struct PeerIDTests {

    @Test func equality() {
        let a = PeerID(host: "127.0.0.1", port: 3001)
        let b = PeerID(host: "127.0.0.1", port: 3001)
        let c = PeerID(host: "127.0.0.1", port: 3002)
        let d = PeerID(host: "127.0.0.2", port: 3001)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test func description() {
        #expect(PeerID(host: "relay.iog.io", port: 3001).description == "relay.iog.io:3001")
    }

    @Test func hashableInSet() {
        var s = Set<PeerID>()
        s.insert(PeerID(host: "1.1.1.1", port: 1))
        s.insert(PeerID(host: "1.1.1.1", port: 1))
        s.insert(PeerID(host: "1.1.1.1", port: 2))
        #expect(s.count == 2)
    }

    @Test func parsingValidIPv4() {
        let p = PeerID(parsing: "127.0.0.1:3001")
        #expect(p == PeerID(host: "127.0.0.1", port: 3001))
    }

    @Test func parsingValidHostname() {
        let p = PeerID(parsing: "relay.iog.io:3001")
        #expect(p == PeerID(host: "relay.iog.io", port: 3001))
    }

    @Test func parsingMissingPort() {
        #expect(PeerID(parsing: "127.0.0.1") == nil)
    }

    @Test func parsingNonNumericPort() {
        #expect(PeerID(parsing: "127.0.0.1:abc") == nil)
    }

    @Test func parsingEmptyHost() {
        #expect(PeerID(parsing: ":3001") == nil)
    }

    @Test func parsingPortOutOfRange() {
        #expect(PeerID(parsing: "127.0.0.1:99999") == nil)
    }

    @Test func fromIPv4PeerAddress() {
        let addr = PeerAddress.ipv4(addr: 0x7F00_0001, port: 3001)
        #expect(PeerID(addr) == PeerID(host: "127.0.0.1", port: 3001))
    }

    @Test func fromIPv6PeerAddress() {
        let addr = PeerAddress.ipv6(addr: (0x2001_0DB8, 0, 0, 1), port: 3001)
        let pid = PeerID(addr)
        #expect(pid.host == "2001:db8:0:0:0:0:0:1")
        #expect(pid.port == 3001)
    }
}

// MARK: - ConnectionState

@Suite("ConnectionState") struct ConnectionStateTests {

    @Test func descriptions() {
        #expect(ConnectionState.new.description == "new")
        #expect(ConnectionState.connecting.description == "connecting")
        #expect(ConnectionState.connected.description == "connected")
        #expect(ConnectionState.initialized.description == "initialized")
        #expect(ConnectionState.disconnected.description == "disconnected")
    }

    @Test func tagPatternMatch() {
        let e = ConnectionState.errored(NSError(domain: "test", code: 1))
        if case .errored = e { /* ok */ } else { Issue.record("expected .errored") }
        if case .new = ConnectionState.new { /* ok */ } else { Issue.record("expected .new") }
    }
}

// MARK: - PromotionTag

@Suite("PromotionTag") struct PromotionTagTests {

    @Test func equality() {
        #expect(PromotionTag.cold == PromotionTag.cold)
        #expect(PromotionTag.warm != PromotionTag.cold)
    }

    @Test func descriptions() {
        #expect(PromotionTag.cold.description == "cold")
        #expect(PromotionTag.warm.description == "warm")
        #expect(PromotionTag.hot.description == "hot")
        #expect(PromotionTag.banned.description == "banned")
    }
}

// MARK: - AnyMiniProtocolMessage

@Suite("AnyMiniProtocolMessage") struct AnyMiniProtocolMessageTests {

    @Test func protocolIDsMatchMux() {
        let cases: [(AnyMiniProtocolMessage, UInt16, String)] = [
            (.handshake(.proposeVersions([:])), MuxSDU.ProtocolID.handshake, "handshake"),
            (.keepAlive(.done), MuxSDU.ProtocolID.keepAlive, "keepAlive"),
            (.peerSharing(.done), MuxSDU.ProtocolID.peerSharing, "peerSharing"),
            (.chainSync(.done), MuxSDU.ProtocolID.chainSync, "chainSync"),
            (.blockFetch(.clientDone), MuxSDU.ProtocolID.blockFetch, "blockFetch"),
            (.txSubmission2(.done), MuxSDU.ProtocolID.txSubmission2, "txSubmission2"),
        ]
        for (msg, expectedID, expectedName) in cases {
            #expect(msg.protocolID == expectedID)
            #expect(msg.protocolName == expectedName)
        }
    }
}

// MARK: - PeerState

@Suite("PeerState") struct PeerStateTests {

    @Test func defaultsAreSensible() {
        let s = PeerState()
        if case .new = s.connection { /* ok */ } else { Issue.record("expected .new") }
        #expect(s.promotion == .cold)
        #expect(s.handshake == .start)
        #expect(s.keepAlive == .idle)
        #expect(s.peerSharing == .idle)
        #expect(s.violation == false)
        #expect(s.errorCount == 0)
        #expect(s.negotiatedVersion == nil)
        #expect(s.lastSeen == nil)
    }

    @Test func isInitializedTracksConnection() {
        var s = PeerState()
        #expect(!s.isInitialized)
        s.connection = .initialized
        #expect(s.isInitialized)
        s.connection = .connecting
        #expect(!s.isInitialized)
    }

    @Test func supportsPeerSharingFalseWithoutNegotiation() {
        let s = PeerState()
        #expect(!s.supportsPeerSharing)
    }

    @Test func supportsPeerSharingFalseBelowV14() {
        var s = PeerState()
        s.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v13,
            versionData: .nodeToNode(networkMagic: 1, initiatorOnly: false, peerSharing: 1, query: false)
        )
        #expect(!s.supportsPeerSharing)
    }

    @Test func supportsPeerSharingFalseWhenFlagDisabled() {
        var s = PeerState()
        s.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(networkMagic: 1, initiatorOnly: false, peerSharing: 0, query: false)
        )
        #expect(!s.supportsPeerSharing)
    }

    @Test func supportsPeerSharingTrueAtV14WithFlag1() {
        var s = PeerState()
        s.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(networkMagic: 1, initiatorOnly: false, peerSharing: 1, query: false)
        )
        #expect(s.supportsPeerSharing)
    }

    @Test func supportsPeerSharingFalseForNtCData() {
        var s = PeerState()
        s.negotiatedVersion = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToClient(networkMagic: 1)
        )
        #expect(!s.supportsPeerSharing)
    }
}

// MARK: - OutboundQueue

@Suite("OutboundQueue") struct OutboundQueueTests {

    @Test func startsEmpty() {
        let q = OutboundQueue()
        #expect(q.isEmpty)
        #expect(q.count == 0)
    }

    @Test func pushCommandsAndEvents() {
        var q = OutboundQueue()
        let pid = PeerID(host: "127.0.0.1", port: 3001)
        q.push(.connect(pid))
        q.push(.peerDiscovered(pid))
        q.push(.disconnect(pid))
        #expect(q.count == 3)
        #expect(!q.isEmpty)
    }

    @Test func drainPreservesOrderAndEmpties() {
        var q = OutboundQueue()
        let pid = PeerID(host: "127.0.0.1", port: 3001)
        q.push(.connect(pid))
        q.push(.peerDiscovered(pid))

        let items = q.drain()

        #expect(items.count == 2)
        #expect(q.isEmpty)

        guard case .command(.connect(let p1)) = items[0] else {
            Issue.record("expected .command(.connect)"); return
        }
        guard case .event(.peerDiscovered(let p2)) = items[1] else {
            Issue.record("expected .event(.peerDiscovered)"); return
        }
        #expect(p1 == pid)
        #expect(p2 == pid)
    }

    @Test func drainOnEmpty() {
        var q = OutboundQueue()
        let items = q.drain()
        #expect(items.isEmpty)
        #expect(q.isEmpty)
    }
}

// MARK: - PeerVisitor (default no-op)

@Suite("PeerVisitor (default no-ops)") struct PeerVisitorDefaultTests {

    /// A sample visitor with no overrides — every hook should be a no-op.
    private struct NoopVisitor: PeerVisitor {}

    @Test func everyHookIsNoOp() {
        var v = NoopVisitor()
        let pid = PeerID(host: "127.0.0.1", port: 3001)
        var state = PeerState()
        var queue = OutboundQueue()

        v.discovered(pid, &state, &queue)
        v.connected(pid, &state, &queue)
        v.disconnected(pid, &state, &queue)
        v.errored(pid, &state, &queue)
        v.inboundMessage(pid, &state, &queue)
        v.outboundMessage(pid, &state, &queue)
        v.housekeeping(pid, &state, &queue)
        v.tagged(pid, &state, &queue)

        #expect(queue.isEmpty)
        if case .new = state.connection { /* ok */ } else { Issue.record("state mutated") }
        #expect(state.promotion == .cold)
    }

    /// Confirm the inout-mutation pattern actually works — visitor that
    /// mutates state and pushes a command is observed by the caller.
    private struct CountingVisitor: PeerVisitor {
        var ticks: Int = 0
        mutating func housekeeping(_ pid: PeerID, _ state: inout PeerState, _ outbound: inout OutboundQueue) {
            ticks += 1
            state.errorCount += 1
            outbound.push(.connect(pid))
        }
    }

    @Test func mutatingVisitorInOutWorks() {
        var v = CountingVisitor()
        var state = PeerState()
        var queue = OutboundQueue()
        let pid = PeerID(host: "1.2.3.4", port: 3001)

        v.housekeeping(pid, &state, &queue)
        v.housekeeping(pid, &state, &queue)

        #expect(v.ticks == 2)
        #expect(state.errorCount == 2)
        #expect(queue.count == 2)
    }
}

// MARK: - GovernorEvent / BanReason

@Suite("BanReason") struct BanReasonTests {

    @Test func equality() {
        #expect(BanReason.violation == .violation)
        #expect(BanReason.errorThreshold(observed: 5, limit: 3)
              == BanReason.errorThreshold(observed: 5, limit: 3))
        #expect(BanReason.errorThreshold(observed: 5, limit: 3)
              != BanReason.errorThreshold(observed: 6, limit: 3))
        #expect(BanReason.violation != .manual)
    }

    @Test func descriptions() {
        #expect(BanReason.violation.description == "violation")
        #expect(BanReason.manual.description == "manual")
        #expect(BanReason.errorThreshold(observed: 5, limit: 3).description
              == "errorThreshold(observed=5, limit=3)")
    }
}
