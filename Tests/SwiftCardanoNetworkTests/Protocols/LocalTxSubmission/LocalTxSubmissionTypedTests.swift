import Foundation
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers for integration tests

private let alloc = ByteBufferAllocator()

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

// MARK: - LocalTxSubmissionClient typed tests

@Suite("TxRejection.decode") struct TxRejectionDecodeTests {

    @Test func decodesTransactionId() throws {
        // Build a TxRejection whose reasonCBOR is a valid 32-byte CBOR bstr.
        var cbor = alloc.buffer(capacity: 34)
        cbor.writeBytes([0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32))
        let rejection = TxRejection(era: .conway, reasonCBOR: cbor)
        let txId = try rejection.decode(TransactionId.self)
        #expect(txId.payload == Data(repeating: 0xAB, count: 32))
    }

    @Test func decodeWrongTypeCBORThrows() throws {
        // Providing non-byte-string CBOR where TransactionId is expected throws.
        var cbor = alloc.buffer(capacity: 1)
        cbor.writeBytes([0x80])  // empty array — not a 32-byte bstr
        let rejection = TxRejection(era: .conway, reasonCBOR: cbor)
        #expect(throws: (any Error).self) {
            _ = try rejection.decode(TransactionId.self)
        }
    }

    @Test func decodeEmptyBufferThrows() throws {
        let cbor = alloc.buffer(capacity: 0)
        let rejection = TxRejection(era: .conway, reasonCBOR: cbor)
        #expect(throws: (any Error).self) {
            _ = try rejection.decode(TransactionId.self)
        }
    }
}

// MARK: - TypedSubmissionError

@Suite("TypedSubmissionError") struct TypedSubmissionErrorTests {

    @Test func isSendable() {
        // Compile-time proof that the type is Sendable.
        let _: any Sendable = TypedSubmissionError.missingTransactionId
    }

    @Test func isError() {
        // TypedSubmissionError must conform to Error (used in throws clauses).
        let err: any Error = TypedSubmissionError.missingTransactionId
        #expect(String(describing: err).contains("missingTransactionId"))
    }
}

// MARK: - LocalTxSubmissionClient.submit(RawTransaction) typed wrapping

@Suite("LocalTxSubmissionClient typed submit", .serialized)
struct LocalTxSubmissionClientTypedSubmitTests {

    @Test("submit(RawTransaction): accepted by mock node completes without throwing")
    func rawSubmitAcceptedNoThrow() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = true

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        // Confirm the raw submit path works (covers the non-typed submit).
        var buf = alloc.buffer(capacity: 4)
        buf.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let rawTx = RawTransaction(era: .conway, rawCBOR: buf)
        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        try await client.submit(rawTx)
    }

    @Test("submit(RawTransaction): rejected by mock node throws .rejected")
    func rawSubmitRejectedThrows() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = false

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x01, 0x02])
        let rawTx = RawTransaction(era: .conway, rawCBOR: buf)
        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        do {
            try await client.submit(rawTx)
            Issue.record("Expected rejection error")
        } catch LocalTxSubmissionError.rejected(let rejection) {
            #expect(rejection.era == .conway)
        }
    }

    // MARK: - Typed Transaction helpers

    /// Build a minimal valid `Transaction` that serialises cleanly.
    private func makeMinimalTransaction() throws -> Transaction {
        let txId = TransactionId(payload: Data(repeating: 0xAA, count: 32))
        let input = TransactionInput(transactionId: txId, index: 0)
        let keyHash = VerificationKeyHash(payload: Data(repeating: 0xBB, count: 28))
        let payment = PaymentPart.verificationKeyHash(keyHash)
        let address = try Address(paymentPart: payment, network: .testnet)
        let output = TransactionOutput(address: address, amount: Value(coin: 1_000_000))
        let body = TransactionBody(
            inputs: .list([input]),
            outputs: [output],
            fee: 250_000
        )
        let witnessSet = TransactionWitnessSet()
        return Transaction(transactionBody: body, transactionWitnessSet: witnessSet)
    }

    @Test("submit(Transaction): serialises and submits to mock; accepted without throwing")
    func submitTypedTransactionAccepted() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = true

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let tx = try makeMinimalTransaction()
        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        try await client.submit(tx)
    }

    @Test("submitChecked(Transaction): returns TransactionId when mock accepts")
    func submitCheckedTypedTransactionReturnsId() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = true

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let node = try await MockCardanoNode(config: config, group: group)
        defer { Task { try? await node.stop() } }

        let (channel, demux) = try await connectAndHandshakeNtN(port: node.port, group: group)
        defer { Task { try? await channel.close() } }

        let tx = try makeMinimalTransaction()
        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        let returnedId = try await client.submitChecked(tx)
        #expect(returnedId == tx.id!)
    }
}
