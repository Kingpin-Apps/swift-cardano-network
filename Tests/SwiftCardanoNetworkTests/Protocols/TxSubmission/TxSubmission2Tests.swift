import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = TxSubmission2Codec()

private func roundTrip(_ msg: TxSubmission2Message) throws -> TxSubmission2Message {
    let buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(buf)
}

private func makeTxId(byte: UInt8 = 0xAB) -> TxId {
    Array(repeating: byte, count: 32)
}

private func makeTxBody(bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

// MARK: - TxSubmission2State

@Suite("TxSubmission2State") struct TxSubmission2StateTests {

    @Test func agencyRules() {
        #expect(TxSubmission2State.idle.agency             == .server)
        #expect(TxSubmission2State.txIdsBlocking.agency    == .client)
        #expect(TxSubmission2State.txIdsNonBlocking.agency == .client)
        #expect(TxSubmission2State.txs.agency              == .client)
        #expect(TxSubmission2State.done.agency             == .nobody)
    }

    // MARK: Receive transitions (server → client, from idle)

    @Test func idleBlockingRequestTxIdsToTxIdsBlocking() throws {
        let next = try TxSubmission2State.idle.afterReceive(
            .requestTxIds(blocking: true, ackCount: 0, reqCount: 10)
        )
        #expect(next == .txIdsBlocking)
    }

    @Test func idleNonBlockingRequestTxIdsToTxIdsNonBlocking() throws {
        let next = try TxSubmission2State.idle.afterReceive(
            .requestTxIds(blocking: false, ackCount: 2, reqCount: 5)
        )
        #expect(next == .txIdsNonBlocking)
    }

    @Test func idleRequestTxsToTxs() throws {
        let next = try TxSubmission2State.idle.afterReceive(.requestTxs([makeTxId()]))
        #expect(next == .txs)
    }

    @Test func idleRequestTxsEmptyToTxs() throws {
        let next = try TxSubmission2State.idle.afterReceive(.requestTxs([]))
        #expect(next == .txs)
    }

    @Test func idleDoneToDone() throws {
        let next = try TxSubmission2State.idle.afterReceive(.done)
        #expect(next == .done)
    }

    @Test func invalidReceiveFromTxIdsBlockingThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.txIdsBlocking.afterReceive(
                .requestTxIds(blocking: true, ackCount: 0, reqCount: 1)
            )
        }
    }

    @Test func invalidReceiveFromTxsThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.txs.afterReceive(.requestTxs([]))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.done.afterReceive(.done)
        }
    }

    // MARK: Send transitions (client → server)

    @Test func txIdsBlockingReplyTxIdsToIdle() throws {
        let next = try TxSubmission2State.txIdsBlocking.afterSend(.replyTxIds([]))
        #expect(next == .idle)
    }

    @Test func txIdsNonBlockingReplyTxIdsToIdle() throws {
        let entries = [TxIdWithSize(id: makeTxId(), size: 256)]
        let next = try TxSubmission2State.txIdsNonBlocking.afterSend(.replyTxIds(entries))
        #expect(next == .idle)
    }

    @Test func txsReplyTxsToIdle() throws {
        let next = try TxSubmission2State.txs.afterSend(.replyTxs([makeTxBody()]))
        #expect(next == .idle)
    }

    @Test func txsReplyTxsEmptyToIdle() throws {
        let next = try TxSubmission2State.txs.afterSend(.replyTxs([]))
        #expect(next == .idle)
    }

    @Test func invalidSendFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.idle.afterSend(.replyTxIds([]))
        }
    }

    @Test func invalidSendReplyTxsFromTxIdsBlockingThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.txIdsBlocking.afterSend(.replyTxs([]))
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try TxSubmission2State.done.afterSend(.replyTxIds([]))
        }
    }

    // MARK: Full exchange cycles

    @Test func fullTxIdsCycle() throws {
        var state: TxSubmission2State = .idle
        state = try state.afterReceive(.requestTxIds(blocking: true, ackCount: 0, reqCount: 5))
        #expect(state == .txIdsBlocking)
        state = try state.afterSend(.replyTxIds([TxIdWithSize(id: makeTxId(), size: 512)]))
        #expect(state == .idle)
    }

    @Test func fullTxBodyCycle() throws {
        var state: TxSubmission2State = .idle
        state = try state.afterReceive(.requestTxs([makeTxId()]))
        #expect(state == .txs)
        state = try state.afterSend(.replyTxs([makeTxBody()]))
        #expect(state == .idle)
    }

    @Test func multipleRoundsEndingInDone() throws {
        var state: TxSubmission2State = .idle
        // Round 1: IDs
        state = try state.afterReceive(.requestTxIds(blocking: false, ackCount: 0, reqCount: 3))
        state = try state.afterSend(.replyTxIds([]))
        #expect(state == .idle)
        // Round 2: bodies
        state = try state.afterReceive(.requestTxs([makeTxId()]))
        state = try state.afterSend(.replyTxs([makeTxBody()]))
        #expect(state == .idle)
        // Done
        state = try state.afterReceive(.done)
        #expect(state == .done)
    }
}

