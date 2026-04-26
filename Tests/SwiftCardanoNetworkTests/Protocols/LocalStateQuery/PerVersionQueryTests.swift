import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func makeNtCMock(
    maxNtcVersion: UInt16,
    group: EventLoopGroup
) async throws -> MockCardanoNode {
    var cfg = MockNodeConfig()
    cfg.handshakeMode = .nodeToClient
    cfg.maxNtcVersion = maxNtcVersion
    // RawResult will be returned for any query the gate lets through.
    var buf = alloc.buffer(capacity: 1)
    buf.writeBytes([0x80])  // CBOR empty array
    cfg.queryResult = RawResult(era: 6, rawCBOR: buf)
    return try await MockCardanoNode(config: cfg, group: group)
}

/// Connect to the mock with a configurable ntcVersions list and return the
/// finished `NodeToClientConnection` so callers can assert
/// `negotiatedVersion`.
private func connectNtCToMock(
    port: Int,
    ntcVersions: [UInt16],
    group: EventLoopGroup
) async throws -> (Channel, NodeToClientConnection) {
    var conn = ConnectionConfig()
    conn.host = "127.0.0.1"
    conn.port = port
    var proto = ProtocolConfig()
    proto.ntcVersions = ntcVersions
    let (channel, demux) = try await TCPTransport(
        config: conn,
        protocolConfig: proto,
        group: group
    ).connect()
    let negotiated = try await HandshakeClient(
        channel: channel,
        demux: demux,
        config: proto,
        mode: .nodeToClient
    ).negotiate(networkMagic: 764_824_073)
    return (channel, NodeToClientConnection(
        channel: channel,
        demux: demux,
        negotiatedVersion: negotiated.version
    ))
}

// MARK: - Per-version round-trip suite

@Suite("Per-version NtC round-trip via MockNode", .serialized)
struct PerVersionQueryTests {

    /// Verify we negotiate exactly the version the mock advertises.
    @Test(arguments: [
        NodeToClientVersion.v16,
        NodeToClientVersion.v17,
        NodeToClientVersion.v18,
        NodeToClientVersion.v19,
        NodeToClientVersion.v20,
        NodeToClientVersion.v21,
        NodeToClientVersion.v22,
        NodeToClientVersion.v23,
    ])
    func negotiatesMockMaxVersion(maxV: UInt16) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCMock(maxNtcVersion: maxV, group: group)
        let (ch, conn) = try await connectNtCToMock(
            port: node.port,
            ntcVersions: NodeToClientVersion.allKnown,
            group: group
        )
        #expect(conn.negotiatedVersion == maxV)
        try? await ch.close()
        try? await node.stop()
    }

    /// At each negotiated version, verify the gate accepts queries that should
    /// be available and rejects (with `queryNotSupported`) those that aren't —
    /// before any bytes go on the wire.
    @Test(arguments: [
        NodeToClientVersion.v16,
        NodeToClientVersion.v18,
        NodeToClientVersion.v20,
        NodeToClientVersion.v22,
        NodeToClientVersion.v23,
    ])
    func gateBehaviourAtVersion(v: UInt16) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCMock(maxNtcVersion: v, group: group)
        let (ch, conn) = try await connectNtCToMock(
            port: node.port,
            ntcVersions: NodeToClientVersion.allKnown,
            group: group
        )

        // governanceState: requires v16+, expected supported at every v in this matrix.
        let govQuery = try LedgerQuery.governanceState(at: conn.negotiatedVersion)
        _ = govQuery  // building the query is enough; the test asserts no throw.

        // ratifyState: v17+. v16 should refuse before sending.
        if v >= NodeToClientVersion.v17 {
            _ = try LedgerQuery.ratifyState(at: conn.negotiatedVersion)
        } else {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.ratifyState(at: conn.negotiatedVersion)
            }
        }

        // futurePParams: v18+.
        if v >= NodeToClientVersion.v18 {
            _ = try LedgerQuery.futurePParams(at: conn.negotiatedVersion)
        } else {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.futurePParams(at: conn.negotiatedVersion)
            }
        }

        // bigLedgerPeerSnapshot: v19+; encoding switches at v23.
        if v >= NodeToClientVersion.v19 {
            let q = try LedgerQuery.bigLedgerPeerSnapshot(at: conn.negotiatedVersion)
            var b = q.rawQuery.rawCBOR
            let bytes = b.readBytes(length: b.readableBytes) ?? []
            if v >= NodeToClientVersion.v23 {
                #expect(bytes == [0x82, 0x18, 0x22, 0x01], "v23+ should emit SRV form")
            } else {
                #expect(bytes == [0x81, 0x18, 0x22], "v19..v22 should emit legacy form")
            }
        } else {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.bigLedgerPeerSnapshot(at: conn.negotiatedVersion)
            }
        }

        // proposedProtocolParametersUpdates: removed at v20+.
        if v >= NodeToClientVersion.v20 {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.proposedProtocolParametersUpdates(at: conn.negotiatedVersion)
            }
        } else {
            _ = try LedgerQuery.proposedProtocolParametersUpdates(at: conn.negotiatedVersion)
        }

        // stakeDistribution: encoder picks tag 5 below v21, tag 37 at v21+.
        let sd = LedgerQuery.stakeDistribution(at: conn.negotiatedVersion)
        var sdb = sd.rawQuery.rawCBOR
        let sdBytes = sdb.readBytes(length: sdb.readableBytes) ?? []
        if v >= NodeToClientVersion.v21 {
            #expect(sdBytes == [0x81, 0x18, 0x25], "v21+ should emit tag 37")
        } else {
            #expect(sdBytes == [0x81, 0x05], "v9..v20 should emit tag 5")
        }

        // poolDistr: encoder picks tag 21 below v21, tag 36 at v21+.
        let pd = try LedgerQuery.poolDistr(nil, at: conn.negotiatedVersion)
        var pdb = pd.rawQuery.rawCBOR
        let pdBytes = pdb.readBytes(length: pdb.readableBytes) ?? []
        if v >= NodeToClientVersion.v21 {
            #expect(pdBytes == [0x82, 0x18, 0x24, 0x80], "v21+ should emit tag 36")
        } else {
            #expect(pdBytes == [0x82, 0x15, 0x80], "v9..v20 should emit tag 21")
        }

        // maxMajorProtocolVersion: v21+.
        if v >= NodeToClientVersion.v21 {
            _ = try LedgerQuery.maxMajorProtocolVersion(at: conn.negotiatedVersion)
        } else {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.maxMajorProtocolVersion(at: conn.negotiatedVersion)
            }
        }

        // drepDelegations: v23+.
        if v >= NodeToClientVersion.v23 {
            _ = try LedgerQuery.drepDelegations([], at: conn.negotiatedVersion)
        } else {
            #expect(throws: LocalStateQueryError.self) {
                _ = try LedgerQuery.drepDelegations([], at: conn.negotiatedVersion)
            }
        }

        try? await ch.close()
        try? await node.stop()
    }
}
