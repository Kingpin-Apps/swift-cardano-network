import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = ChainSyncCodec()

private func roundTrip(_ msg: ChainSyncMessage) throws -> ChainSyncMessage {
    let buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(buf)
}

private func makeTip(slot: UInt64 = 0, blockNo: UInt64 = 0) -> Tip {
    Tip(point: slot == 0 ? .origin : .blockPoint(slot: slot, hash: Array(repeating: 0xFF, count: 32)),
        blockNo: blockNo)
}

// MARK: - Point

@Suite("Point") struct PointTests {
    @Test func originEquality() {
        #expect(Point.origin == Point.origin)
    }

    @Test func blockPointEquality() {
        let a = Point.blockPoint(slot: 100, hash: [0x01, 0x02])
        let b = Point.blockPoint(slot: 100, hash: [0x01, 0x02])
        let c = Point.blockPoint(slot: 200, hash: [0x01, 0x02])
        #expect(a == b)
        #expect(a != c)
    }

    @Test func originNotEqualToBlockPoint() {
        #expect(Point.origin != Point.blockPoint(slot: 0, hash: []))
    }

    @Test func originDescription() {
        #expect(Point.origin.description == "origin")
    }

    @Test func blockPointDescriptionContainsSlot() {
        let p = Point.blockPoint(slot: 12_345, hash: Array(repeating: 0xAB, count: 32))
        #expect(p.description.contains("12345"))
    }
}

// MARK: - Tip

@Suite("Tip") struct TipTests {
    @Test func storesPointAndBlockNo() {
        let tip = Tip(point: .origin, blockNo: 99)
        guard case .origin = tip.point else {
            Issue.record("Expected .origin"); return
        }
        #expect(tip.blockNo == 99)
    }

    @Test func blockPointTip() {
        let point = Point.blockPoint(slot: 500_000, hash: Array(repeating: 0x42, count: 32))
        let tip   = Tip(point: point, blockNo: 1_000)
        guard case .blockPoint(let s, _) = tip.point else {
            Issue.record("Expected blockPoint"); return
        }
        #expect(s == 500_000)
        #expect(tip.blockNo == 1_000)
    }
}

// MARK: - ChainEvent

@Suite("ChainEvent") struct ChainEventTests {
    @Test func rollForwardDescription() {
        let buf = alloc.buffer(capacity: 0)
        let block = RawBlock(era: 6, rawCBOR: buf)
        let tip   = makeTip(slot: 100_000, blockNo: 500)
        let event = ChainEvent.rollForward(block: block, tip: tip)
        let desc  = event.description
        #expect(desc.contains("rollForward"))
        #expect(desc.contains("6"))    // era
        #expect(desc.contains("500"))  // blockNo
    }

    @Test func rollBackwardDescription() {
        let event = ChainEvent.rollBackward(to: .origin, tip: makeTip())
        let desc  = event.description
        #expect(desc.contains("rollBackward"))
        #expect(desc.contains("origin"))
    }
}

// MARK: - ChainSyncState (state machine)

@Suite("ChainSyncState") struct ChainSyncStateTests {
    @Test func agencyRules() {
        #expect(ChainSyncState.idle.agency      == .client)
        #expect(ChainSyncState.canAwait.agency  == .server)
        #expect(ChainSyncState.mustReply.agency == .server)
        #expect(ChainSyncState.intersect.agency == .server)
        #expect(ChainSyncState.done.agency      == .nobody)
    }

    // MARK: Send transitions

    @Test func idleRequestNextToCanAwait() throws {
        #expect(try ChainSyncState.idle.afterSend(.requestNext) == .canAwait)
    }

    @Test func idleFindIntersectToIntersect() throws {
        #expect(try ChainSyncState.idle.afterSend(.findIntersect([])) == .intersect)
    }

    @Test func idleDoneToDone() throws {
        #expect(try ChainSyncState.idle.afterSend(.done) == .done)
    }

