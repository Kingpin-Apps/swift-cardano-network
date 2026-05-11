import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

/// Connect to `port` via TCP, complete an NtC handshake, and return a
/// `NodeToClientConnection` ready for use.
private func connectNtC(
    port: Int,
    group: EventLoopGroup,
    networkMagic: UInt32 = 764_824_073
) async throws -> (channel: Channel, connection: NodeToClientConnection) {
    var conn = ConnectionConfig()
    conn.host = "127.0.0.1"
    conn.port = port
    let (channel, demux) = try await TCPTransport(
        config: conn,
        protocolConfig: ProtocolConfig(),
        group: group
    ).connect()
    _ = try await HandshakeClient(
        channel: channel,
        demux: demux,
        config: ProtocolConfig(),
        mode: .nodeToClient
    ).negotiate(networkMagic: networkMagic)
    return (channel, NodeToClientConnection(channel: channel, demux: demux))
}

/// Returns a mock node configured with NtC handshake mode and the given query
/// result bytes. Every ledger query returns those bytes.
private func makeNtCNode(
    resultBytes: [UInt8],
    group: EventLoopGroup
) async throws -> MockCardanoNode {
    var config = MockNodeConfig()
    config.handshakeMode = .nodeToClient
    var buf = alloc.buffer(capacity: resultBytes.count)
    buf.writeBytes(resultBytes)
    config.queryResult = RawResult(era: 6, rawCBOR: buf)
    return try await MockCardanoNode(config: config, group: group)
}

/// Returns a mock node with NtC handshake mode and an empty-map query result.
private func makeNtCNodeWithEmptyMap(
    group: EventLoopGroup,
    mempoolSlot: UInt64 = 0,
    mempoolTxs: [MempoolTx] = []
) async throws -> MockCardanoNode {
    var config = MockNodeConfig()
    config.handshakeMode = .nodeToClient
    var buf = alloc.buffer(capacity: 1)
    buf.writeBytes([0xA0])  // CBOR empty map
    config.queryResult = RawResult(era: 6, rawCBOR: buf)
    config.mempoolSlot = mempoolSlot
    config.mempoolTxs = mempoolTxs
    return try await MockCardanoNode(config: config, group: group)
}

// MARK: - NodeToClientConnection typed API tests

@Suite("NodeToClientConnection typed API", .serialized)
struct NodeToClientConnectionTypedTests {

    // MARK: - queryLedgerTip

