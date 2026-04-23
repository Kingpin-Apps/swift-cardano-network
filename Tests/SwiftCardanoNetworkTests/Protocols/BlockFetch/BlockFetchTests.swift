import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = BlockFetchCodec()

private func roundTrip(_ msg: BlockFetchMessage) throws -> BlockFetchMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

private func makePoint(slot: UInt64 = 100_000) -> Point {
    .blockPoint(slot: slot, hash: Array(repeating: 0xAB, count: 32))
}

private func makeBody(bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

// MARK: - BlockFetchState

@Suite("BlockFetchState") struct BlockFetchStateTests {

    @Test func agencyRules() {
        #expect(BlockFetchState.idle.agency      == .client)
        #expect(BlockFetchState.busy.agency      == .server)
        #expect(BlockFetchState.streaming.agency == .server)
        #expect(BlockFetchState.done.agency      == .nobody)
    }

    // MARK: Send transitions

    @Test func idleRequestRangeToBusy() throws {
        let next = try BlockFetchState.idle.afterSend(.requestRange(from: .origin, to: .origin))
        #expect(next == .busy)
    }

    @Test func idleClientDoneToDone() throws {
        let next = try BlockFetchState.idle.afterSend(.clientDone)
        #expect(next == .done)
    }

    @Test func invalidSendFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.busy.afterSend(.clientDone)
        }
    }

    @Test func invalidSendFromStreamingThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.streaming.afterSend(.requestRange(from: .origin, to: .origin))
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.done.afterSend(.clientDone)
        }
    }

    // MARK: Receive transitions

    @Test func busyStartBatchToStreaming() throws {
        let next = try BlockFetchState.busy.afterReceive(.startBatch)
        #expect(next == .streaming)
    }

    @Test func busyNoBlocksToIdle() throws {
        let next = try BlockFetchState.busy.afterReceive(.noBlocks)
        #expect(next == .idle)
    }

    @Test func streamingBlockStaysStreaming() throws {
        let next = try BlockFetchState.streaming.afterReceive(.block(makeBody()))
        #expect(next == .streaming)
    }

    @Test func streamingBatchDoneToIdle() throws {
        let next = try BlockFetchState.streaming.afterReceive(.batchDone)
        #expect(next == .idle)
    }

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.idle.afterReceive(.startBatch)
        }
    }

    @Test func invalidReceiveFromBusyBlockThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.busy.afterReceive(.block(makeBody()))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try BlockFetchState.done.afterReceive(.batchDone)
        }
    }

    @Test func fullFetchCycle() throws {
        var state: BlockFetchState = .idle
        state = try state.afterSend(.requestRange(from: makePoint(), to: makePoint(slot: 200_000)))
        #expect(state == .busy)
        state = try state.afterReceive(.startBatch)
        #expect(state == .streaming)
        state = try state.afterReceive(.block(makeBody()))
        #expect(state == .streaming)
        state = try state.afterReceive(.block(makeBody()))
        #expect(state == .streaming)
        state = try state.afterReceive(.batchDone)
        #expect(state == .idle)
    }

    @Test func emptyBatchCycle() throws {
        var state: BlockFetchState = .idle
        state = try state.afterSend(.requestRange(from: .origin, to: makePoint()))
        #expect(state == .busy)
        state = try state.afterReceive(.noBlocks)
        #expect(state == .idle)
    }
}

// MARK: - BlockFetchCodec

@Suite("BlockFetchCodec") struct BlockFetchCodecTests {

    // MARK: Client messages

    @Test func requestRangeOriginToOriginRoundTrip() throws {
        let decoded = try roundTrip(.requestRange(from: .origin, to: .origin))
        guard case .requestRange(let f, let t) = decoded else {
            Issue.record("Expected .requestRange"); return
        }
        #expect(f == .origin)
        #expect(t == .origin)
    }

