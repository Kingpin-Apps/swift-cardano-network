import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func rawBuf(_ bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

/// Connect to `port` via TCP, complete an NtN handshake, and return a
/// `NodeToNodeConnection` ready for use.
private func connectNtN(
    port: Int,
    group: EventLoopGroup,
    networkMagic: UInt32 = 764_824_073
) async throws -> (channel: Channel, connection: NodeToNodeConnection) {
    var conn = ConnectionConfig()
    conn.host = "127.0.0.1"
    conn.port = port
    let protocolConfig = ProtocolConfig()
    let (channel, demux) = try await TCPTransport(
        config: conn,
        protocolConfig: protocolConfig,
        group: group
    ).connect()
    let connection = NodeToNodeConnection(channel: channel, demux: demux, protocolConfig: protocolConfig)
    _ = try await HandshakeClient(
        channel: channel,
        demux: demux,
        config: protocolConfig,
        mode: .nodeToNode
    ).negotiate(networkMagic: networkMagic)
    return (channel, connection)
}

// MARK: - BlockFetch shortcut

@Suite("NodeToNodeConnection BlockFetch shortcut", .serialized)
struct NodeToNodeConnectionBlockFetchShortcutTests {

    @Test("fetch: returns configured block bodies from mock")
    func fetchReturnsConfiguredBlocks() async throws {
        var config = MockNodeConfig()
        config.blockFetchBlocks = [
            rawBuf([0xAA, 0xBB]),
            rawBuf([0xCC, 0xDD, 0xEE]),
        ]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (_, conn) = try await connectNtN(port: node.port, group: group)

        let start = Point.blockPoint(slot: 1_000, hash: Array(repeating: 0x11, count: 32))
        let end = Point.blockPoint(slot: 1_001, hash: Array(repeating: 0x22, count: 32))

        let blocks: [ByteBuffer] = try await conn.blockFetch.fetch(from: start, to: end)
        #expect(blocks.count == 2)
        #expect(blocks[0].readableBytes == 2)
        #expect(blocks[1].readableBytes == 3)

        await conn.close()
        try? await node.stop()
    }

    @Test("fetch: empty configuration throws BlockFetchError.emptyBatch")
    func fetchEmptyThrows() async throws {
        var config = MockNodeConfig()
        config.blockFetchBlocks = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (_, conn) = try await connectNtN(port: node.port, group: group)

        let start = Point.blockPoint(slot: 1, hash: Array(repeating: 0x11, count: 32))
        let end = Point.blockPoint(slot: 2, hash: Array(repeating: 0x22, count: 32))

        await #expect(throws: BlockFetchError.self) {
            let _: [ByteBuffer] = try await conn.blockFetch.fetch(from: start, to: end)
        }

        await conn.close()
        try? await node.stop()
    }
}

// MARK: - TxSubmission2 shortcut

/// A trivial provider that records whether it was invoked; the default mock
/// behaviour is `doneImmediately`, so no methods will actually be called.
private struct NoOpProvider: TxSubmissionProvider {
    func requestTxIds(
        blocking: Bool,
        ackCount: UInt16,
        reqCount: UInt16
    ) async throws -> [TxIdWithSize] { [] }

    func requestTxs(_ ids: [TxId]) async throws -> [ByteBuffer] { [] }
}

@Suite("NodeToNodeConnection TxSubmission2 shortcut", .serialized)
struct NodeToNodeConnectionTxSubmission2ShortcutTests {

    @Test("serveTransactions: returns cleanly when remote sends done immediately")
    func serveTransactionsTerminatesOnDone() async throws {
        var config = MockNodeConfig()
        config.txSubmission2Behavior = .doneImmediately

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (_, conn) = try await connectNtN(port: node.port, group: group)

        try await conn.serveTransactions(provider: NoOpProvider())

        await conn.close()
        try? await node.stop()
    }
}

// MARK: - follow (existing shortcut — sanity check)

@Suite("NodeToNodeConnection follow shortcut", .serialized)
struct NodeToNodeConnectionFollowShortcutTests {

    @Test("follow: returns AsyncThrowingStream and delegates to chainSync")
    func followReturnsStream() async throws {
        let config = MockNodeConfig()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        let (_, conn) = try await connectNtN(port: node.port, group: group)

        let _: AsyncThrowingStream<EraHeaderEvent, Error> = conn.follow(from: [])

        await conn.close()
        try? await node.stop()
    }
}
