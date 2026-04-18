import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

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
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNode(resultBytes: bytes, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let point = try await conn.queryLedgerTip()
        guard case .blockPoint(let slot, let hash) = point else {
            Issue.record("Expected .blockPoint, got \(point)")
            return
        }
        #expect(slot == 5_000)
        #expect(hash.count == 32)
    }

    // MARK: - queryEpochNo

    @Test("queryEpochNo: returns the UInt64 epoch number from raw CBOR")
    func queryEpochNoReturnsEpoch() async throws {
        // CBOR uint(200): 0x18 0xC8
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNode(resultBytes: [0x18, 0xC8], group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let epoch = try await conn.queryEpochNo()
        #expect(epoch == 200)
    }

    // MARK: - queryUTxO(for addresses:)

    @Test("queryUTxO(for:) addresses: empty map returns empty UTxO array")
    func queryUTxOForAddressesReturnsEmpty() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNodeWithEmptyMap(group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let utxos = try await conn.queryUTxO(for: [] as [Address])
        #expect(utxos.isEmpty)
    }

    // MARK: - queryUTxO(for inputs:)

    @Test("queryUTxO(for:) inputs: empty map returns empty UTxO array")
    func queryUTxOForTransactionInputsReturnsEmpty() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNodeWithEmptyMap(group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let utxos = try await conn.queryUTxO(for: [] as [TransactionInput])
        #expect(utxos.isEmpty)
    }

    // MARK: - snapshotMempool

    @Test("snapshotMempool: empty mempool returns correct slot and no transactions")
    func snapshotMempoolReturnsEmptyInfo() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNodeWithEmptyMap(group: group, mempoolSlot: 77_777)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let (slotNo, txs) = try await conn.snapshotMempool()
        #expect(slotNo == 77_777)
        #expect(txs.isEmpty)
    }

    // MARK: - followTyped

    @Test("followTyped: returns AsyncThrowingStream — delegation compiles and runs")
    func followTypedReturnsDelegatedStream() async throws {
        // This test just confirms that the facade calls chainSync.followTyped(from:)
        // and returns an AsyncThrowingStream.  We do not iterate: the mock has no
        // NtC-ChainSync handler (protocol 5), so any iteration would stall.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNodeWithEmptyMap(group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        // Just obtain the stream — covers the `followTyped` delegation line.
        let _: AsyncThrowingStream<TypedChainEvent, Error> = conn.followTyped(from: [])
    }

    // MARK: - queryProtocolParameters

    @Test("queryProtocolParameters: propagates CBOR decode error through NtC facade")
    func queryProtocolParametersThrowsOnInvalidCBOR() async throws {
        // 0x01 is CBOR uint(1) — not valid ProtocolParameters CBOR.
        // The call must enter the function body and propagate the decode error.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await makeNtCNode(resultBytes: [0x01], group: group)
        defer { Task { try? await node.stop() } }

        let (channel, conn) = try await connectNtC(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        await #expect(throws: (any Error).self) {
            _ = try await conn.queryProtocolParameters()
        }
    }
}
