import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func makeMempoolTx(bytes: [UInt8]) -> MempoolTx {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return MempoolTx(rawCBOR: buf)
}

private func connectAndHandshakeNtN(
    port: Int,
    group: EventLoopGroup
) async throws -> (Channel, DemuxHandler) {
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
        mode: .nodeToNode
    ).negotiate(networkMagic: 764_824_073)
    return (channel, demux)
}

// MARK: - MempoolTx.decode unit tests

@Suite("MempoolTx typed decoding") struct MempoolTxTypedDecodeTests {

    @Test func invalidCBORThrows() {
        // Garbage bytes must throw instead of silently producing a bad Transaction.
        let tx = makeMempoolTx(bytes: [0xFF, 0xFF, 0xFF])
        #expect(throws: (any Error).self) {
            _ = try tx.decode()
        }
    }

    @Test func emptyBufferThrows() {
        // An empty buffer is not a valid Transaction CBOR payload.
        let tx = makeMempoolTx(bytes: [])
        #expect(throws: (any Error).self) {
            _ = try tx.decode()
        }
    }

    @Test func truncatedCBORThrows() {
        // A CBOR array header with no elements following cannot decode as Transaction.
        let tx = makeMempoolTx(bytes: [0x84])  // array(4) header, no elements
        #expect(throws: (any Error).self) {
            _ = try tx.decode()
        }
    }
}

// MARK: - LocalTxMonitorClient.snapshotTyped integration tests

@Suite("LocalTxMonitorClient snapshotTyped", .serialized)
struct LocalTxMonitorClientSnapshotTypedTests {

    @Test("snapshotTyped: empty mempool returns correct slotNo and no transactions")
    func snapshotTypedEmptyMempoolReturnsCorrectInfo() async throws {
        var config = MockNodeConfig()
        config.mempoolSlot = 42_000
        config.mempoolTxs = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let (slotNo, txs) = try await LocalTxMonitorClient(
            channel: channel, demux: demux
        ).snapshotTyped()

        #expect(slotNo == 42_000)
        #expect(txs.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    @Test("snapshotTyped: mempool tx with invalid CBOR propagates decode error")
    func snapshotTypedInvalidTxCBORThrows() async throws {
        var config = MockNodeConfig()
        config.mempoolSlot = 1
        // Provide a MempoolTx whose rawCBOR cannot be decoded as a Transaction.
        config.mempoolTxs = [makeMempoolTx(bytes: [0xFF, 0xFF, 0xFF])]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let client = LocalTxMonitorClient(channel: channel, demux: demux)
        await #expect(throws: (any Error).self) {
            _ = try await client.snapshotTyped()
        }

        try? await channel.close()
        try? await node.stop()
    }

    @Test("snapshotTyped: slotNo matches the mock-configured mempool slot")
    func snapshotTypedSlotNoMatchesMockConfig() async throws {
        var config = MockNodeConfig()
        config.mempoolSlot = 999_999
        config.mempoolTxs = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let (slotNo, _) = try await LocalTxMonitorClient(
            channel: channel, demux: demux
        ).snapshotTyped()
        #expect(slotNo == 999_999)

        try? await channel.close()
        try? await node.stop()
    }
}
