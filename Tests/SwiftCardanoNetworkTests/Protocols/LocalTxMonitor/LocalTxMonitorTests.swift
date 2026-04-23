import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = LocalTxMonitorCodec()

private func roundTrip(_ msg: LocalTxMonitorMessage) throws -> LocalTxMonitorMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

private func makeTx(bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]) -> MempoolTx {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return MempoolTx(rawCBOR: buf)
}

private let sampleTxId: TxId = Array(repeating: 0xAB, count: 32)

// MARK: - MempoolTx

@Suite("MempoolTx") struct MempoolTxTests {

    @Test func storesRawCBOR() {
        let tx = makeTx(bytes: [0x01, 0x02, 0x03])
        #expect(tx.rawCBOR.readableBytes == 3)
    }

    @Test func emptyTx() {
        let tx = makeTx(bytes: [])
        #expect(tx.rawCBOR.readableBytes == 0)
    }
}

// MARK: - MempoolCapacity

@Suite("MempoolCapacity") struct MempoolCapacityTests {

    @Test func storesFields() {
        let cap = MempoolCapacity(capacityInBytes: 1024, sizeInBytes: 256, numberOfTxs: 4)
        #expect(cap.capacityInBytes == 1024)
        #expect(cap.sizeInBytes == 256)
        #expect(cap.numberOfTxs == 4)
    }

    @Test func equatableIdentical() {
        let a = MempoolCapacity(capacityInBytes: 500, sizeInBytes: 100, numberOfTxs: 2)
        let b = MempoolCapacity(capacityInBytes: 500, sizeInBytes: 100, numberOfTxs: 2)
        #expect(a == b)
    }

    @Test func equatableDifferent() {
        let a = MempoolCapacity(capacityInBytes: 500, sizeInBytes: 100, numberOfTxs: 2)
        let b = MempoolCapacity(capacityInBytes: 500, sizeInBytes: 101, numberOfTxs: 2)
        #expect(a != b)
    }

    @Test func zeroCapacity() {
        let cap = MempoolCapacity(capacityInBytes: 0, sizeInBytes: 0, numberOfTxs: 0)
        #expect(cap.capacityInBytes == 0)
        #expect(cap.numberOfTxs == 0)
    }

    @Test func largeValues() {
        let cap = MempoolCapacity(
            capacityInBytes: UInt64.max,
            sizeInBytes: UInt64.max - 1,
            numberOfTxs: 999_999
        )
        #expect(cap.capacityInBytes == UInt64.max)
        #expect(cap.numberOfTxs == 999_999)
    }
}

// MARK: - LocalTxMonitorState

@Suite("LocalTxMonitorState") struct LocalTxMonitorStateTests {

    // MARK: Agency

    @Test func agencyRules() {
        #expect(LocalTxMonitorState.idle.agency      == .client)
        #expect(LocalTxMonitorState.acquiring.agency == .server)
        #expect(LocalTxMonitorState.acquired.agency  == .client)
        #expect(LocalTxMonitorState.busy.agency      == .server)
        #expect(LocalTxMonitorState.done.agency      == .nobody)
    }

    // MARK: Descriptions

    @Test func descriptions() {
        #expect(LocalTxMonitorState.idle.description      == "idle")
        #expect(LocalTxMonitorState.acquiring.description == "acquiring")
        #expect(LocalTxMonitorState.acquired.description  == "acquired")
        #expect(LocalTxMonitorState.busy.description      == "busy")
        #expect(LocalTxMonitorState.done.description      == "done")
    }

    // MARK: Send transitions

    @Test func idleAcquireToAcquiring() throws {
        let next = try LocalTxMonitorState.idle.afterSend(.acquire)
        #expect(next == .acquiring)
    }

    @Test func idleDoneToDone() throws {
        let next = try LocalTxMonitorState.idle.afterSend(.done)
        #expect(next == .done)
    }