    @Test func requestRangeBlockPointsRoundTrip() throws {
        let from = Point.blockPoint(slot: 1_000_000, hash: Array(repeating: 0x11, count: 32))
        let to   = Point.blockPoint(slot: 2_000_000, hash: Array(repeating: 0x22, count: 32))
        let decoded = try roundTrip(.requestRange(from: from, to: to))
        guard case .requestRange(let f, let t) = decoded else {
            Issue.record("Expected .requestRange"); return
        }
        guard case .blockPoint(let fSlot, let fHash) = f,
              case .blockPoint(let tSlot, let tHash) = t else {
            Issue.record("Expected blockPoint pairs"); return
        }
        #expect(fSlot == 1_000_000)
        #expect(fHash == Array(repeating: 0x11, count: 32))
        #expect(tSlot == 2_000_000)
        #expect(tHash == Array(repeating: 0x22, count: 32))
    }

    @Test func clientDoneRoundTrip() throws {
        let decoded = try roundTrip(.clientDone)
        guard case .clientDone = decoded else {
            Issue.record("Expected .clientDone"); return
        }
    }

    // MARK: Server messages

    @Test func startBatchRoundTrip() throws {
        let decoded = try roundTrip(.startBatch)
        guard case .startBatch = decoded else {
            Issue.record("Expected .startBatch"); return
        }
    }

    @Test func noBlocksRoundTrip() throws {
        let decoded = try roundTrip(.noBlocks)
        guard case .noBlocks = decoded else {
            Issue.record("Expected .noBlocks"); return
        }
    }

    @Test func batchDoneRoundTrip() throws {
        let decoded = try roundTrip(.batchDone)
        guard case .batchDone = decoded else {
            Issue.record("Expected .batchDone"); return
        }
    }

    @Test func blockRoundTrip() throws {
        let body    = makeBody(bytes: [0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD])
        let decoded = try roundTrip(.block(body))
        guard case .block(let buf) = decoded else {
            Issue.record("Expected .block"); return
        }
        #expect(buf.readableBytes == 6)
        var copy = buf
        #expect(copy.readBytes(length: 6) == [0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD])
    }

    @Test func blockEmptyBodyRoundTrip() throws {
        let body    = alloc.buffer(capacity: 0)
        let decoded = try roundTrip(.block(body))
        guard case .block(let buf) = decoded else {
            Issue.record("Expected .block"); return
        }
        #expect(buf.readableBytes == 0)
    }

    @Test func blockLargeBodyRoundTrip() throws {
        let bytes   = (0..<1024).map { UInt8($0 & 0xFF) }
        let decoded = try roundTrip(.block(makeBody(bytes: bytes)))
        guard case .block(let buf) = decoded else {
            Issue.record("Expected .block"); return
        }
        #expect(buf.readableBytes == 1024)
    }

    // MARK: Byte-level checks

    @Test func clientDoneEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.clientDone, allocator: alloc)
        // CBOR [1] = 0x81 0x01
        #expect(buf.readableBytes == 2)
    }

    @Test func startBatchEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.startBatch, allocator: alloc)
        // CBOR [2] = 0x81 0x02
        #expect(buf.readableBytes == 2)
    }

    @Test func noBlocksEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.noBlocks, allocator: alloc)
        // CBOR [3] = 0x81 0x03
        #expect(buf.readableBytes == 2)
    }

    @Test func batchDoneEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.batchDone, allocator: alloc)
        // CBOR [5] = 0x81 0x05
        #expect(buf.readableBytes == 2)
    }

    @Test func requestRangeOriginHasCorrectFirstByte() throws {
        let buf = try codec.encode(.requestRange(from: .origin, to: .origin), allocator: alloc)
        // Array(3) = 0x83
        var copy = buf
        let first = copy.readInteger(as: UInt8.self)
        #expect(first == 0x83)
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x1E])  // [30] — unknown tag
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForClientDoneThrows() {
        var buf = alloc.buffer(capacity: 3)
        // [1, 0] — array of 2 with tag 1 (clientDone expects array of 1)
        buf.writeBytes([0x82, 0x01, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }
}

// MARK: - BlockFetchError

@Suite("BlockFetchError") struct BlockFetchErrorTests {
    @Test func errorCases() {
        let errs: [BlockFetchError] = [
            .unknownMessageTag(99),
            .unexpectedArrayLength(4),
            .malformedPoint(arrayLength: 3),
            .emptyBatch,
        ]
        #expect(errs.count == 4)
    }
}
