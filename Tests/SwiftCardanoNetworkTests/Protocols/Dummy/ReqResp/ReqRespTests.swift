import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

private func rawBuf(_ bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

/// A codec that encodes `UInt64` via CBOR uint and decodes the same way.
/// Exercises the generic codec with a non-ByteBuffer payload type.
private func intCodec() -> ReqRespCodec<UInt64, UInt64> {
    ReqRespCodec<UInt64, UInt64>(
        encodeRequest:  { value, buf in CBORLite.writeUInt(value, into: &buf) },
        decodeRequest:  { buf in try CBORLite.readUInt(from: &buf) },
        encodeResponse: { value, buf in CBORLite.writeUInt(value, into: &buf) },
        decodeResponse: { buf in try CBORLite.readUInt(from: &buf) }
    )
}

/// A codec with text request and uint response, demonstrating mixed payload types.
private func mixedCodec() -> ReqRespCodec<String, UInt64> {
    ReqRespCodec<String, UInt64>(
        encodeRequest:  { value, buf in CBORLite.writeText(value, into: &buf) },
        decodeRequest:  { buf in try CBORLite.readText(from: &buf) },
        encodeResponse: { value, buf in CBORLite.writeUInt(value, into: &buf) },
        decodeResponse: { buf in try CBORLite.readUInt(from: &buf) }
    )
}

// MARK: - ReqRespState

@Suite("ReqRespState") struct ReqRespStateTests {

    typealias Msg = ReqRespMessage<UInt64, UInt64>

    // MARK: Agency

    @Test func agencyRules() {
        #expect(ReqRespState.idle.agency == .client)
        #expect(ReqRespState.busy.agency == .server)
        #expect(ReqRespState.done.agency == .nobody)
    }

    // MARK: Descriptions

    @Test func descriptions() {
        #expect(ReqRespState.idle.description == "idle")
        #expect(ReqRespState.busy.description == "busy")
        #expect(ReqRespState.done.description == "done")
    }

    // MARK: Valid send transitions

    @Test func idleRequestToBusy() throws {
        let next = try ReqRespState.idle.afterSend(Msg.request(42))
        #expect(next == .busy)
    }

    @Test func idleDoneToDone() throws {
        let next = try ReqRespState.idle.afterSend(Msg.done)
        #expect(next == .done)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendResponseFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.idle.afterSend(Msg.response(1))
        }
    }

    @Test func invalidSendRequestFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.busy.afterSend(Msg.request(1))
        }
    }

    @Test func invalidSendDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.busy.afterSend(Msg.done)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.done.afterSend(Msg.request(1))
        }
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.done.afterSend(Msg.done)
        }
    }

    // MARK: Valid receive transitions

    @Test func busyResponseToIdle() throws {
        let next = try ReqRespState.busy.afterReceive(Msg.response(99))
        #expect(next == .idle)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceiveRequestFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.busy.afterReceive(Msg.request(1))
        }
    }

    @Test func invalidReceiveDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.busy.afterReceive(Msg.done)
        }
    }

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.idle.afterReceive(Msg.response(1))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try ReqRespState.done.afterReceive(Msg.response(1))
        }
    }

    // MARK: Full protocol walk

    @Test func fullSequenceReachesDone() throws {
        var state = ReqRespState.idle
        for i in UInt64(0)..<3 {
            state = try state.afterSend(Msg.request(i))
            #expect(state == .busy)
            state = try state.afterReceive(Msg.response(i))
            #expect(state == .idle)
        }
        state = try state.afterSend(Msg.done)
        #expect(state == .done)
    }
}

// MARK: - ReqRespCodec (raw ByteBuffer)

@Suite("ReqRespCodec.raw()") struct ReqRespCodecRawTests {

    private let codec = ReqRespCodec<ByteBuffer, ByteBuffer>.raw()

    // MARK: Round-trips

    @Test func doneRoundTrip() throws {
        var buf = try codec.encode(.done, allocator: alloc)
        let decoded = try codec.decode(&buf)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    @Test func requestRoundTrip() throws {
        let payload = rawBuf([0xDE, 0xAD, 0xBE, 0xEF])
        var encoded = try codec.encode(.request(payload), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .request(let received) = decoded else {
            Issue.record("Expected .request, got \(decoded)"); return
        }
        #expect(received.readableBytes == 4)
        #expect(received.getBytes(at: received.readerIndex, length: 4) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func responseRoundTrip() throws {
        let payload = rawBuf([0x01, 0x02, 0x03])
        var encoded = try codec.encode(.response(payload), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .response(let received) = decoded else {
            Issue.record("Expected .response, got \(decoded)"); return
        }
        #expect(received.readableBytes == 3)
    }

    @Test func emptyRequestPayloadRoundTrip() throws {
        let payload = alloc.buffer(capacity: 0)
        var encoded = try codec.encode(.request(payload), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .request(let received) = decoded else {
            Issue.record("Expected .request"); return
        }
        #expect(received.readableBytes == 0)
    }

    // MARK: Byte-level encoding

    @Test func doneEncodesAsArrayZero() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes == [0x81, 0x00])
    }

    @Test func requestTagIsOne() throws {
        let payload = rawBuf([0xAA])
        let buf = try codec.encode(.request(payload), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: 3)!
        #expect(bytes[0] == 0x82) // array of 2
        #expect(bytes[1] == 0x01) // request tag
        // bytes[2] is the start of the CBOR byte-string header.
    }

    @Test func responseTagIsTwo() throws {
        let payload = rawBuf([0xBB])
        let buf = try codec.encode(.response(payload), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: 3)!
        #expect(bytes[0] == 0x82) // array of 2
        #expect(bytes[1] == 0x02) // response tag
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        // [3, 0] — tag 3 is undefined
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x03, 0x40]) // 0x40 = empty byte string
        #expect(throws: ReqRespError.self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForDoneThrows() {
        // [0, 0] — done should be [0]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x00, 0x00])
        #expect(throws: ReqRespError.self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForRequestThrows() {
        // [1] — request needs a payload
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x01])
        #expect(throws: ReqRespError.self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForResponseThrows() {
        // [2] — response needs a payload
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x02])
        #expect(throws: ReqRespError.self) {
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

