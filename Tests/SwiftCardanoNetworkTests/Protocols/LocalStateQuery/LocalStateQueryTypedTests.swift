import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers for integration tests

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

// MARK: - RawResult.decode and RawResult.decodeUTxOs unit tests
//
// These tests exercise the typed result decoding helpers without a live node
// by constructing synthetic CBOR payloads that mirror the Ouroboros wire format.

private let alloc = ByteBufferAllocator()

// MARK: - RawResult.decode generic helper

@Suite("RawResult.decode") struct RawResultDecodeTests {

    @Test func decodeForwardsToSwiftCardanoCore() throws {
        // TransactionId is a 32-byte ConstrainedBytes that conforms to CBORSerializable.
        // Build a valid CBOR byte string of 32 zero bytes (the CBOR encoding of a
        // TransactionId with all-zero bytes).
        var cbor = alloc.buffer(capacity: 34)
        // CBOR byte string of length 32: 0x58 0x20 + 32 bytes
        cbor.writeBytes([0x58, 0x20] + [UInt8](repeating: 0x00, count: 32))
        let result = RawResult(era: 6, rawCBOR: cbor)
        let txId = try result.decode(TransactionId.self)
        #expect(txId.payload == Data(repeating: 0x00, count: 32))
    }
}

// MARK: - RawResult.decodeUTxOs

@Suite("RawResult.decodeUTxOs") struct RawResultDecodeUTxOsTests {

    @Test func emptyMapDecodesAsEmptyArray() throws {
        // CBOR empty map: 0xA0
        var cbor = alloc.buffer(capacity: 1)
        cbor.writeBytes([0xA0])
        let result = RawResult(era: 6, rawCBOR: cbor)
        let utxos = try result.decodeUTxOs()
        #expect(utxos.isEmpty)
    }

    @Test func taggedEmptyMapDecodesAsEmptyArray() throws {
        // CBOR Tag 258 wrapping empty map: 0xD9 0x01 0x02  0xA0
        var cbor = alloc.buffer(capacity: 4)
        cbor.writeBytes([0xD9, 0x01, 0x02, 0xA0])
        let result = RawResult(era: 6, rawCBOR: cbor)
        let utxos = try result.decodeUTxOs()
        #expect(utxos.isEmpty)
    }
}

// MARK: - CBORLite.readValueBuffer

@Suite("CBORLite.readValueBuffer") struct ReadValueBufferTests {

    @Test func capturesUInt() throws {
        // writeUInt(7) fits in 1 byte (7 <= 23: 0x07)
        // writeUInt(9) fits in 1 byte (9 <= 23: 0x09)
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeUInt(7, into: &buf)
        CBORLite.writeUInt(9, into: &buf)
        let slice = try CBORLite.readValueBuffer(from: &buf)
        // slice contains just the first value
        #expect(slice.readableBytes == 1)
        var s = slice
        let v = try CBORLite.readUInt(from: &s)
        #expect(v == 7)
        // Remaining in original
        #expect(buf.readableBytes == 1)
    }

    @Test func capturesArray() throws {
        var buf = alloc.buffer(capacity: 8)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(1, into: &buf)
        CBORLite.writeUInt(2, into: &buf)
        CBORLite.writeUInt(5, into: &buf)  // sentinel (5 <= 23: 1 byte)
        let slice = try CBORLite.readValueBuffer(from: &buf)
        #expect(slice.readableBytes == 3)  // [1, 2] encodes to 3 bytes
        #expect(buf.readableBytes == 1)  // sentinel remains
    }

    @Test func capturesByteString() throws {
        var buf = alloc.buffer(capacity: 10)
        CBORLite.writeByteString([0xAA, 0xBB], into: &buf)
        let slice = try CBORLite.readValueBuffer(from: &buf)
        // byte string header (1 byte) + 2 data bytes = 3 bytes
        #expect(slice.readableBytes == 3)
    }