// MARK: - TxSubmission2Codec

@Suite("TxSubmission2Codec") struct TxSubmission2CodecTests {

    // MARK: Server messages

    @Test func requestTxIdsBlockingRoundTrip() throws {
        let decoded = try roundTrip(.requestTxIds(blocking: true, ackCount: 3, reqCount: 10))
        guard case .requestTxIds(let b, let ack, let req) = decoded else {
            Issue.record("Expected .requestTxIds"); return
        }
        #expect(b   == true)
        #expect(ack == 3)
        #expect(req == 10)
    }

    @Test func requestTxIdsNonBlockingRoundTrip() throws {
        let decoded = try roundTrip(.requestTxIds(blocking: false, ackCount: 0, reqCount: 5))
        guard case .requestTxIds(let b, let ack, let req) = decoded else {
            Issue.record("Expected .requestTxIds"); return
        }
        #expect(b   == false)
        #expect(ack == 0)
        #expect(req == 5)
    }

    @Test func requestTxIdsZeroCountsRoundTrip() throws {
        let decoded = try roundTrip(.requestTxIds(blocking: true, ackCount: 0, reqCount: 0))
        guard case .requestTxIds(let b, let ack, let req) = decoded else {
            Issue.record("Expected .requestTxIds"); return
        }
        #expect(b   == true)
        #expect(ack == 0)
        #expect(req == 0)
    }

    @Test func requestTxsRoundTrip() throws {
        let ids = [makeTxId(byte: 0x11), makeTxId(byte: 0x22)]
        let decoded = try roundTrip(.requestTxs(ids))
        guard case .requestTxs(let result) = decoded else {
            Issue.record("Expected .requestTxs"); return
        }
        #expect(result.count == 2)
        #expect(result[0] == makeTxId(byte: 0x11))
        #expect(result[1] == makeTxId(byte: 0x22))
    }

