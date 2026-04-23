import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = LocalStateQueryCodec()

private func roundTrip(_ msg: LocalStateQueryMessage) throws -> LocalStateQueryMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

private func makeRawQuery(era: UInt16 = 6, bytes: [UInt8] = [0xDE, 0xAD]) -> RawQuery {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawQuery(era: era, rawCBOR: buf)
}

private func makeRawResult(era: UInt16 = 6, bytes: [UInt8] = [0xCA, 0xFE]) -> RawResult {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawResult(era: era, rawCBOR: buf)
}

private let testHash: BlockHash = Array(repeating: 0xAB, count: 32)

// MARK: - RawQuery

@Suite("RawQuery") struct RawQueryTests {

    @Test func storesEraAndBytes() {
        let q = makeRawQuery(era: 5, bytes: [0x01, 0x02, 0x03])
        #expect(q.era == 5)
        #expect(q.rawCBOR.readableBytes == 3)
    }

    @Test func conwayEra() {
        let q = makeRawQuery(era: 6)
        #expect(q.era == 6)
    }
}

// MARK: - RawResult

@Suite("RawResult") struct RawResultTests {

    @Test func storesEraAndBytes() {
        let r = makeRawResult(era: 4, bytes: [0xFF, 0xFE])
        #expect(r.era == 4)
        #expect(r.rawCBOR.readableBytes == 2)
    }
}

// MARK: - LedgerQuery

@Suite("LedgerQuery") struct LedgerQueryTests {

    @Test func rawQueryAccessor() {
        let q = makeRawQuery(era: 6, bytes: [0x01])
        let lq = LedgerQuery.raw(q)
        #expect(lq.rawQuery.era == 6)
        #expect(lq.rawQuery.rawCBOR.readableBytes == 1)
    }
}

// MARK: - AcquirePoint

@Suite("AcquirePoint") struct AcquirePointTests {

    @Test func volatileTipDescription() {
        #expect(AcquirePoint.volatileTip.description == "volatileTip")
    }

    @Test func specificOriginDescription() {
        let ap = AcquirePoint.specific(.origin)
        #expect(ap.description == "specific(origin)")
    }

    @Test func specificBlockPointDescription() {
        let ap = AcquirePoint.specific(.blockPoint(slot: 100, hash: testHash))
        #expect(ap.description.hasPrefix("specific("))
    }
}

// MARK: - AcquireFailure

@Suite("AcquireFailure") struct AcquireFailureTests {

    @Test func rawValues() {
        #expect(AcquireFailure.pointTooOld.rawValue == 0)
        #expect(AcquireFailure.pointNotOnChain.rawValue == 1)
    }

    @Test func initFromRawValue() {
        #expect(AcquireFailure(rawValue: 0) == .pointTooOld)
        #expect(AcquireFailure(rawValue: 1) == .pointNotOnChain)
        #expect(AcquireFailure(rawValue: 99) == nil)
    }
}

// MARK: - LocalStateQueryState

@Suite("LocalStateQueryState") struct LocalStateQueryStateTests {

    // MARK: Agency

    @Test func agencyRules() {
        #expect(LocalStateQueryState.idle.agency      == .client)
        #expect(LocalStateQueryState.acquiring.agency == .server)
        #expect(LocalStateQueryState.acquired.agency  == .client)
        #expect(LocalStateQueryState.querying.agency  == .server)
        #expect(LocalStateQueryState.done.agency      == .nobody)
    }

    // MARK: Descriptions

    @Test func descriptions() {
        #expect(LocalStateQueryState.idle.description      == "idle")
        #expect(LocalStateQueryState.acquiring.description == "acquiring")
        #expect(LocalStateQueryState.acquired.description  == "acquired")
        #expect(LocalStateQueryState.querying.description  == "querying")
        #expect(LocalStateQueryState.done.description      == "done")
    }

    // MARK: Send transitions