// MARK: - ReqRespCodec (generic payloads)

@Suite("ReqRespCodec (generic)") struct ReqRespCodecGenericTests {

    @Test func uintPayloadsRoundTrip() throws {
        let codec = intCodec()
        var encoded = try codec.encode(.request(1234), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .request(let value) = decoded else {
            Issue.record("Expected .request"); return
        }
        #expect(value == 1234)
    }

    @Test func uintResponseRoundTrip() throws {
        let codec = intCodec()
        var encoded = try codec.encode(.response(UInt64.max), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .response(let value) = decoded else {
            Issue.record("Expected .response"); return
        }
        #expect(value == UInt64.max)
    }

    @Test func mixedTextAndIntRoundTrip() throws {
        let codec = mixedCodec()
        var encoded = try codec.encode(.request("hello world"), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .request(let value) = decoded else {
            Issue.record("Expected .request"); return
        }
        #expect(value == "hello world")
    }

    @Test func mixedResponseRoundTrip() throws {
        let codec = mixedCodec()
        var encoded = try codec.encode(.response(999), allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .response(let value) = decoded else {
            Issue.record("Expected .response"); return
        }
        #expect(value == 999)
    }

    @Test func doneIgnoresCodecClosures() throws {
        // Even when the payload codecs would throw, `.done` must encode/decode fine.
        let codec = ReqRespCodec<UInt64, UInt64>(
            encodeRequest:  { _, _ in throw ReqRespError.unknownMessageTag(999) },
            decodeRequest:  { _ in throw ReqRespError.unknownMessageTag(999) },
            encodeResponse: { _, _ in throw ReqRespError.unknownMessageTag(999) },
            decodeResponse: { _ in throw ReqRespError.unknownMessageTag(999) }
        )
        var encoded = try codec.encode(.done, allocator: alloc)
        let decoded = try codec.decode(&encoded)
        guard case .done = decoded else {
            Issue.record("Expected .done"); return
        }
    }

    @Test func encoderErrorPropagates() {
        struct BoomError: Error {}
        let codec = ReqRespCodec<UInt64, UInt64>(
            encodeRequest:  { _, _ in throw BoomError() },
            decodeRequest:  { _ in 0 },
            encodeResponse: { _, _ in },
            decodeResponse: { _ in 0 }
        )
        #expect(throws: BoomError.self) {
            _ = try codec.encode(.request(1), allocator: alloc)
        }
    }

    @Test func decoderErrorPropagates() {
        struct BoomError: Error {}
        let codec = ReqRespCodec<UInt64, UInt64>(
            encodeRequest:  { value, buf in CBORLite.writeUInt(value, into: &buf) },
            decodeRequest:  { _ in throw BoomError() },
            encodeResponse: { _, _ in },
            decodeResponse: { _ in 0 }
        )
        var encoded = try! codec.encode(.request(1), allocator: alloc)
        #expect(throws: BoomError.self) {
            _ = try codec.decode(&encoded)
        }
    }
}

// MARK: - ReqRespError

@Suite("ReqRespError") struct ReqRespErrorTests {

    @Test func unknownMessageTagCarriesTag() {
        let err = ReqRespError.unknownMessageTag(42)
        guard case .unknownMessageTag(let tag) = err else {
            Issue.record("Expected .unknownMessageTag"); return
        }
        #expect(tag == 42)
    }

    @Test func unexpectedArrayLengthCarriesCount() {
        let err = ReqRespError.unexpectedArrayLength(5)
        guard case .unexpectedArrayLength(let n) = err else {
            Issue.record("Expected .unexpectedArrayLength"); return
        }
        #expect(n == 5)
    }

    @Test func distinctErrorsAreNotEqual() {
        #expect(ReqRespError.unknownMessageTag(1) != ReqRespError.unknownMessageTag(2))
        #expect(ReqRespError.unexpectedArrayLength(1) != ReqRespError.unexpectedArrayLength(2))
    }
}

// MARK: - MuxSDU.ProtocolID.reqResp

@Suite("ReqResp protocol ID") struct ReqRespProtocolIDTests {

    @Test func reqRespIDIsReserved() {
        #expect(MuxSDU.ProtocolID.reqResp == 0x7FFD)
    }

    @Test func reqRespDoesNotCollideWithProductionIDs() {
        let production: [UInt16] = [
            MuxSDU.ProtocolID.handshake,
            MuxSDU.ProtocolID.chainSync,
            MuxSDU.ProtocolID.blockFetch,
            MuxSDU.ProtocolID.txSubmission2,
            MuxSDU.ProtocolID.ntcChainSync,
            MuxSDU.ProtocolID.localTxSubmission,
            MuxSDU.ProtocolID.localStateQuery,
            MuxSDU.ProtocolID.keepAlive,
            MuxSDU.ProtocolID.localTxMonitor,
            MuxSDU.ProtocolID.peerSharing,
        ]
        #expect(!production.contains(MuxSDU.ProtocolID.reqResp))
    }

    @Test func reqRespDoesNotCollideWithPingPong() {
        #expect(MuxSDU.ProtocolID.reqResp != MuxSDU.ProtocolID.pingPong)
    }

    @Test func reqRespFitsInFifteenBits() {
        #expect(MuxSDU.ProtocolID.reqResp & 0x8000 == 0)
    }
}