    @Test func invalidSendFromCanAwaitThrows() {
        #expect(throws: (any Error).self) {
            _ = try ChainSyncState.canAwait.afterSend(.requestNext)
        }
    }

    // MARK: Receive transitions

    @Test func canAwaitAwaitReplyToMustReply() throws {
        #expect(try ChainSyncState.canAwait.afterReceive(.awaitReply) == .mustReply)
    }

    @Test func canAwaitRollForwardToIdle() throws {
        let msg = ChainSyncMessage.rollForward(RawBlock(era: 6, rawCBOR: alloc.buffer(capacity: 0)),
                                               makeTip())
        #expect(try ChainSyncState.canAwait.afterReceive(msg) == .idle)
    }

    @Test func canAwaitRollBackwardToIdle() throws {
        let msg = ChainSyncMessage.rollBackward(.origin, makeTip())
        #expect(try ChainSyncState.canAwait.afterReceive(msg) == .idle)
    }

    @Test func mustReplyRollForwardToIdle() throws {
        let msg = ChainSyncMessage.rollForward(RawBlock(era: 5, rawCBOR: alloc.buffer(capacity: 0)),
                                               makeTip())
        #expect(try ChainSyncState.mustReply.afterReceive(msg) == .idle)
    }

    @Test func mustReplyRollBackwardToIdle() throws {
        let msg = ChainSyncMessage.rollBackward(.blockPoint(slot: 100, hash: []), makeTip())
        #expect(try ChainSyncState.mustReply.afterReceive(msg) == .idle)
    }

    @Test func intersectFoundToIdle() throws {
        let msg = ChainSyncMessage.intersectFound(.origin, makeTip())
        #expect(try ChainSyncState.intersect.afterReceive(msg) == .idle)
    }

    @Test func intersectNotFoundToIdle() throws {
        let msg = ChainSyncMessage.intersectNotFound(makeTip())
        #expect(try ChainSyncState.intersect.afterReceive(msg) == .idle)
    }

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try ChainSyncState.idle.afterReceive(.awaitReply)
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try ChainSyncState.done.afterReceive(.awaitReply)
        }
    }
}

// MARK: - ChainSyncCodec

@Suite("ChainSyncCodec") struct ChainSyncCodecTests {
    // MARK: Simple messages

