import Logging
import NIOCore
import NIOPosix
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func makeRawBlock(era: UInt64 = 6, bytes: [UInt8] = [0x01, 0x02]) -> RawBlock {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawBlock(era: era, rawCBOR: buf)
}

private func makeRawTx(era: Era = .conway, bytes: [UInt8] = [0xAB, 0xCD]) -> RawTransaction {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawTransaction(era: era, rawCBOR: buf)
}

private func makeMempoolTx(bytes: [UInt8]) -> MempoolTx {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return MempoolTx(rawCBOR: buf)
}

private func makeRawQuery(era: UInt16 = 6, bytes: [UInt8] = [0x80]) -> RawQuery {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawQuery(era: era, rawCBOR: buf)
}

/// Connect to `port`, complete the NtN handshake, and return `(channel, demux)`.
private func connectAndHandshake(
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

// MARK: - Integration Suite

/// Full-stack tests using `MockCardanoNode`.
///
/// Run `.serialized` so each test gets its own clean TCP connection without
/// racing on shared port state.
@Suite("Integration", .serialized)
struct IntegrationTests {

    // MARK: - Handshake

    @Test("Handshake: negotiates highest mutual version")
    func handshakeNegotiatesVersion() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        var conn = ConnectionConfig()
        conn.host = "127.0.0.1"
        conn.port = node.port

        let (channel, demux) = try await TCPTransport(
            config: conn,
            protocolConfig: ProtocolConfig(),
            group: group
        ).connect()

        let negotiated = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: ProtocolConfig(),
            mode: .nodeToNode
        ).negotiate(networkMagic: 764_824_073)

        #expect(negotiated.version == 14)
        guard case .nodeToNode(let magic, _, _, _) = negotiated.versionData else {
            Issue.record("Expected NtN version data")
            return
        }
        #expect(magic == 764_824_073)
    }

    // MARK: - ChainSync

    @Test("ChainSync: streams pre-loaded blocks as rollForward events")
    func chainSyncReceivesBlocks() async throws {
        var config = MockNodeConfig()
        config.chainSyncBlocks = [
            makeRawBlock(era: 5, bytes: [0x01]),
            makeRawBlock(era: 6, bytes: [0x02, 0x03]),
        ]
        config.chainSyncTip = Tip(
            point: .blockPoint(slot: 200, hash: Array(repeating: 0xAA, count: 32)), blockNo: 2)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let stream: AsyncThrowingStream<ChainEvent, Error> = ChainSyncClient(
            channel: channel, demux: demux
        ).follow(from: [])
        var received: [ChainEvent] = []

        for try await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }

        #expect(received.count == 2)

        guard case .rollForward(let block1, _) = received[0] else {
            Issue.record("Expected rollForward[0]")
            return
        }
        #expect(block1.era == 5)
        #expect(block1.rawCBOR.readableBytes == 1)

        guard case .rollForward(let block2, _) = received[1] else {
            Issue.record("Expected rollForward[1]")
            return
        }
        #expect(block2.era == 6)
        #expect(block2.rawCBOR.readableBytes == 2)
    }

    @Test("ChainSync: intersection not found when starting from unknown point")
    func chainSyncIntersectNotFound() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let knownPoint = Point.blockPoint(slot: 9_999_999, hash: Array(repeating: 0xFF, count: 32))
        let stream: AsyncThrowingStream<ChainEvent, Error> = ChainSyncClient(
            channel: channel, demux: demux
        ).follow(from: [knownPoint])

        do {
            for try await _ in stream { break }
            Issue.record("Expected intersectionNotFound to throw")
        } catch {
            // Mock always returns intersectNotFound for non-empty point lists.
            #expect(String(describing: error).contains("intersection") || error is ChainSyncError)
        }
    }

    @Test("ChainSync: empty block list yields awaitReply without crash")
    func chainSyncAwaitReply() async throws {
        var config = MockNodeConfig()
        config.chainSyncBlocks = []  // no blocks → server sends awaitReply

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        // Collect events with a short timeout — none should arrive.
        let stream: AsyncThrowingStream<ChainEvent, Error> = ChainSyncClient(
            channel: channel, demux: demux
        ).follow(from: [])
        let receiveTask = Task {
            var count = 0
            for try await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }

        // Cancel after 200 ms — no events should have arrived.
        try await Task.sleep(nanoseconds: 200_000_000)
        receiveTask.cancel()
        let count = (try? await receiveTask.value) ?? 0
        #expect(count == 0)
    }

    // MARK: - LocalTxSubmission

    @Test("LocalTxSubmission: accepted transaction returns without error")
    func localTxSubmissionAccepted() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = true

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        try await client.submit(makeRawTx(era: .conway, bytes: [0xDE, 0xAD, 0xBE, 0xEF]))
        // No throw → test passes
    }

    @Test("LocalTxSubmission: rejected transaction throws LocalTxSubmissionError.rejected")
    func localTxSubmissionRejected() async throws {
        var config = MockNodeConfig()
        config.acceptTransactions = false

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        do {
            try await client.submit(makeRawTx())
            Issue.record("Expected rejection error")
        } catch LocalTxSubmissionError.rejected(let rejection) {
            #expect(rejection.era == .conway)
        }
    }

    @Test("LocalTxSubmission: multiple sequential submissions each succeed")
    func localTxSubmissionMultiple() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalTxSubmissionClient(channel: channel, demux: demux)
        for i in 0..<3 {
            try await client.submit(makeRawTx(bytes: [UInt8(i)]))
        }
    }

    // MARK: - LocalStateQuery

    @Test("LocalStateQuery: query returns the mock result")
    func localStateQueryReturnsResult() async throws {
        var config = MockNodeConfig()
        var resultBuf = alloc.buffer(capacity: 3)
        resultBuf.writeBytes([0x83, 0x01, 0x02])  // CBOR [1, 2]
        config.queryResult = RawResult(era: 6, rawCBOR: resultBuf)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalStateQueryClient(channel: channel, demux: demux)
        let result = try await client.query(.raw(makeRawQuery()))

        #expect(result.era == 6)
        #expect(result.rawCBOR.readableBytes == 3)
    }

    @Test("LocalStateQuery: query at volatile tip succeeds")
    func localStateQueryAtVolatileTip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalStateQueryClient(channel: channel, demux: demux)
        let result = try await client.query(.raw(makeRawQuery()), at: .volatileTip)

        #expect(result.era == 6)
    }

    @Test("LocalStateQuery: query at specific chain point succeeds")
    func localStateQueryAtSpecificPoint() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalStateQueryClient(channel: channel, demux: demux)
        let point = AcquirePoint.specific(
            .blockPoint(slot: 1_000, hash: Array(repeating: 0x11, count: 32)))
        let result = try await client.query(.raw(makeRawQuery()), at: point)

        #expect(result.rawCBOR.readableBytes > 0)
    }

    @Test("LocalStateQuery: multiple sequential queries on same connection succeed")
    func localStateQueryMultiple() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalStateQueryClient(channel: channel, demux: demux)
        for era in [UInt16(4), 5, 6] {
            let r = try await client.query(.raw(makeRawQuery(era: era)))
            #expect(r.era == 6)  // mock always returns era 6
        }
    }

    // MARK: - LocalTxMonitor

    @Test("LocalTxMonitor: snapshot returns correct slot and transaction count")
    func localTxMonitorSnapshot() async throws {
        var config = MockNodeConfig()
        config.mempoolSlot = 77_777
        config.mempoolTxs = [
            makeMempoolTx(bytes: [0x01, 0x02]),
            makeMempoolTx(bytes: [0x03, 0x04]),
            makeMempoolTx(bytes: [0x05]),
        ]

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = LocalTxMonitorClient(channel: channel, demux: demux)
        let (slotNo, txs) = try await client.snapshot()

        #expect(slotNo == 77_777)
        #expect(txs.count == 3)
        #expect(txs[0].rawCBOR.readableBytes == 2)
        #expect(txs[2].rawCBOR.readableBytes == 1)
    }

    @Test("LocalTxMonitor: empty mempool returns zero transactions")
    func localTxMonitorEmptyMempool() async throws {
        var config = MockNodeConfig()
        config.mempoolTxs = []
        config.mempoolSlot = 1

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let (slotNo, txs) = try await LocalTxMonitorClient(channel: channel, demux: demux)
            .snapshot()
        #expect(slotNo == 1)
        #expect(txs.isEmpty)
    }

    @Test("LocalTxMonitor: capacity returns configured values")
    func localTxMonitorCapacity() async throws {
        var config = MockNodeConfig()
        config.mempoolCapacity = MempoolCapacity(
            capacityInBytes: 131_072,
            sizeInBytes: 4_096,
            numberOfTxs: 7
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let cap = try await LocalTxMonitorClient(channel: channel, demux: demux).sizes()
        #expect(cap.capacityInBytes == 131_072)
        #expect(cap.sizeInBytes == 4_096)
        #expect(cap.numberOfTxs == 7)
    }

    @Test("LocalTxMonitor: hasTx returns false for unknown transaction")
    func localTxMonitorHasTxFalse() async throws {
        var config = MockNodeConfig()
        config.mempoolTxs = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let unknownTxId: TxId = Array(repeating: 0xDE, count: 32)
        let present = try await LocalTxMonitorClient(channel: channel, demux: demux).hasTx(
            unknownTxId)
        #expect(present == false)
    }

    // MARK: - KeepAlive

    @Test("KeepAlive: probe receives matching cookie response")
    func keepAliveProbeRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        // Use a very short interval so the first probe fires quickly,
        // then cancel the task after it completes.
        let handler = KeepAliveHandler(
            channel: channel,
            demux: demux,
            intervalSeconds: 0.001,  // 1 ms
            timeoutSeconds: 5.0,
            logger: Logger(label: "test.keepalive")
        )

        let task = Task { try await handler.run() }

        // Allow time for at least one probe/response round-trip.
        try await Task.sleep(nanoseconds: 300_000_000)  // 300 ms
        task.cancel()

        // Accept CancellationError (clean exit); any other error is a test failure.
        do {
            try await task.value
        } catch is CancellationError {
            // Expected — we cancelled it.
        }
    }

    // MARK: - Multi-protocol

    @Test("Multi-protocol: handshake + txSubmit + query on same connection")
    func multiProtocolSingleConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        // Tx submission
        let txClient = LocalTxSubmissionClient(channel: channel, demux: demux)
        try await txClient.submit(makeRawTx())

        // Ledger query
        let qClient = LocalStateQueryClient(channel: channel, demux: demux)
        let result = try await qClient.query(.raw(makeRawQuery()))
        #expect(result.era == 6)

        // Mempool snapshot
        let mClient = LocalTxMonitorClient(channel: channel, demux: demux)
        let (slotNo, _) = try await mClient.snapshot()
        #expect(slotNo == 1_000)
    }
}
