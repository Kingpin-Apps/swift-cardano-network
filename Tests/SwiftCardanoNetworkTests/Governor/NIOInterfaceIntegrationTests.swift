import Dispatch
import Logging
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

/// Wait up to `timeoutMillis` for `predicate` to return true, calling
/// `housekeeping` between checks. Returns `true` if the predicate held
/// before the budget ran out.
private func waitFor(
    timeoutMillis: Int = 3_000,
    pollMillis: Int = 50,
    governor: OutboundGovernor,
    _ predicate: @Sendable (OutboundGovernor) async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMillis) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        await governor.housekeeping()
        if await predicate(governor) { return true }
        try? await Task.sleep(nanoseconds: UInt64(pollMillis) * 1_000_000)
    }
    return false
}

/// Spin up a single `MockCardanoNode` with peer-sharing enabled.
private func makeMock(
    group: EventLoopGroup,
    serves: [PeerAddress] = []
) async throws -> (MockCardanoNode, PeerID) {
    var config = MockNodeConfig()
    config.peerSharingFlag = 1
    config.peerSharingResponse = serves
    let node = try await MockCardanoNode(config: config, group: group)
    let pid = PeerID(host: "127.0.0.1", port: UInt16(node.port))
    return (node, pid)
}

/// Tear down governor + interface + nodes synchronously before the event
/// loop group shuts down, so NIO's "scheduled task on a shut-down loop"
/// warning never fires. The defer-based fallback only kicks in if a test
/// throws before the explicit cleanup runs.
private func teardown(
    governor: OutboundGovernor,
    iface: NIOInterface,
    nodes: [MockCardanoNode]
) async {
    await governor.stop()
    await iface.close()
    for n in nodes { try? await n.stop() }
}

@Suite("OutboundGovernor + NIOInterface (multi-peer)", .serialized)
struct OutboundGovernorMultiPeerTests {

    // MARK: - Single-peer end-to-end

    @Test("Governor: single peer goes Cold → Warm → Hot via real TCP")
    func singlePeerReachesHot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let (node, pid) = try await makeMock(group: group)
        let iface = NIOInterface(group: group)
        let governor = OutboundGovernor(
            interface: iface,
            handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
            promotionConfig: PromotionConfig(maxPeers: 10, maxWarmPeers: 5, maxHotPeers: 5)
        )
        await governor.start()

        await governor.includePeer(pid)

        let reached = await waitFor(governor: governor) { g in
            let counts = await g.promotionCounts()
            return counts.hot >= 1
        }
        #expect(reached, "expected peer to reach hot within timeout")

        let snapshot = await governor.peerSnapshot()
        if case .initialized = snapshot[pid]?.connection { /* ok */ } else {
            Issue.record("expected .initialized, got \(String(describing: snapshot[pid]?.connection))")
        }
        #expect(snapshot[pid]?.handshake == .accepted)
        #expect(snapshot[pid]?.negotiatedVersion?.version == NodeToNodeVersion.v14)

        await teardown(governor: governor, iface: iface, nodes: [node])
    }

    // MARK: - Multi-peer fan-out

    @Test("Governor: three peers all reach Hot in parallel")
    func threePeersAllReachHot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let mock1 = try await makeMock(group: group)
        let mock2 = try await makeMock(group: group)
        let mock3 = try await makeMock(group: group)

        let iface = NIOInterface(group: group)
        let governor = OutboundGovernor(
            interface: iface,
            handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
            promotionConfig: PromotionConfig(maxPeers: 10, maxWarmPeers: 5, maxHotPeers: 3)
        )
        await governor.start()

        await governor.includePeer(mock1.1)
        await governor.includePeer(mock2.1)
        await governor.includePeer(mock3.1)

        let reached = await waitFor(timeoutMillis: 5_000, governor: governor) { g in
            let counts = await g.promotionCounts()
            return counts.hot == 3
        }
        #expect(reached, "expected all three peers to reach hot")

        let snapshot = await governor.peerSnapshot()
        for pid in [mock1.1, mock2.1, mock3.1] {
            if case .initialized = snapshot[pid]?.connection { /* ok */ } else {
                Issue.record("\(pid): expected .initialized")
            }
        }

        await teardown(governor: governor, iface: iface, nodes: [mock1.0, mock2.0, mock3.0])
    }

    // MARK: - Discovery via peer-sharing

    @Test("Governor: peer-sharing replies populate discovery pool")
    func discoveryPoolFillsFromPeerSharing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let sharedAddrs: [PeerAddress] = [
            .ipv4(addr: 0x0A00_0011, port: 3001),
            .ipv4(addr: 0x0A00_0012, port: 3001),
            .ipv4(addr: 0x0A00_0013, port: 3001),
        ]
        let (node, pid) = try await makeMock(group: group, serves: sharedAddrs)
        let iface = NIOInterface(group: group)
        let governor = OutboundGovernor(
            interface: iface,
            handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
            discoveryConfig: DiscoveryConfig(highWaterMark: 50),
            promotionConfig: PromotionConfig(maxPeers: 10, maxWarmPeers: 5, maxHotPeers: 5)
        )
        await governor.start()

        await governor.includePeer(pid)

        let discovered = await waitFor(timeoutMillis: 5_000, governor: governor) { g in
            await g.discoveredPeers().count >= sharedAddrs.count
        }
        #expect(discovered, "expected discovery pool to fill from peer-sharing reply")

        let pool = await governor.discoveredPeers()
        #expect(pool.count == sharedAddrs.count)

        await teardown(governor: governor, iface: iface, nodes: [node])
    }

    // MARK: - Banning via violation

    @Test("Governor: explicit banPeer disconnects via NIO and never reconnects")
    func banPeerDisconnectsAndStaysBanned() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let (node, pid) = try await makeMock(group: group)
        let iface = NIOInterface(group: group)
        let governor = OutboundGovernor(
            interface: iface,
            handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
            promotionConfig: PromotionConfig(maxPeers: 10, maxWarmPeers: 5, maxHotPeers: 5)
        )
        await governor.start()

        await governor.includePeer(pid)
        let reached = await waitFor(governor: governor) { g in
            let counts = await g.promotionCounts()
            return counts.hot >= 1
        }
        #expect(reached)

        await governor.banPeer(pid)

        let bannedAndDisconnected = await waitFor(timeoutMillis: 2_000, governor: governor) { g in
            let counts = await g.promotionCounts()
            let snap = await g.peerSnapshot()
            let isDisconnected: Bool = {
                guard let s = snap[pid] else { return false }
                if case .disconnected = s.connection { return true }
                return false
            }()
            return counts.banned == 1 && isDisconnected
        }
        #expect(bannedAndDisconnected, "expected ban + disconnect to settle within budget")

        await teardown(governor: governor, iface: iface, nodes: [node])
    }
}
