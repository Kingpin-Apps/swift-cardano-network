import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func rawBuf(_ bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

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

private func makeNtCNode(
    group: EventLoopGroup,
    config: inout MockNodeConfig
) async throws -> MockCardanoNode {
    config.handshakeMode = .nodeToClient
    return try await MockCardanoNode(config: config, group: group)
}

// MARK: - Mempool extras suite

@Suite("NodeToClientConnection mempool shortcuts", .serialized)
struct NodeToClientConnectionMempoolShortcutsTests {

    @Test("hasTx: returns false for unknown tx")
    func hasTxReturnsFalse() async throws {
        var config = MockNodeConfig()
        config.mempoolTxs = []
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNode(group: group, config: &config)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let txId = TransactionId(payload: Data(repeating: 0xAB, count: 32))
        let present = try await conn.hasTx(txId)
        #expect(present == false)

        try? await channel.close()
        try? await node.stop()
    }

    @Test("mempoolSizes: returns configured capacity values")
    func mempoolSizesReturnsConfigured() async throws {
        var config = MockNodeConfig()
        config.mempoolCapacity = MempoolCapacity(
            capacityInBytes: 262_144,
            sizeInBytes: 8_192,
            numberOfTxs: 13
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNtCNode(group: group, config: &config)

        let (channel, conn) = try await connectNtC(port: node.port, group: group)

        let cap = try await conn.mempoolSizes()
        #expect(cap.capacityInBytes == 262_144)
        #expect(cap.sizeInBytes == 8_192)
        #expect(cap.numberOfTxs == 13)

        try? await channel.close()
        try? await node.stop()
    }
}