    @Test func capturesNestedMap() throws {
        var buf = alloc.buffer(capacity: 16)
        CBORLite.writeMapHeader(count: 1, into: &buf)
        CBORLite.writeUInt(0, into: &buf)
        CBORLite.writeUInt(1, into: &buf)
        CBORLite.writeUInt(9, into: &buf)  // sentinel
        let slice = try CBORLite.readValueBuffer(from: &buf)
        // map(1) + key(0) + value(1) = 3 bytes
        #expect(slice.readableBytes == 3)
        #expect(buf.readableBytes == 1)
    }
}

// MARK: - RawResult.decodeUTxOs additional unit tests

@Suite("RawResult.decodeUTxOs extended") struct RawResultDecodeUTxOsExtendedTests {

    @Test func invalidCBORThrows() throws {
        // Non-map CBOR should throw when attempting to read a map header.
        var cbor = alloc.buffer(capacity: 3)
        cbor.writeBytes([0xFF, 0xFF, 0xFF])  // garbage
        let result = RawResult(era: 6, rawCBOR: cbor)
        #expect(throws: (any Error).self) {
            _ = try result.decodeUTxOs()
        }
    }

    @Test func truncatedMapThrows() throws {
        // A map header claiming 1 pair but no data throws.
        var cbor = alloc.buffer(capacity: 1)
        cbor.writeBytes([0xA1])  // CBOR map(1), no key/value bytes
        let result = RawResult(era: 6, rawCBOR: cbor)
        #expect(throws: (any Error).self) {
            _ = try result.decodeUTxOs()
        }
    }
}

// MARK: - RawResult.decode error cases

@Suite("RawResult.decode errors") struct RawResultDecodeErrorTests {

    @Test func wrongTypeCBORThrows() throws {
        // Providing array CBOR where a byte-string (TransactionId) is expected throws.
        var cbor = alloc.buffer(capacity: 1)
        cbor.writeBytes([0x80])  // CBOR empty array — not a valid TransactionId
        let result = RawResult(era: 6, rawCBOR: cbor)
        #expect(throws: (any Error).self) {
            _ = try result.decode(TransactionId.self)
        }
    }
}

// MARK: - LocalStateQueryClient typed methods — integration tests

@Suite("LocalStateQueryClient typed API", .serialized)
struct LocalStateQueryClientTypedTests {

    // MARK: - Helpers

    /// Builds a mock node whose every query response is `resultBytes`.
    private func makeNode(
        resultBytes: [UInt8],
        group: EventLoopGroup
    ) async throws -> MockCardanoNode {
        var config = MockNodeConfig()
        var buf = alloc.buffer(capacity: resultBytes.count)
        buf.writeBytes(resultBytes)
        config.queryResult = RawResult(era: 6, rawCBOR: buf)
        return try await MockCardanoNode(config: config, group: group)
    }

    private func makeClient(
        port: Int,
        group: EventLoopGroup
    ) async throws -> (channel: Channel, client: LocalStateQueryClient) {
        let (channel, demux) = try await connectAndHandshakeNtN(port: port, group: group)
        return (channel, LocalStateQueryClient(channel: channel, demux: demux))
    }

    // MARK: - queryLedgerTip

    @Test("queryLedgerTip: returns Point.blockPoint for valid CBOR response")
    func queryLedgerTipReturnsPoint() async throws {
        // CBOR: [5000, <32-byte hash>]
        // 0x82 = array(2)
        // 0x19 0x13 0x88 = uint(5000)
        // 0x58 0x20 = bstr(32) + 32 zero bytes
        var bytes: [UInt8] = [0x82, 0x19, 0x13, 0x88, 0x58, 0x20]
        bytes += [UInt8](repeating: 0x00, count: 32)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: bytes, group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        let point = try await client.queryLedgerTip()
        guard case .blockPoint(let slot, let hash) = point else {
            Issue.record("Expected .blockPoint, got \(point)")
            return
        }
        #expect(slot == 5_000)
        #expect(hash.count == 32)

        try? await channel.close()
        try? await node.stop()
    }