    @Test func requestNextRoundTrip() throws {
        let decoded = try roundTrip(.requestNext)
        guard case .requestNext = decoded else {
            Issue.record("Expected .requestNext, got \(decoded)"); return
        }
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    @Test func awaitReplyRoundTrip() throws {
        let decoded = try roundTrip(.awaitReply)
        guard case .awaitReply = decoded else {
            Issue.record("Expected .awaitReply, got \(decoded)"); return
        }
    }

    // MARK: FindIntersect

    @Test func findIntersectEmptyRoundTrip() throws {
        let decoded = try roundTrip(.findIntersect([]))
        guard case .findIntersect(let pts) = decoded else {
            Issue.record("Expected .findIntersect"); return
        }
        #expect(pts.isEmpty)
    }

    @Test func findIntersectWithPointsRoundTrip() throws {
        let points: [Point] = [
            .origin,
            .blockPoint(slot: 1_000_000, hash: Array(repeating: 0xAB, count: 32)),
        ]
        let decoded = try roundTrip(.findIntersect(points))
        guard case .findIntersect(let pts) = decoded else {
            Issue.record("Expected .findIntersect"); return
        }
        #expect(pts.count == 2)
        #expect(pts[0] == .origin)
        guard case .blockPoint(let slot, let hash) = pts[1] else {
            Issue.record("Expected .blockPoint"); return
        }
        #expect(slot == 1_000_000)
        #expect(hash == Array(repeating: 0xAB, count: 32))
    }

    // MARK: RollForward — Shelley+ (tag 24 wrapped)

    @Test func rollForwardShelleyRoundTrip() throws {
        var rawBuf = alloc.buffer(capacity: 4)
        rawBuf.writeBytes([0xCA, 0xFE, 0xBA, 0xBE])
        let block   = RawBlock(era: 6, rawCBOR: rawBuf)
        let tip     = Tip(point: .blockPoint(slot: 99_000, hash: Array(repeating: 0x42, count: 32)),
                          blockNo: 12_345)
        let decoded = try roundTrip(.rollForward(block, tip))

        guard case .rollForward(let b, let t) = decoded else {
            Issue.record("Expected .rollForward"); return
        }
        #expect(b.era == 6)
        #expect(b.rawCBOR.readableBytes == 4)
        #expect(t.blockNo == 12_345)
        guard case .blockPoint(let slot, _) = t.point else {
            Issue.record("Expected .blockPoint tip"); return
        }
        #expect(slot == 99_000)
    }

    @Test func rollForwardByronRoundTrip() throws {
        var rawBuf = alloc.buffer(capacity: 6)
        rawBuf.writeBytes([0x82, 0x00, 0x01, 0x02, 0x03, 0x04])
        let block   = RawBlock(era: 0, rawCBOR: rawBuf)  // Byron
        let tip     = Tip(point: .origin, blockNo: 0)
        let decoded = try roundTrip(.rollForward(block, tip))

        guard case .rollForward(let b, _) = decoded else {
            Issue.record("Expected .rollForward"); return
        }
        #expect(b.era == 0)
        #expect(b.rawCBOR.readableBytes == 6)
    }

    // MARK: RollBackward

    @Test func rollBackwardOriginRoundTrip() throws {
        let decoded = try roundTrip(.rollBackward(.origin, makeTip()))
        guard case .rollBackward(let p, _) = decoded else {
            Issue.record("Expected .rollBackward"); return
        }
        #expect(p == .origin)
    }

    @Test func rollBackwardBlockPointRoundTrip() throws {
        let point   = Point.blockPoint(slot: 500_000, hash: Array(repeating: 0x11, count: 32))
        let decoded = try roundTrip(.rollBackward(point, makeTip(slot: 600_000, blockNo: 9_999)))
        guard case .rollBackward(let p, let t) = decoded else {
            Issue.record("Expected .rollBackward"); return
        }
        guard case .blockPoint(let slot, _) = p else {
            Issue.record("Expected .blockPoint"); return
        }
        #expect(slot == 500_000)
        #expect(t.blockNo == 9_999)
    }

    // MARK: IntersectFound / IntersectNotFound

    @Test func intersectFoundRoundTrip() throws {
        let point   = Point.blockPoint(slot: 200_000, hash: Array(repeating: 0xCC, count: 32))
        let decoded = try roundTrip(.intersectFound(point, makeTip(slot: 300_000, blockNo: 4_000)))
        guard case .intersectFound(let p, let t) = decoded else {
            Issue.record("Expected .intersectFound"); return
        }
        guard case .blockPoint(let slot, _) = p else {
            Issue.record("Expected .blockPoint"); return
        }
        #expect(slot == 200_000)
        #expect(t.blockNo == 4_000)
    }

    @Test func intersectNotFoundRoundTrip() throws {
        let decoded = try roundTrip(.intersectNotFound(makeTip(slot: 0, blockNo: 0)))
        guard case .intersectNotFound(let t) = decoded else {
            Issue.record("Expected .intersectNotFound"); return
        }
        guard case .origin = t.point else {
            Issue.record("Expected .origin tip"); return
        }
    }

    // MARK: Payload byte-level check for requestNext

    @Test func requestNextEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.requestNext, allocator: alloc)
        // CBOR [0] = 0x81 (array len 1) 0x00 (uint 0)
        #expect(buf.readableBytes == 2)
    }

    @Test func doneEncodesAsTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // CBOR [7] = 0x81 (array len 1) 0x07 (uint 7)
        #expect(buf.readableBytes == 2)
    }
}

// MARK: - ChainSyncError

@Suite("ChainSyncError") struct ChainSyncErrorTests {
    @Test func errorCases() {
        let errs: [ChainSyncError] = [
            .unknownMessageTag(99),
            .unexpectedArrayLength(4),
            .malformedPoint(arrayLength: 3),
            .malformedTip(arrayLength: 1),
            .malformedBlock(arrayLength: 0),
            .intersectionNotFound(Tip(point: .origin, blockNo: 0)),
        ]
        #expect(errs.count == 6)
    }
}