    @Test("queryLedgerTip: returns Point.blockPoint with decoded slot and hash")
    func queryLedgerTipReturnsPoint() async throws {
        // CBOR: [5000, <32-byte hash>]
        // 0x82 = array(2), 0x19 0x13 0x88 = uint(5000), 0x58 0x20 + 32 zero bytes
        var bytes: [UInt8] = [0x82, 0x19, 0x13, 0x88, 0x58, 0x20]
        bytes += [UInt8](repeating: 0x00, count: 32)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNode(resultBytes: bytes, group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let point = try await conn.queryLedgerTip()
        guard case .blockPoint(let slot, let hash) = point else {
            Issue.record("Expected .blockPoint, got \(point)")
            return
        }
        #expect(slot == 5_000)
        #expect(hash.count == 32)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryEpochNo

    @Test("queryEpochNo: returns the UInt64 epoch number from raw CBOR")
    func queryEpochNoReturnsEpoch() async throws {
        // CBOR uint(200): 0x18 0xC8
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNode(resultBytes: [0x18, 0xC8], group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let epoch = try await conn.queryEpochNo()
        #expect(epoch == 200)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryUTxO(for addresses:)

    @Test("queryUTxO(for:) addresses: empty map returns empty UTxO array")
    func queryUTxOForAddressesReturnsEmpty() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNodeWithEmptyMap(group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let utxos = try await conn.queryUTxO(for: [] as [Address])
        #expect(utxos.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryUTxO(for inputs:)

    @Test("queryUTxO(for:) inputs: empty map returns empty UTxO array")
    func queryUTxOForTransactionInputsReturnsEmpty() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNodeWithEmptyMap(group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let utxos = try await conn.queryUTxO(for: [] as [TransactionInput])
        #expect(utxos.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - snapshotMempool

    @Test("snapshotMempool: empty mempool returns correct slot and no transactions")
    func snapshotMempoolReturnsEmptyInfo() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNodeWithEmptyMap(group: group, mempoolSlot: 77_777)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let snapshot = try await conn.snapshotMempool()
        #expect(snapshot.slotNo == 77_777)
        #expect(snapshot.txs.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - followTyped

    @Test("followTyped: returns AsyncThrowingStream — delegation compiles and runs")
    func followTypedReturnsDelegatedStream() async throws {
        // This test just confirms that the facade calls chainSync.followTyped(from:)
        // and returns an AsyncThrowingStream.  We do not iterate: the mock has no
        // NtC-ChainSync handler (protocol 5), so any iteration would stall.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNodeWithEmptyMap(group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        // Just obtain the stream — covers the `follow` delegation line.
        let _: AsyncThrowingStream<EraBlockEvent, Error> = conn.follow(from: [])

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryProtocolParameters

    @Test("queryProtocolParameters: propagates CBOR decode error through NtC facade")
    func queryProtocolParametersThrowsOnInvalidCBOR() async throws {
        // 0x01 is CBOR uint(1) — not valid ProtocolParameters CBOR.
        // The call must enter the function body and propagate the decode error.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNode(resultBytes: [0x01], group: group)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        await #expect(throws: (any Error).self) {
            _ = try await conn.queryProtocolParameters()
        }

        try? await channel.close()
        try? await node.stop()
    }
}

// MARK: - Live GovernanceState decode test

private func previewSocketReachable(path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    // Verify the node is actually running by attempting a brief connection.
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // Phase 1: write path into sun_path (exclusive borrow of addr.sun_path ends here).
    // strlcpy is BSD-only — use a bounded manual copy that works on every libc.
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let dst = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
        path.withCString { cstr in
            let max = buf.count - 1
            var i = 0
            while i < max && cstr[i] != 0 {
                dst[i] = cstr[i]
                i += 1
            }
            dst[i] = 0
        }
    }
    // Phase 2: connect (shared borrow of addr)
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result == 0
}

private let previewSocket = "/Users/hadderley/cardano/preview/socket/node.socket"

@Suite(
    "GovernanceState live decode",
    .enabled(if: previewSocketReachable(path: previewSocket), "No live preview socket"),
    .serialized
)
struct GovernanceStateLiveTests {

    @Test("queryGovernanceState: decodes fully from live preview node")
    func queryGovernanceStateDecodes() async throws {
        var connConfig = ConnectionConfig()
        connConfig.socketPath = previewSocket
        connConfig.networkMagic = 2

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var cfg = CardanoNetworkConfiguration()
        cfg.connection = connConfig
        // Conway-era queries (governanceState, ratifyState, bigLedgerPeerSnapshot)
        // require the gate at v16+ / v17+ / v19+ respectively.  Propose the full
        // modern range so we negotiate whatever the node supports and the gate
        // accepts the query.
        cfg.protocol.ntcVersions = NodeToClientVersion.allKnown

        let conn = try await CardanoNode.connectToClient(config: cfg, group: group)
        defer { Task { await conn.close() } }

        let state = try await conn.queryGovernanceState()

        // Basic sanity checks on the decoded state
        #expect(state.currentPParams.txFeeFixed > 0)
        #expect(state.constitution.anchor.anchorUrl.value.absoluteString.isEmpty == false)
        #expect(state.proposals.proposals.count >= 0)

        await conn.close()
    }
}

// MARK: - RatifyState live decode test

@Suite(
    "RatifyState live decode",
    .enabled(if: previewSocketReachable(path: previewSocket), "No live preview socket"),
    .serialized
)
struct RatifyStateLiveTests {

    @Test("queryRatifyState: decodes fully from live preview node")
    func queryRatifyStateDecodes() async throws {
        var connConfig = ConnectionConfig()
        connConfig.socketPath = previewSocket
        connConfig.networkMagic = 2

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var cfg = CardanoNetworkConfiguration()
        cfg.connection = connConfig
        // Conway-era queries (governanceState, ratifyState, bigLedgerPeerSnapshot)
        // require the gate at v16+ / v17+ / v19+ respectively.  Propose the full
        // modern range so we negotiate whatever the node supports and the gate
        // accepts the query.
        cfg.protocol.ntcVersions = NodeToClientVersion.allKnown

        let conn = try await CardanoNode.connectToClient(config: cfg, group: group)
        defer { Task { await conn.close() } }

        let state = try await conn.queryRatifyState()

        // Sanity checks
        #expect(state.enactState.treasury >= 0)
        #expect(state.enactState.currentPParams.txFeeFixed > 0)
        #expect(state.enactState.constitution.anchor.anchorUrl.value.absoluteString.isEmpty == false)
        #expect(state.delayed == false || state.delayed == true)

        await conn.close()
    }
}

// MARK: - PoolDistr live decode test

@Suite(
    "PoolDistr live decode",
    .enabled(if: previewSocketReachable(path: previewSocket), "No live preview socket"),
    .serialized
)
struct PoolDistrLiveTests {

    @Test("queryPoolDistr: decodes fully from live preview node")
    func queryPoolDistrDecodes() async throws {
        var connConfig = ConnectionConfig()
        connConfig.socketPath = previewSocket
        connConfig.networkMagic = 2

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var cfg = CardanoNetworkConfiguration()
        cfg.connection = connConfig
        cfg.protocol.ntcVersions = NodeToClientVersion.allKnown

        let conn = try await CardanoNode.connectToClient(config: cfg, group: group)
        defer { Task { await conn.close() } }

        let dist = try await conn.queryPoolDistr()

        // We expect at least one pool on a healthy preview node.
        #expect(dist.entries.isEmpty == false)
        for entry in dist.entries.prefix(5) {
            #expect(entry.poolOperator.poolKeyHash.payload.count == 28)
            #expect(entry.vrfKeyHash.payload.count == 32)
            #expect(entry.stakeDenominator > 0)
            // v2 (NtCv21+) responses populate absoluteStake; if the node
            // negotiates v21+ we should see real values.
            if conn.negotiatedVersion >= NodeToClientVersion.v21 {
                #expect(entry.absoluteStake != nil)
            }
        }
        if conn.negotiatedVersion >= NodeToClientVersion.v21 {
            #expect(dist.totalStake != nil)
            #expect((dist.totalStake ?? 0) > 0)
        }

        await conn.close()
    }
}

// MARK: - BigLedgerPeerSnapshot live decode test

@Suite(
    "BigLedgerPeerSnapshot live decode",
    .enabled(if: previewSocketReachable(path: previewSocket), "No live preview socket"),
    .serialized
)
struct BigLedgerPeerSnapshotLiveTests {

    @Test("queryBigLedgerPeerSnapshot: decodes fully from live preview node")
    func queryBigLedgerPeerSnapshotDecodes() async throws {
        var connConfig = ConnectionConfig()
        connConfig.socketPath = previewSocket
        connConfig.networkMagic = 2

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var cfg = CardanoNetworkConfiguration()
        cfg.connection = connConfig
        // Conway-era queries (governanceState, ratifyState, bigLedgerPeerSnapshot)
        // require the gate at v16+ / v17+ / v19+ respectively.  Propose the full
        // modern range so we negotiate whatever the node supports and the gate
        // accepts the query.
        cfg.protocol.ntcVersions = NodeToClientVersion.allKnown

        let conn = try await CardanoNode.connectToClient(config: cfg, group: group)
        defer { Task { await conn.close() } }

        let snapshot = try await conn.queryBigLedgerPeerSnapshot()

        #expect(snapshot.peers.isEmpty == false)
        #expect(snapshot.snapshotSlot != nil)

        var prev: Double = 0.0
        for peer in snapshot.peers {
            let acc = Double(peer.accumulatedRelativeStake.numerator) / Double(peer.accumulatedRelativeStake.denominator)
            #expect(acc > prev)
            prev = acc
            #expect(peer.relays.isEmpty == false)
            for relay in peer.relays {
                #expect(relay.address.isEmpty == false)
                #expect(relay.port > 0)
            }
        }

        await conn.close()
    }
}
