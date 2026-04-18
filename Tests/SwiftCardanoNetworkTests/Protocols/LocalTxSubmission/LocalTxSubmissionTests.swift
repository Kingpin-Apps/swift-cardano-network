import Testing
import NIOCore
import SwiftCardanoCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = LocalTxSubmissionCodec()

private func roundTrip(_ msg: LocalTxSubmissionMessage) throws -> LocalTxSubmissionMessage {
    let buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(buf)
}

private func makeRawTx(era: Era = .conway, bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]) -> RawTransaction {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return RawTransaction(era: era, rawCBOR: buf)
}

private func makeRejection(era: Era = .conway, bytes: [UInt8] = [0xBA, 0xD0]) -> TxRejection {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return TxRejection(era: era, reasonCBOR: buf)
}

// MARK: - RawTransaction

@Suite("RawTransaction") struct RawTransactionTests {
    @Test func storesEraAndBytes() {
        let tx = makeRawTx(era: .babbage, bytes: [0x01, 0x02, 0x03])
        #expect(tx.era == .babbage)
        #expect(tx.rawCBOR.readableBytes == 3)
    }

    @Test func conwayEra() {
        let tx = makeRawTx(era: .conway)
        #expect(tx.era == .conway)
    }
}

// MARK: - TxRejection

@Suite("TxRejection") struct TxRejectionTests {
    @Test func storesEraAndReason() {
        let r = makeRejection(era: .alonzo, bytes: [0xFF, 0xFE])
        #expect(r.era == .alonzo)
        #expect(r.reasonCBOR.readableBytes == 2)
    }
}

// MARK: - LocalTxSubmissionState

@Suite("LocalTxSubmissionState") struct LocalTxSubmissionStateTests {

    @Test func agencyRules() {
        #expect(LocalTxSubmissionState.idle.agency == .client)
        #expect(LocalTxSubmissionState.busy.agency == .server)
        #expect(LocalTxSubmissionState.done.agency == .nobody)
    }

    @Test func descriptions() {
        #expect(LocalTxSubmissionState.idle.description == "idle")
        #expect(LocalTxSubmissionState.busy.description == "busy")
        #expect(LocalTxSubmissionState.done.description == "done")
    }

    // MARK: Send transitions

    @Test func idleSubmitTxToBusy() throws {
        let next = try LocalTxSubmissionState.idle.afterSend(.submitTx(makeRawTx()))
        #expect(next == .busy)
    }

    @Test func idleDoneToDone() throws {
        let next = try LocalTxSubmissionState.idle.afterSend(.done)
        #expect(next == .done)
    }

    @Test func invalidSendFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxSubmissionState.busy.afterSend(.done)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxSubmissionState.done.afterSend(.submitTx(makeRawTx()))
        }
    }

    // MARK: Receive transitions

    @Test func busyAcceptTxToIdle() throws {
        let next = try LocalTxSubmissionState.busy.afterReceive(.acceptTx)
        #expect(next == .idle)
    }

    @Test func busyRejectTxToIdle() throws {
        let next = try LocalTxSubmissionState.busy.afterReceive(.rejectTx(makeRejection()))
        #expect(next == .idle)
    }

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxSubmissionState.idle.afterReceive(.acceptTx)
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try LocalTxSubmissionState.done.afterReceive(.rejectTx(makeRejection()))
        }
    }
}

// MARK: - LocalTxSubmissionCodec

@Suite("LocalTxSubmissionCodec") struct LocalTxSubmissionCodecTests {

    // MARK: Round-trips

    @Test func submitTxRoundTrip() throws {
        let tx      = makeRawTx(era: .conway, bytes: [0xCA, 0xFE, 0xBA, 0xBE])
        let decoded = try roundTrip(.submitTx(tx))
        guard case .submitTx(let t) = decoded else {
            Issue.record("Expected .submitTx, got \(decoded)"); return
        }
        #expect(t.era == .conway)
        #expect(t.rawCBOR.readableBytes == 4)
        #expect(t.rawCBOR.getBytes(at: t.rawCBOR.readerIndex, length: 4) == [0xCA, 0xFE, 0xBA, 0xBE])
    }

