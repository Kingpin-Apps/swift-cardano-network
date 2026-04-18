import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Test doubles

/// Records each call made by the TxSubmission2 serve loop.
private actor RecordingMempool: TxSubmissionProvider {
    private(set) var txIdsRequestCount = 0
    private(set) var txsRequestCount = 0
    private(set) var lastBlockingFlag: Bool?
    private(set) var lastAckCount: UInt16?
    private(set) var lastReqCount: UInt16?
    private(set) var lastRequestedIds: [TxId] = []

    private var txIdsToReturn: [TxIdWithSize] = []
    private var txBodiesToReturn: [ByteBuffer] = []

    func setTxIds(_ ids: [TxIdWithSize]) { txIdsToReturn = ids }
    func setTxBodies(_ bodies: [ByteBuffer]) { txBodiesToReturn = bodies }

    func requestTxIds(
        blocking: Bool,
        ackCount: UInt16,
        reqCount: UInt16
    ) async throws -> [TxIdWithSize] {
        txIdsRequestCount += 1
        lastBlockingFlag = blocking
        lastAckCount = ackCount
        lastReqCount = reqCount
        return txIdsToReturn
    }

    func requestTxs(_ ids: [TxId]) async throws -> [ByteBuffer] {
        txsRequestCount += 1
        lastRequestedIds = ids
        return txBodiesToReturn
    }
}

/// Always returns empty collections.
private struct EmptyMempool: TxSubmissionProvider {
    func requestTxIds(blocking: Bool, ackCount: UInt16, reqCount: UInt16) async throws
        -> [TxIdWithSize]
    { [] }
    func requestTxs(_ ids: [TxId]) async throws -> [ByteBuffer] { [] }
}

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = TxSubmission2Codec()
private let testLogger = Logger(label: "test.txsubmission2")

/// Build a NIOAsyncTestingChannel + DemuxHandler pair ready for TxSubmission2Client tests.
///
/// `NIOAsyncTestingChannel` uses a lock-based event loop, so channel operations
/// inside `ProtocolDriver` (an actor) are safe regardless of which thread they
/// originate from — unlike `EmbeddedChannel` which asserts on its creating thread.
private func makeChannel() async throws -> (NIOAsyncTestingChannel, DemuxHandler) {
    let ch = NIOAsyncTestingChannel()
    let demux = DemuxHandler(logger: testLogger)
    try await ch.pipeline.addHandler(demux)
    return (ch, demux)
}

/// Encode `msg` as a server-side TxSubmission2 SDU and inject it into the channel's
/// inbound pipeline so that the registered DemuxHandler stream receives it.
///
/// Must be called after the client's `makeDriver()` has run (i.e. after at least two
/// `await Task.yield()` calls following `Task { try await client.run(...) }`).
private func injectServer(_ msg: TxSubmission2Message, into ch: NIOAsyncTestingChannel)
    async throws
{
    let payload = try codec.encode(msg, allocator: ch.allocator)
    // Server sets the responder mode-bit (0x8000); DemuxHandler strips it when routing.
    let sdu = MuxSDU(
        timestamp: 0,
        protocolID: MuxSDU.ProtocolID.txSubmission2 | 0x8000,
        payload: payload
    )
    try await ch.writeInbound(sdu)
}

/// Drain any unconsumed outbound MuxSDUs, then finish the channel so NIO's deinit
/// assertion is satisfied.
private func cleanUp(_ ch: NIOAsyncTestingChannel) async {
    while (try? await ch.readOutbound(as: MuxSDU.self)) != nil {}
    _ = try? await ch.finish()
}

private func makeTxId(byte: UInt8 = 0xAB) -> TxId {
    Array(repeating: byte, count: 32)
}

// MARK: - TxSubmission2Client
//
// TxSubmission2 is **server-initiated**: the remote peer (server) sends the first
// message. This creates a race when using MockCardanoNode over TCP because the
// server may send before the client has called `makeDriver()` and registered its
// inbound stream. The lost SDU would cause `run()` to hang forever.
//
// All tests here use NIOAsyncTestingChannel to bypass the race:
//   1. Create NIOAsyncTestingChannel + DemuxHandler.
//   2. Start `client.run()` in a background Task.
//   3. `await Task.yield()` twice — the cooperative scheduler lets `run()` execute
//      until its first suspension point (inside `driver.receive()`). By then
//      `makeDriver()` has already registered the stream.
//   4. Inject server messages via `injectServer(_:into:)`. AsyncStream's unbounded
//      buffer means we can inject all messages before the client has consumed any of
//      them and they will be processed in order.
//   5. Await the task, then drain + close the channel.