    @Test func requestTxsEmptyRoundTrip() throws {
        let decoded = try roundTrip(.requestTxs([]))
        guard case .requestTxs(let ids) = decoded else {
            Issue.record("Expected .requestTxs"); return
        }
        #expect(ids.isEmpty)
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done"); return
        }
    }

    // MARK: Client messages

    @Test func replyTxIdsEmptyRoundTrip() throws {
        let decoded = try roundTrip(.replyTxIds([]))
        guard case .replyTxIds(let entries) = decoded else {
            Issue.record("Expected .replyTxIds"); return
        }
        #expect(entries.isEmpty)
    }

    @Test func replyTxIdsWithEntriesRoundTrip() throws {
        let entries = [
            TxIdWithSize(id: makeTxId(byte: 0xAA), size: 256),
            TxIdWithSize(id: makeTxId(byte: 0xBB), size: 512),
        ]
        let decoded = try roundTrip(.replyTxIds(entries))
        guard case .replyTxIds(let result) = decoded else {
            Issue.record("Expected .replyTxIds"); return
        }
        #expect(result.count == 2)
        #expect(result[0].id == makeTxId(byte: 0xAA))
        #expect(result[0].size == 256)
        #expect(result[1].id == makeTxId(byte: 0xBB))
        #expect(result[1].size == 512)
    }

    @Test func replyTxIdsLargeSizeRoundTrip() throws {
        let entries = [TxIdWithSize(id: makeTxId(), size: UInt32.max)]
        let decoded = try roundTrip(.replyTxIds(entries))
        guard case .replyTxIds(let result) = decoded else {
            Issue.record("Expected .replyTxIds"); return
        }
        #expect(result[0].size == UInt32.max)
    }

    @Test func replyTxsEmptyRoundTrip() throws {
        let decoded = try roundTrip(.replyTxs([]))
        guard case .replyTxs(let txs) = decoded else {
            Issue.record("Expected .replyTxs"); return
        }
        #expect(txs.isEmpty)
    }

    @Test func replyTxsWithBodiesRoundTrip() throws {
        let bodies = [
            makeTxBody(bytes: [0xCA, 0xFE]),
            makeTxBody(bytes: [0xBA, 0xBE, 0xDE, 0xAD]),
        ]
        let decoded = try roundTrip(.replyTxs(bodies))
        guard case .replyTxs(let result) = decoded else {
            Issue.record("Expected .replyTxs"); return
        }
        #expect(result.count == 2)
        #expect(result[0].readableBytes == 2)
        #expect(result[1].readableBytes == 4)
        var copy0 = result[0]
        #expect(copy0.readBytes(length: 2) == [0xCA, 0xFE])
        var copy1 = result[1]
        #expect(copy1.readBytes(length: 4) == [0xBA, 0xBE, 0xDE, 0xAD])
    }

    // MARK: Byte-level checks

    @Test func doneEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // CBOR [4] = 0x81 0x04
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x04])
    }

    @Test func requestTxIdsHasFourElementArray() throws {
        let buf = try codec.encode(
            .requestTxIds(blocking: true, ackCount: 0, reqCount: 1),
            allocator: alloc
        )
        var copy = buf
        let first = copy.readInteger(as: UInt8.self)
        // 0x84 = array(4)
        #expect(first == 0x84)
    }

    @Test func replyTxIdsHasTwoElementArray() throws {
        let buf = try codec.encode(.replyTxIds([]), allocator: alloc)
        var copy = buf
        let first = copy.readInteger(as: UInt8.self)
        // 0x82 = array(2)
        #expect(first == 0x82)
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x1E])  // [30]
        #expect(throws: (any Error).self) {
            _ = try codec.decode(buf)
        }
    }

    @Test func wrongArrayLengthForDoneThrows() {
        // [4, 0] — done expects array of 1
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x04, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(buf)
        }
    }

    @Test func wrongArrayLengthForRequestTxIdsThrows() {
        // [0, true, 0] — requestTxIds expects array of 4
        var buf = alloc.buffer(capacity: 4)
        buf.writeBytes([0x83, 0x00, 0xF5, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(buf)
        }
    }

    @Test func emptyBufferThrows() {
        let buf = alloc.buffer(capacity: 0)
        #expect(throws: (any Error).self) {
            _ = try codec.decode(buf)
        }
    }
}

// MARK: - TxSubmission2Error

@Suite("TxSubmission2Error") struct TxSubmission2ErrorTests {
    @Test func errorCases() {
        let errs: [TxSubmission2Error] = [
            .unknownMessageTag(99),
            .unexpectedArrayLength(3),
            .malformedTxIdEntry(arrayLength: 1),
        ]
        #expect(errs.count == 3)
    }
}

// MARK: - TxIdWithSize

@Suite("TxIdWithSize") struct TxIdWithSizeTests {
    @Test func storesIdAndSize() {
        let entry = TxIdWithSize(id: makeTxId(byte: 0xFF), size: 1024)
        #expect(entry.id == makeTxId(byte: 0xFF))
        #expect(entry.size == 1024)
    }

    @Test func zeroSizeIsValid() {
        let entry = TxIdWithSize(id: [], size: 0)
        #expect(entry.id.isEmpty)
        #expect(entry.size == 0)
    }
}