    @Test func idleAcquireToAcquiring() throws {
        let next = try LocalStateQueryState.idle.afterSend(.acquire(.origin))
        #expect(next == .acquiring)
    }

    @Test func idleAcquireVolatileTipToAcquiring() throws {
        let next = try LocalStateQueryState.idle.afterSend(.acquireVolatileTip)
        #expect(next == .acquiring)
    }

    @Test func idleDoneToDone() throws {
        let next = try LocalStateQueryState.idle.afterSend(.done)
        #expect(next == .done)
    }

    @Test func acquiredQueryToQuerying() throws {
        let next = try LocalStateQueryState.acquired.afterSend(.query(makeRawQuery()))
        #expect(next == .querying)
    }

    @Test func acquiredReleaseToIdle() throws {
        let next = try LocalStateQueryState.acquired.afterSend(.release)
        #expect(next == .idle)
    }

    @Test func acquiredReAcquireToAcquiring() throws {
        let next = try LocalStateQueryState.acquired.afterSend(.reAcquire(.blockPoint(slot: 1, hash: testHash)))
        #expect(next == .acquiring)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendFromAcquiringThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.acquiring.afterSend(.done)
        }
    }

    @Test func invalidSendFromQueryingThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.querying.afterSend(.release)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.done.afterSend(.acquire(.origin))
        }
    }

    @Test func invalidSendQueryFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.idle.afterSend(.query(makeRawQuery()))
        }
    }

    // MARK: Receive transitions

    @Test func acquiringAcquiredToAcquired() throws {
        let next = try LocalStateQueryState.acquiring.afterReceive(.acquired)
        #expect(next == .acquired)
    }

    @Test func acquiringFailureToIdle() throws {
        let next = try LocalStateQueryState.acquiring.afterReceive(.failure(.pointTooOld))
        #expect(next == .idle)
    }

    @Test func acquiringFailurePointNotOnChainToIdle() throws {
        let next = try LocalStateQueryState.acquiring.afterReceive(.failure(.pointNotOnChain))
        #expect(next == .idle)
    }

    @Test func queryingResultToAcquired() throws {
        let next = try LocalStateQueryState.querying.afterReceive(.result(makeRawResult()))
        #expect(next == .acquired)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.idle.afterReceive(.acquired)
        }
    }

    @Test func invalidReceiveFromAcquiredThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.acquired.afterReceive(.result(makeRawResult()))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.done.afterReceive(.acquired)
        }
    }

    @Test func invalidReceiveResultFromAcquiringThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalStateQueryState.acquiring.afterReceive(.result(makeRawResult()))
        }
    }
}

// MARK: - LocalStateQueryCodec

@Suite("LocalStateQueryCodec") struct LocalStateQueryCodecTests {

    // MARK: Round-trips

    @Test func acquireOriginRoundTrip() throws {
        let decoded = try roundTrip(.acquire(.origin))
        guard case .acquire(let p) = decoded else {
            Issue.record("Expected .acquire, got \(decoded)"); return
        }
        #expect(p == .origin)
    }

    @Test func acquireBlockPointRoundTrip() throws {
        let decoded = try roundTrip(.acquire(.blockPoint(slot: 123_456, hash: testHash)))
        guard case .acquire(let p) = decoded else {
            Issue.record("Expected .acquire, got \(decoded)"); return
        }
        guard case .blockPoint(let slot, let hash) = p else {
            Issue.record("Expected .blockPoint, got \(p)"); return
        }
        #expect(slot == 123_456)
        #expect(hash == testHash)
    }

    @Test func acquiredRoundTrip() throws {
        let decoded = try roundTrip(.acquired)
        guard case .acquired = decoded else {
            Issue.record("Expected .acquired, got \(decoded)"); return
        }
    }

    @Test func failurePointTooOldRoundTrip() throws {
        let decoded = try roundTrip(.failure(.pointTooOld))
        guard case .failure(let f) = decoded else {
            Issue.record("Expected .failure, got \(decoded)"); return
        }
        #expect(f == .pointTooOld)
    }