    @Test func acquiredNextTxToBusy() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.nextTx)
        #expect(next == .busy)
    }

    @Test func acquiredHasTxToBusy() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.hasTx(sampleTxId))
        #expect(next == .busy)
    }

    @Test func acquiredGetSizesToBusy() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.getSizes)
        #expect(next == .busy)
    }

    @Test func acquiredGetMeasuresToBusy() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.getMeasures)
        #expect(next == .busy)
    }

    @Test func acquiredAwaitAcquireToAcquiring() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.awaitAcquire)
        #expect(next == .acquiring)
    }

    @Test func acquiredReleaseToIdle() throws {
        let next = try LocalTxMonitorState.acquired.afterSend(.release)
        #expect(next == .idle)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendFromAcquiringThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.acquiring.afterSend(.acquire)
        }
    }

    @Test func invalidSendFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.busy.afterSend(.nextTx)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.done.afterSend(.acquire)
        }
    }

    @Test func invalidSendDoneFromAcquiredThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.acquired.afterSend(.done)
        }
    }

    @Test func invalidSendAcquireFromAcquiredThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.acquired.afterSend(.acquire)
        }
    }

    // MARK: Receive transitions

    @Test func acquiringAcquiredToAcquired() throws {
        let next = try LocalTxMonitorState.acquiring.afterReceive(.acquired(slotNo: 100))
        #expect(next == .acquired)
    }

    @Test func busyReplyNextTxToAcquired() throws {
        let next = try LocalTxMonitorState.busy.afterReceive(.replyNextTx(makeTx()))
        #expect(next == .acquired)
    }

    @Test func busyReplyNextTxNilToAcquired() throws {
        let next = try LocalTxMonitorState.busy.afterReceive(.replyNextTx(nil))
        #expect(next == .acquired)
    }

    @Test func busyReplyHasTxToAcquired() throws {
        let next = try LocalTxMonitorState.busy.afterReceive(.replyHasTx(true))
        #expect(next == .acquired)
    }

    @Test func busyReplyGetSizesToAcquired() throws {
        let cap = MempoolCapacity(capacityInBytes: 1024, sizeInBytes: 0, numberOfTxs: 0)
        let next = try LocalTxMonitorState.busy.afterReceive(.replyGetSizes(cap))
        #expect(next == .acquired)
    }

    @Test func busyReplyGetMeasuresToAcquired() throws {
        let next = try LocalTxMonitorState.busy.afterReceive(.replyGetMeasures(totalTxs: 3, measures: []))
        #expect(next == .acquired)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.idle.afterReceive(.acquired(slotNo: 0))
        }
    }

    @Test func invalidReceiveFromAcquiredThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.acquired.afterReceive(.replyNextTx(nil))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.done.afterReceive(.acquired(slotNo: 0))
        }
    }

    @Test func invalidReceiveAcquiredFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxMonitorState.busy.afterReceive(.acquired(slotNo: 0))
        }
    }
}

// MARK: - LocalTxMonitorCodec

@Suite("LocalTxMonitorCodec") struct LocalTxMonitorCodecTests {

    // MARK: Round-trips

    @Test func acquireRoundTrip() throws {
        let decoded = try roundTrip(.acquire)
        guard case .acquire = decoded else {
            Issue.record("Expected .acquire, got \(decoded)"); return
        }
    }

    @Test func awaitAcquireRoundTrip() throws {
        // awaitAcquire encodes as [1] (same as acquire); decode returns .acquire
        var buf = try codec.encode(.awaitAcquire, allocator: alloc)
        let decoded = try codec.decode(&buf)
        guard case .acquire = decoded else {
            Issue.record("Expected .acquire (awaitAcquire wire encoding), got \(decoded)"); return
        }
    }

    @Test func acquiredRoundTrip() throws {
        let decoded = try roundTrip(.acquired(slotNo: 987_654))
        guard case .acquired(let slot) = decoded else {
            Issue.record("Expected .acquired, got \(decoded)"); return
        }
        #expect(slot == 987_654)
    }

    @Test func acquiredSlotZeroRoundTrip() throws {
        let decoded = try roundTrip(.acquired(slotNo: 0))
        guard case .acquired(let slot) = decoded else {
            Issue.record("Expected .acquired, got \(decoded)"); return
        }
        #expect(slot == 0)
    }

    @Test func releaseRoundTrip() throws {
        let decoded = try roundTrip(.release)
        guard case .release = decoded else {
            Issue.record("Expected .release, got \(decoded)"); return
        }
    }

    @Test func nextTxRoundTrip() throws {
        let decoded = try roundTrip(.nextTx)
        guard case .nextTx = decoded else {
            Issue.record("Expected .nextTx, got \(decoded)"); return
        }
    }

