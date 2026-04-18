import Logging
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func makeBlockBody(bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
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

// MARK: - BlockFetchClient

@Suite("BlockFetchClient", .serialized)
struct BlockFetchClientTests {

    // MARK: Empty batch

    @Test("fetch: throws BlockFetchError.emptyBatch when server has no blocks")
    func fetchEmptyRangeThrows() async throws {
        var config = MockNodeConfig()
        config.blockFetchBlocks = []  // mock will reply noBlocks

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let client = BlockFetchClient(channel: channel, demux: demux)

        do {
            _ = try await client.fetch(from: .origin, to: .origin)
            Issue.record("Expected BlockFetchError.emptyBatch but no error was thrown")
        } catch BlockFetchError.emptyBatch {
            // expected
        } catch {
            Issue.record("Expected BlockFetchError.emptyBatch, got \(error)")
        }
    }

    // MARK: Single block

    @Test("fetch: returns single block body")
    func fetchReturnsSingleBlock() async throws {
        let body = makeBlockBody(bytes: [0xDE, 0xAD, 0xBE, 0xEF])

        var config = MockNodeConfig()
        config.blockFetchBlocks = [body]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let blocks = try await BlockFetchClient(channel: channel, demux: demux)
            .fetch(from: .origin, to: .origin)

        #expect(blocks.count == 1)
        #expect(blocks[0].readableBytes == 4)
        var copy = blocks[0]
        #expect(copy.readBytes(length: 4) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    // MARK: Multiple blocks

    @Test("fetch: returns multiple block bodies in order")
    func fetchReturnsMultipleBlocks() async throws {
        let b1 = makeBlockBody(bytes: [0x01, 0x02, 0x03])
        let b2 = makeBlockBody(bytes: [0x04, 0x05])
        let b3 = makeBlockBody(bytes: [0x06])

        var config = MockNodeConfig()
        config.blockFetchBlocks = [b1, b2, b3]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let from = Point.blockPoint(slot: 1_000, hash: Array(repeating: 0xAA, count: 32))
        let to = Point.blockPoint(slot: 3_000, hash: Array(repeating: 0xBB, count: 32))
        let blocks = try await BlockFetchClient(channel: channel, demux: demux)
            .fetch(from: from, to: to)

        #expect(blocks.count == 3)
        #expect(blocks[0].readableBytes == 3)
        #expect(blocks[1].readableBytes == 2)
        #expect(blocks[2].readableBytes == 1)
    }

    // MARK: Point variants

    @Test("fetch: accepts origin-to-blockPoint range")
    func fetchOriginToBlockPoint() async throws {
        let body = makeBlockBody(bytes: [0xCA, 0xFE])

        var config = MockNodeConfig()
        config.blockFetchBlocks = [body]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let to = Point.blockPoint(slot: 990, hash: Array(repeating: 0x55, count: 32))
        let blocks = try await BlockFetchClient(channel: channel, demux: demux)
            .fetch(from: .origin, to: to)

        #expect(blocks.count == 1)
        #expect(blocks[0].readableBytes == 2)
    }

    // MARK: Empty body

    @Test("fetch: handles a zero-byte block body")
    func fetchHandlesEmptyBlockBody() async throws {
        let emptyBody = alloc.buffer(capacity: 0)

        var config = MockNodeConfig()
        config.blockFetchBlocks = [emptyBody]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let blocks = try await BlockFetchClient(channel: channel, demux: demux)
            .fetch(from: .origin, to: .origin)

        #expect(blocks.count == 1)
        #expect(blocks[0].readableBytes == 0)
    }

    // MARK: noBlocks at blockPoint range

    @Test("fetch: throws emptyBatch even when requesting a blockPoint range with no blocks")
    func fetchBlockPointRangeNoBlocks() async throws {
        var config = MockNodeConfig()
        config.blockFetchBlocks = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let from = Point.blockPoint(slot: 1_000_000, hash: Array(repeating: 0x11, count: 32))
        let to = Point.blockPoint(slot: 2_000_000, hash: Array(repeating: 0x22, count: 32))

        do {
            _ = try await BlockFetchClient(channel: channel, demux: demux).fetch(from: from, to: to)
            Issue.record("Expected BlockFetchError.emptyBatch but no error was thrown")
        } catch BlockFetchError.emptyBatch {
            // expected
        } catch {
            Issue.record("Expected BlockFetchError.emptyBatch, got \(error)")
        }
    }
}