    @Test func failurePointNotOnChainRoundTrip() throws {
        let decoded = try roundTrip(.failure(.pointNotOnChain))
        guard case .failure(let f) = decoded else {
            Issue.record("Expected .failure, got \(decoded)"); return
        }
        #expect(f == .pointNotOnChain)
    }

    @Test func queryRoundTrip() throws {
        let q       = makeRawQuery(era: 6, bytes: [0xCA, 0xFE, 0xBA, 0xBE])
        let decoded = try roundTrip(.query(q))
        guard case .query(let r) = decoded else {
            Issue.record("Expected .query, got \(decoded)"); return
        }
        #expect(r.era == 6)
        #expect(r.rawCBOR.readableBytes == 4)
        #expect(r.rawCBOR.getBytes(at: r.rawCBOR.readerIndex, length: 4) == [0xCA, 0xFE, 0xBA, 0xBE])
    }

    @Test func resultRoundTrip() throws {
        let res     = makeRawResult(era: 5, bytes: [0x01, 0x02, 0x03])
        let decoded = try roundTrip(.result(res))
        guard case .result(let r) = decoded else {
            Issue.record("Expected .result, got \(decoded)"); return
        }
        #expect(r.era == 5)
        #expect(r.rawCBOR.readableBytes == 3)
        #expect(r.rawCBOR.getBytes(at: r.rawCBOR.readerIndex, length: 3) == [0x01, 0x02, 0x03])
    }

    @Test func releaseRoundTrip() throws {
        let decoded = try roundTrip(.release)
        guard case .release = decoded else {
            Issue.record("Expected .release, got \(decoded)"); return
        }
    }