    @Test func replyNextTxWithTxRoundTrip() throws {
        let tx = makeTx(bytes: [0xCA, 0xFE, 0xBA, 0xBE])
        let decoded = try roundTrip(.replyNextTx(tx))
        guard case .replyNextTx(let result) = decoded else {
            Issue.record("Expected .replyNextTx, got \(decoded)"); return
        }
        guard let result else {
            Issue.record("Expected non-nil tx"); return
        }
        #expect(result.rawCBOR.readableBytes == 4)
        #expect(result.rawCBOR.getBytes(at: result.rawCBOR.readerIndex, length: 4)
                == [0xCA, 0xFE, 0xBA, 0xBE])
    }

    @Test func replyNextTxNilRoundTrip() throws {
        let decoded = try roundTrip(.replyNextTx(nil))
        guard case .replyNextTx(let result) = decoded else {
            Issue.record("Expected .replyNextTx, got \(decoded)"); return
        }
        #expect(result == nil)
    }

    @Test func hasTxRoundTrip() throws {
        let decoded = try roundTrip(.hasTx(sampleTxId))
        guard case .hasTx(let id) = decoded else {
            Issue.record("Expected .hasTx, got \(decoded)"); return
        }
        #expect(id == sampleTxId)
    }

    @Test func replyHasTxTrueRoundTrip() throws {
        let decoded = try roundTrip(.replyHasTx(true))
        guard case .replyHasTx(let present) = decoded else {
            Issue.record("Expected .replyHasTx, got \(decoded)"); return
        }
        #expect(present == true)
    }

    @Test func replyHasTxFalseRoundTrip() throws {
        let decoded = try roundTrip(.replyHasTx(false))
        guard case .replyHasTx(let present) = decoded else {
            Issue.record("Expected .replyHasTx, got \(decoded)"); return
        }
        #expect(present == false)
    }

    @Test func getSizesRoundTrip() throws {
        let decoded = try roundTrip(.getSizes)
        guard case .getSizes = decoded else {
            Issue.record("Expected .getSizes, got \(decoded)"); return
        }
    }

    @Test func replyGetSizesRoundTrip() throws {
        let cap = MempoolCapacity(capacityInBytes: 65_536, sizeInBytes: 1_024, numberOfTxs: 5)
        let decoded = try roundTrip(.replyGetSizes(cap))
        guard case .replyGetSizes(let result) = decoded else {
            Issue.record("Expected .replyGetSizes, got \(decoded)"); return
        }
        #expect(result.capacityInBytes == 65_536)
        #expect(result.sizeInBytes == 1_024)
        #expect(result.numberOfTxs == 5)
    }

    @Test func replyGetSizesZerosRoundTrip() throws {
        let cap = MempoolCapacity(capacityInBytes: 0, sizeInBytes: 0, numberOfTxs: 0)
        let decoded = try roundTrip(.replyGetSizes(cap))
        guard case .replyGetSizes(let result) = decoded else {
            Issue.record("Expected .replyGetSizes, got \(decoded)"); return
        }
        #expect(result == MempoolCapacity(capacityInBytes: 0, sizeInBytes: 0, numberOfTxs: 0))
    }

    @Test func getMeasuresRoundTrip() throws {
        let decoded = try roundTrip(.getMeasures)
        guard case .getMeasures = decoded else {
            Issue.record("Expected .getMeasures, got \(decoded)"); return
        }
    }

    @Test func replyGetMeasuresRoundTrip() throws {
        let decoded = try roundTrip(.replyGetMeasures(
            totalTxs: 7,
            measures: [
                (key: "bytes", current: 1024, capacity: 65536),
                (key: "count", current: 3, capacity: 100),
            ]
        ))
        guard case .replyGetMeasures(let total, let ms) = decoded else {
            Issue.record("Expected .replyGetMeasures, got \(decoded)"); return
        }
        #expect(total == 7)
        #expect(ms.count == 2)
        #expect(ms[0].key == "bytes")
        #expect(ms[0].current == 1024)
        #expect(ms[0].capacity == 65536)
        #expect(ms[1].key == "count")
        #expect(ms[1].current == 3)
    }

    @Test func replyGetMeasuresEmptyRoundTrip() throws {
        let decoded = try roundTrip(.replyGetMeasures(totalTxs: 0, measures: []))
        guard case .replyGetMeasures(let total, let ms) = decoded else {
            Issue.record("Expected .replyGetMeasures, got \(decoded)"); return
        }
        #expect(total == 0)
        #expect(ms.isEmpty)
    }

    @Test func replyGetMeasuresNegativeValuesRoundTrip() throws {
        let decoded = try roundTrip(.replyGetMeasures(
            totalTxs: 1,
            measures: [(key: "delta", current: -5, capacity: 100)]
        ))
        guard case .replyGetMeasures(_, let ms) = decoded else {
            Issue.record("Expected .replyGetMeasures, got \(decoded)"); return
        }
        #expect(ms[0].current == -5)
        #expect(ms[0].capacity == 100)
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    // MARK: Byte-level encoding checks (spec §3.14.5)

    @Test func acquireEncodesTwoBytes() throws {
        let buf = try codec.encode(.acquire, allocator: alloc)
        // [1] = 0x81 (array(1)), 0x01
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x01])
    }

    @Test func awaitAcquireEncodesTwoBytes() throws {
        let buf = try codec.encode(.awaitAcquire, allocator: alloc)
        // encodes identically to acquire: [1] = 0x81, 0x01
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x01])
    }

    @Test func releaseEncodesTwoBytes() throws {
        let buf = try codec.encode(.release, allocator: alloc)
        // [3] = 0x81, 0x03
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x03])
    }

    @Test func nextTxEncodesTwoBytes() throws {
        let buf = try codec.encode(.nextTx, allocator: alloc)
        // [5] = 0x81, 0x05
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x05])
    }

    @Test func getSizesEncodesTwoBytes() throws {
        let buf = try codec.encode(.getSizes, allocator: alloc)
        // [9] = 0x81, 0x09
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x09])
    }

    @Test func getMeasuresEncodesTwoBytes() throws {
        let buf = try codec.encode(.getMeasures, allocator: alloc)
        // [11] = 0x81, 0x0B
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x0B])
    }

    @Test func doneEncodesTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // [0] = 0x81, 0x00
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x00])
    }

    @Test func replyNextTxNilEncodesNull() throws {
        let buf   = try codec.encode(.replyNextTx(nil), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [6, null] = 0x82, 0x06, 0xF6
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x06)
        #expect(bytes[2] == 0xF6)
    }

    @Test func acquiredEncodesSlotNo() throws {
        let buf   = try codec.encode(.acquired(slotNo: 1), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [2, 1] = 0x82, 0x02, 0x01
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x02)
        #expect(bytes[2] == 0x01)
    }

    @Test func replyHasTxTrueEncodes() throws {
        let buf   = try codec.encode(.replyHasTx(true), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [8, true] = 0x82, 0x08, 0xF5
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x08)
        #expect(bytes[2] == 0xF5)
    }

    @Test func replyHasTxFalseEncodes() throws {
        let buf   = try codec.encode(.replyHasTx(false), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [8, false] = 0x82, 0x08, 0xF4
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x08)
        #expect(bytes[2] == 0xF4)
    }

    @Test func replyGetSizesEncodesNestedArray() throws {
        let cap   = MempoolCapacity(capacityInBytes: 2, sizeInBytes: 1, numberOfTxs: 0)
        let buf   = try codec.encode(.replyGetSizes(cap), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [10, [2, 1, 0]] = 0x82 (array 2), 0x0A (uint 10), 0x83 (array 3), 0x02, 0x01, 0x00
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x0A)
        #expect(bytes[2] == 0x83)
        #expect(bytes[3] == 0x02)
        #expect(bytes[4] == 0x01)
        #expect(bytes[5] == 0x00)
    }

    @Test func hasTxEncodesTxId() throws {
        let txId: TxId = Array(repeating: 0xFF, count: 32)
        let buf   = try codec.encode(.hasTx(txId), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [7, bstr(32)] = 0x82, 0x07, 0x58, 0x20, <32 bytes>
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x07)
        #expect(bytes[2] == 0x58)
        #expect(bytes[3] == 0x20)
        #expect(bytes[4...35] == ArraySlice(Array(repeating: 0xFF, count: 32)))
    }

    // MARK: Large slot number

    @Test func largeSlotNoRoundTrip() throws {
        let largeSlot: UInt64 = 50_000_000
        let decoded = try roundTrip(.acquired(slotNo: largeSlot))
        guard case .acquired(let slot) = decoded else {
            Issue.record("Expected .acquired, got \(decoded)"); return
        }
        #expect(slot == largeSlot)
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

    @Test func wrongArrayLengthForAcquireThrows() {
        // [1, 0] — acquire tag=1 should have array length 1, not 2
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x01, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForNextTxThrows() {
        // [5, 0] — nextTx tag=5 should have array length 1, not 2
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x05, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForDoneThrows() {
        // [0, 0] — done tag=0 should have array length 1, not 2
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x00, 0x00])
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

// MARK: - LocalTxMonitorError

@Suite("LocalTxMonitorError") struct LocalTxMonitorErrorTests {

    @Test func errorCases() {
        let errs: [LocalTxMonitorError] = [
            .unknownMessageTag(99),
            .unexpectedArrayLength(3),
        ]
        #expect(errs.count == 2)
    }
}