    @Test func acceptTxRoundTrip() throws {
        let decoded = try roundTrip(.acceptTx)
        guard case .acceptTx = decoded else {
            Issue.record("Expected .acceptTx, got \(decoded)"); return
        }
    }

    @Test func rejectTxRoundTrip() throws {
        let rejection = makeRejection(era: .babbage, bytes: [0x01, 0x02, 0x03])
        let decoded   = try roundTrip(.rejectTx(rejection))
        guard case .rejectTx(let r) = decoded else {
            Issue.record("Expected .rejectTx, got \(decoded)"); return
        }
        #expect(r.era == .babbage)
        #expect(r.reasonCBOR.readableBytes == 3)
        #expect(r.reasonCBOR.getBytes(at: r.reasonCBOR.readerIndex, length: 3) == [0x01, 0x02, 0x03])
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    // MARK: Byte-level encoding checks

    @Test func acceptTxEncodesTwoBytes() throws {
        let buf = try codec.encode(.acceptTx, allocator: alloc)
        // CBOR [1] = 0x81 (array len 1) 0x01 (uint 1)
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x01])
    }

    @Test func doneEncodesTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // CBOR [3] = 0x81 (array len 1) 0x03 (uint 3)
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x03])
    }

    @Test func submitTxEncodesEraAndPayload() throws {
        let tx  = makeRawTx(era: .conway, bytes: [0xAB, 0xCD])
        let buf = try codec.encode(.submitTx(tx), allocator: alloc)

        // Outer: [0, [era, bstr(2)]]
        // 0x82           array(2)
        // 0x00           uint(0)         msgSubmitTx
        // 0x82           array(2)        era-tagged
        // 0x06           uint(6)         Conway era
        // 0x42 0xAB 0xCD bstr(2)         tx bytes
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes[0] == 0x82)  // array(2)
        #expect(bytes[1] == 0x00)  // uint(0) = submitTx
        #expect(bytes[2] == 0x82)  // array(2) era-tagged
        #expect(bytes[3] == 0x06)  // uint(6) = Conway
        #expect(bytes[4] == 0x42)  // bstr(2)
        #expect(bytes[5] == 0xAB)
        #expect(bytes[6] == 0xCD)
    }

    @Test func rejectTxEncodesEraAndReason() throws {
        let r   = makeRejection(era: .alonzo, bytes: [0xFF])
        let buf = try codec.encode(.rejectTx(r), allocator: alloc)

        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes[0] == 0x82)  // array(2)
        #expect(bytes[1] == 0x02)  // uint(2) = rejectTx
        #expect(bytes[2] == 0x82)  // array(2) era-tagged
        #expect(bytes[3] == 0x04)  // uint(4) = Alonzo era
        #expect(bytes[4] == 0x41)  // bstr(1)
        #expect(bytes[5] == 0xFF)
    }

    // MARK: Era round-trip across all eras

    @Test func byronEraRoundTrip() throws {
        let tx      = makeRawTx(era: .byron, bytes: [0x01])
        let decoded = try roundTrip(.submitTx(tx))
        guard case .submitTx(let t) = decoded else {
            Issue.record("Expected .submitTx"); return
        }
        #expect(t.era == .byron)
    }

    @Test func shelleyEraRoundTrip() throws {
        let tx      = makeRawTx(era: .shelley, bytes: [0x01])
        let decoded = try roundTrip(.submitTx(tx))
        guard case .submitTx(let t) = decoded else {
            Issue.record("Expected .submitTx"); return
        }
        #expect(t.era == .shelley)
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        // Encode a 1-element array with tag 99
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x81, 0x18, 0x63])  // [99] in CBOR
        #expect(throws: (any Error).self) {
            _ = try codec.decode(buf)
        }
    }

    @Test func wrongArrayLengthForAcceptThrows() {
        // [1, 0] — acceptTx should be [1], not [1, 0]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x01, 0x00])
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

// MARK: - LocalTxSubmissionError

@Suite("LocalTxSubmissionError") struct LocalTxSubmissionErrorTests {
    @Test func errorCases() {
        let errs: [LocalTxSubmissionError] = [
            .rejected(makeRejection()),
            .unknownMessageTag(99),
            .unexpectedArrayLength(3),
            .unknownEraTag(99),
        ]
        #expect(errs.count == 4)
    }
}