    @Test func reAcquireRoundTrip() throws {
        let decoded = try roundTrip(.reAcquire(.blockPoint(slot: 999, hash: testHash)))
        guard case .reAcquire(let p) = decoded else {
            Issue.record("Expected .reAcquire, got \(decoded)"); return
        }
        guard case .blockPoint(let slot, _) = p else {
            Issue.record("Expected .blockPoint, got \(p)"); return
        }
        #expect(slot == 999)
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    @Test func acquireVolatileTipRoundTrip() throws {
        let decoded = try roundTrip(.acquireVolatileTip)
        guard case .acquireVolatileTip = decoded else {
            Issue.record("Expected .acquireVolatileTip, got \(decoded)"); return
        }
    }

    // MARK: Byte-level encoding checks

    @Test func acquiredEncodesTwoBytes() throws {
        let buf = try codec.encode(.acquired, allocator: alloc)
        // CBOR [1] = 0x81 (array len 1) 0x01 (uint 1)
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x01])
    }

    @Test func releaseEncodesTwoBytes() throws {
        let buf = try codec.encode(.release, allocator: alloc)
        // CBOR [5] = 0x81 0x05
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x05])
    }

    @Test func doneEncodesTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // CBOR [7] = 0x81 0x07
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x07])
    }

    @Test func acquireVolatileTipEncodesTwoBytes() throws {
        let buf = try codec.encode(.acquireVolatileTip, allocator: alloc)
        // CBOR [8] = 0x81 0x08
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x08])
    }

    @Test func acquireOriginEncodesCorrectly() throws {
        let buf   = try codec.encode(.acquire(.origin), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [0, []] = 0x82 (array 2), 0x00 (uint 0), 0x80 (array 0)
        #expect(bytes[0] == 0x82)  // array(2)
        #expect(bytes[1] == 0x00)  // uint(0) = msgAcquire
        #expect(bytes[2] == 0x80)  // array(0) = origin
    }

    @Test func failurePointTooOldEncodesCorrectly() throws {
        let buf   = try codec.encode(.failure(.pointTooOld), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [2, 0] = 0x82 (array 2), 0x02 (uint 2), 0x00 (uint 0)
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x02)  // uint(2) = msgFailure
        #expect(bytes[2] == 0x00)  // uint(0) = PointTooOld
    }

    @Test func queryEncodesEraAndPayload() throws {
        let q     = makeRawQuery(era: 6, bytes: [0xAB, 0xCD])
        let buf   = try codec.encode(.query(q), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [3, [6, bstr(2)]]
        // 0x82  array(2)
        // 0x03  uint(3) = msgQuery
        // 0x82  array(2) era-tagged
        // 0x06  uint(6) = Conway
        // 0x42 0xAB 0xCD  bstr(2)
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x03)  // msgQuery
        #expect(bytes[2] == 0x82)  // era-tagged array
        #expect(bytes[3] == 0x06)  // Conway era
        #expect(bytes[4] == 0x42)  // bstr(2)
        #expect(bytes[5] == 0xAB)
        #expect(bytes[6] == 0xCD)
    }

    @Test func resultEncodesEraAndPayload() throws {
        let r     = makeRawResult(era: 4, bytes: [0xFF])
        let buf   = try codec.encode(.result(r), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [4, [4, bstr(1)]]
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x04)  // msgResult
        #expect(bytes[2] == 0x82)  // era-tagged array
        #expect(bytes[3] == 0x04)  // Alonzo era
        #expect(bytes[4] == 0x41)  // bstr(1)
        #expect(bytes[5] == 0xFF)
    }

    // MARK: Era round-trips

    @Test func byronEraQueryRoundTrip() throws {
        let q       = makeRawQuery(era: 0, bytes: [0x01])
        let decoded = try roundTrip(.query(q))
        guard case .query(let r) = decoded else {
            Issue.record("Expected .query"); return
        }
        #expect(r.era == 0)
    }

    @Test func shelleyEraResultRoundTrip() throws {
        let r       = makeRawResult(era: 1, bytes: [0x01])
        let decoded = try roundTrip(.result(r))
        guard case .result(let res) = decoded else {
            Issue.record("Expected .result"); return
        }
        #expect(res.era == 1)
    }

    // MARK: Block point hash preservation

    @Test func blockPointHashRoundTrip() throws {
        let hash: BlockHash = Array(0..<32)
        let decoded = try roundTrip(.acquire(.blockPoint(slot: 42, hash: hash)))
        guard case .acquire(let p) = decoded,
              case .blockPoint(let slot, let h) = p else {
            Issue.record("Unexpected shape"); return
        }
        #expect(slot == 42)
        #expect(h == hash)
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        // [99] in CBOR
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x81, 0x18, 0x63])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForAcquiredThrows() {
        // [1, 0] — acquired should be [1], not [1, 0]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x01, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForReleaseThrows() {
        // [5, 0] — release should be [5]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x05, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func unknownAcquireFailureCodeThrows() {
        // [2, 99]
        var buf = alloc.buffer(capacity: 4)
        buf.writeBytes([0x82, 0x02, 0x18, 0x63])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func malformedPointThrows() {
        // acquire with a 3-element point array: [0, [a, b, c]]
        var buf = alloc.buffer(capacity: 8)
        // 0x82=array(2), 0x00=uint(0), 0x83=array(3), 0x01, 0x02, 0x03
        buf.writeBytes([0x82, 0x00, 0x83, 0x01, 0x02, 0x03])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func emptyBufferThrows() {
        var buf = alloc.buffer(capacity: 0)
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }
}

// MARK: - LocalStateQueryError

@Suite("LocalStateQueryError") struct LocalStateQueryErrorTests {

    @Test func errorCases() {
        let errs: [LocalStateQueryError] = [
            .acquireFailed(.pointTooOld),
            .acquireFailed(.pointNotOnChain),
            .unknownMessageTag(99),
            .unexpectedArrayLength(3),
            .unknownAcquireFailure(42),
            .malformedPoint(arrayLength: 3),
        ]
        #expect(errs.count == 6)
    }
}
