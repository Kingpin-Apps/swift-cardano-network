import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

/// Encode an era-tagged block buffer: `[era, #6.24(blockBytes)]` (Shelley+).
private func makeEraTaggedBlock(era: UInt64, bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: 16 + bytes.count)
    CBORLite.writeArrayHeader(count: 2, into: &buf)
    CBORLite.writeUInt(era, into: &buf)
    CBORLite.writeTag(24, into: &buf)
    CBORLite.writeByteString(bytes, into: &buf)
    return buf
}

/// Encode an era-tagged block buffer without tag-24 (Byron / fallback): `[era, bstr]`.
private func makeEraTaggedBlockRaw(era: UInt64, bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: 8 + bytes.count)
    CBORLite.writeArrayHeader(count: 2, into: &buf)
    CBORLite.writeUInt(era, into: &buf)
    CBORLite.writeByteString(bytes, into: &buf)
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

// MARK: - BlockFetchClient typed tests

@Suite("BlockFetchClient.fetchBlocks", .serialized)
struct BlockFetchTypedTests {

    // MARK: Empty batch propagation

    @Test("fetchBlocks: propagates BlockFetchError.emptyBatch when server has no blocks")
    func fetchBlocksEmptyRangeThrows() async throws {
        var config = MockNodeConfig()
        config.blockFetchBlocks = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let client = BlockFetchClient(channel: channel, demux: demux)

        do {
            let _: [EraBlock] = try await client.fetch(from: .origin, to: .origin)
            Issue.record("Expected BlockFetchError.emptyBatch but no error was thrown")
        } catch BlockFetchError.emptyBatch {
            // expected
        } catch {
            Issue.record("Expected BlockFetchError.emptyBatch, got \(error)")
        }

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: Malformed era wrapper

    @Test("fetchBlocks: throws BlockFetchDecodeError when era wrapper is not a 2-element array")
    func fetchBlocksMalformedEraWrapperThrows() async throws {
        // A 1-element CBOR array — not a valid era-tagged block.
        var malformed = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 1, into: &malformed)
        CBORLite.writeUInt(6, into: &malformed)

        var config = MockNodeConfig()
        config.blockFetchBlocks = [malformed]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let client = BlockFetchClient(channel: channel, demux: demux)

        do {
            let _: [EraBlock] = try await client.fetch(from: .origin, to: .origin)
            Issue.record("Expected BlockFetchDecodeError but no error was thrown")
        } catch BlockFetchDecodeError.unexpectedEraWrapperLength(let len) {
            #expect(len == 1)
        } catch {
            Issue.record("Expected BlockFetchDecodeError.unexpectedEraWrapperLength, got \(error)")
        }

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: Era extraction (tag-24 path)

    @Test("fetchBlocks: extracts era from tag-24 wrapped block (Shelley+)")
    func fetchBlocksExtractsEraFromTag24Block() async throws {
        // Provide a [6, #6.24(garbage)] buffer — era extraction must succeed and
        // the error (if any) must come from EraBlock decode, not BlockFetchDecodeError.
        let block = makeEraTaggedBlock(era: 6, bytes: [0xDE, 0xAD, 0xBE, 0xEF])

        var config = MockNodeConfig()
        config.blockFetchBlocks = [block]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let client = BlockFetchClient(channel: channel, demux: demux)

        // The mock block bytes are not valid Conway block CBOR, so decodeEra() will throw.
        // What matters is that it does NOT throw BlockFetchDecodeError — that would indicate
        // the era wrapper parsing failed, not the block decode.
        do {
            let _: [EraBlock] = try await client.fetch(from: .origin, to: .origin)
        } catch is BlockFetchDecodeError {
            Issue.record("Era extraction should have succeeded; got BlockFetchDecodeError")
        } catch {
            // Expected: CardanoCoreError or similar from EraBlock.fromBlockCBOR — era was parsed OK.
        }

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: Era extraction (raw bytes path)

    @Test("fetchBlocks: extracts era from raw byte-string block (Byron fallback)")
    func fetchBlocksExtractsEraFromRawBlock() async throws {
        let block = makeEraTaggedBlockRaw(era: 0, bytes: [0x01, 0x02, 0x03])

        var config = MockNodeConfig()
        config.blockFetchBlocks = [block]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)

        let client = BlockFetchClient(channel: channel, demux: demux)

        do {
            let _: [EraBlock] = try await client.fetch(from: .origin, to: .origin)
        } catch is BlockFetchDecodeError {
            Issue.record("Era extraction should have succeeded; got BlockFetchDecodeError")
        } catch {
            // Expected: CardanoCoreError from EraBlock.fromBlockCBOR — era was parsed OK.
        }

        try? await channel.close()
        try? await node.stop()
    }
}