@Suite("TxSubmission2Client")
struct TxSubmission2ClientTests {

    // MARK: - Done immediately

    @Test("run: returns cleanly when peer sends MsgDone immediately")
    func runCompletesOnDoneImmediately() async throws {
        let (ch, demux) = try await makeChannel()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: EmptyMempool()) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.done, into: ch)
        try await runTask.value  // must complete without throwing
        await cleanUp(ch)
    }

    @Test("run: provider is never called when peer sends MsgDone immediately")
    func runProviderNotCalledOnDoneImmediately() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.done, into: ch)
        try await runTask.value

        #expect(await mempool.txIdsRequestCount == 0)
        #expect(await mempool.txsRequestCount == 0)
        await cleanUp(ch)
    }

    // MARK: - requestTxIds round-trip

    @Test("run: calls provider and sends replyTxIds when peer sends requestTxIds")
    func runRepliesWithTxIds() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        await mempool.setTxIds([TxIdWithSize(id: makeTxId(byte: 0xCC), size: 256)])
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        // Buffer both messages; AsyncStream delivers them in order.
        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 5), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.txIdsRequestCount == 1)
        await cleanUp(ch)
    }

    @Test("run: correctly forwards blocking=true to provider")
    func runForwardsBlockingTrueFlag() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxIds(blocking: true, ackCount: 2, reqCount: 4), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.lastBlockingFlag == true)
        #expect(await mempool.lastAckCount == 2)
        #expect(await mempool.lastReqCount == 4)
        await cleanUp(ch)
    }

    @Test("run: correctly forwards blocking=false to provider")
    func runForwardsBlockingFalseFlag() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 3), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.lastBlockingFlag == false)
        await cleanUp(ch)
    }

    @Test("run: requestTxIds with empty provider reply is valid")
    func runRepliesEmptyTxIds() async throws {
        let (ch, demux) = try await makeChannel()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: EmptyMempool()) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 10), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value
        await cleanUp(ch)
    }

    // MARK: - requestTxs round-trip

    @Test("run: calls provider and sends replyTxs when peer sends requestTxs")
    func runRepliesToRequestTxs() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        var txBody = alloc.buffer(capacity: 2)
        txBody.writeBytes([0xAB, 0xCD])
        await mempool.setTxBodies([txBody])
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let txId = makeTxId(byte: 0x11)
        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxs([txId]), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.txsRequestCount == 1)
        let requested = await mempool.lastRequestedIds
        #expect(requested.count == 1)
        #expect(requested[0] == txId)
        await cleanUp(ch)
    }

    @Test("run: requestTxs with empty provider body reply is valid")
    func runRepliesToRequestTxsEmpty() async throws {
        let (ch, demux) = try await makeChannel()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: EmptyMempool()) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxs([makeTxId(byte: 0x22)]), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value
        await cleanUp(ch)
    }

    // MARK: - Multiple rounds

    @Test("run: handles multiple requestTxIds rounds before done")
    func runHandlesMultipleRequestTxIdsRounds() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        // Buffer all three server messages up front; the client processes them sequentially.
        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 3), into: ch)
        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 2), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.txIdsRequestCount == 2)
        await cleanUp(ch)
    }

    @Test("run: handles requestTxIds followed by requestTxs then done")
    func runHandlesIdsThenBodiesRounds() async throws {
        let (ch, demux) = try await makeChannel()
        let mempool = RecordingMempool()
        let txId = makeTxId(byte: 0x55)
        await mempool.setTxIds([TxIdWithSize(id: txId, size: 64)])
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: mempool) }
        await Task.yield()
        await Task.yield()

        try await injectServer(.requestTxIds(blocking: false, ackCount: 0, reqCount: 5), into: ch)
        try await injectServer(.requestTxs([txId]), into: ch)
        try await injectServer(.done, into: ch)

        try await runTask.value

        #expect(await mempool.txIdsRequestCount == 1)
        #expect(await mempool.txsRequestCount == 1)
        await cleanUp(ch)
    }

    // MARK: - Cancellation

    @Test("run: exits when task is cancelled while waiting for a message")
    func runRespondsToTaskCancellation() async throws {
        let (ch, demux) = try await makeChannel()
        let client = TxSubmission2Client(channel: ch, demux: demux)

        let runTask = Task { try await client.run(provider: EmptyMempool()) }
        await Task.yield()
        await Task.yield()

        // Cancel while the client is suspended in driver.receive().
        // AsyncStream.next() returns nil on cancellation; ProtocolDriver then
        // throws CancellationError. Both outcomes are acceptable.
        runTask.cancel()
        _ = try? await runTask.value
        await cleanUp(ch)
    }
}