    @Test("queryLedgerTip: wrong array length throws unexpectedArrayLength")
    func queryLedgerTipWrongArrayLengthThrows() async throws {
        // CBOR: [0] — array of 1, but 2 elements are required
        let bytes: [UInt8] = [0x81, 0x00]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: bytes, group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        do {
            _ = try await client.queryLedgerTip()
            Issue.record("Expected unexpectedArrayLength error")
        } catch LocalStateQueryError.unexpectedArrayLength(let count) {
            #expect(count == 1)
        }

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryEpochNo

    @Test("queryEpochNo: returns the decoded UInt64 epoch number")
    func queryEpochNoReturnsEpoch() async throws {
        // CBOR uint(100): 0x18 0x64
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: [0x18, 0x64], group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        let epoch = try await client.queryEpochNo()
        #expect(epoch == 100)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryUTxO(for addresses:)

    @Test("queryUTxO(for addresses:): empty CBOR map returns empty UTxO array")
    func queryUTxOForAddressesEmptyResult() async throws {
        // CBOR: 0xA0 = empty map
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: [0xA0], group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        let utxos = try await client.queryUTxO(for: [] as [Address])
        #expect(utxos.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryUTxO(for inputs:)

    @Test("queryUTxO(for inputs:): empty CBOR map returns empty UTxO array")
    func queryUTxOForInputsEmptyResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: [0xA0], group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        let utxos = try await client.queryUTxO(for: [] as [TransactionInput])
        #expect(utxos.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryPoolDistr

    @Test("queryPoolDistr: decodes an empty pool distribution map")
    func queryPoolDistrDecodesEmptyMap() async throws {
        let payload: [UInt8] = [0xa0]  // CBOR empty map {}
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: payload, group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        let result = try await client.queryPoolDistr()
        #expect(result.entries.isEmpty)

        try? await channel.close()
        try? await node.stop()
    }

    // MARK: - queryGovernanceState

    @Test("queryGovernanceState: throws on invalid CBOR payload")
    func queryGovernanceStateThrowsOnInvalidPayload() async throws {
        // GovernanceState now requires a list[7]; an empty map is an invalid payload.
        let payload: [UInt8] = [0xa0]  // CBOR empty map — not a valid GovernanceState
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await makeNode(resultBytes: payload, group: group)
        let (channel, client) = try await makeClient(port: node.port, group: group)

        await #expect(throws: (any Error).self) {
            _ = try await client.queryGovernanceState()
        }

        try? await channel.close()
        try? await node.stop()
    }
}

// LocalStateQueryClientProtocolParamsTests is kept outside .serialized suite to avoid
// timeout interference when ProtocolParameters decode throws synchronously.

@Suite("LocalStateQueryClient queryProtocolParameters")
struct LocalStateQueryClientProtocolParamsTests {

    @Test("queryProtocolParameters: propagates CBOR decode error for invalid response")
    func queryProtocolParametersThrowsOnInvalidCBOR() async throws {
        // 0x01 is valid CBOR uint(1) but ProtocolParameters expects a map — throws.
        var config = MockNodeConfig()
        var buf = ByteBufferAllocator().buffer(capacity: 1)
        buf.writeBytes([0x01])
        config.queryResult = RawResult(era: 6, rawCBOR: buf)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }
        let node = try await MockCardanoNode(config: config, group: group)

        var connConfig = ConnectionConfig()
        connConfig.host = "127.0.0.1"
        connConfig.port = node.port
        let (channel, demux) = try await TCPTransport(
            config: connConfig,
            protocolConfig: ProtocolConfig(),
            group: group
        ).connect()
        _ = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: ProtocolConfig(),
            mode: .nodeToNode
        ).negotiate(networkMagic: 764_824_073)

        let client = LocalStateQueryClient(channel: channel, demux: demux)
        await #expect(throws: (any Error).self) {
            _ = try await client.queryProtocolParameters()
        }

        try? await channel.close()
        try? await node.stop()
    }
}
