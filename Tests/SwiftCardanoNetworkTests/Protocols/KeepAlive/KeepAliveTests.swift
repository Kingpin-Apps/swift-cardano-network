import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = KeepAliveCodec()

private func roundTrip(_ msg: KeepAliveMessage) throws -> KeepAliveMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

// MARK: - KeepAliveState

@Suite("KeepAliveState") struct KeepAliveStateTests {

    // MARK: Agency

    @Test func agencyRules() {
        #expect(KeepAliveState.idle.agency == .client)
        #expect(KeepAliveState.busy.agency == .server)
        #expect(KeepAliveState.done.agency == .nobody)
    }

    // MARK: Descriptions

    @Test func descriptions() {
        #expect(KeepAliveState.idle.description == "idle")
        #expect(KeepAliveState.busy.description == "busy")
        #expect(KeepAliveState.done.description == "done")
    }

    // MARK: Send transitions

    @Test func idleKeepAliveTobusy() throws {
        let next = try KeepAliveState.idle.afterSend(.keepAlive(cookie: 42))
        #expect(next == .busy)
    }

    @Test func idleDoneToDone() throws {
        let next = try KeepAliveState.idle.afterSend(.done)
        #expect(next == .done)
    }

    @Test func cookieZero() throws {
        let next = try KeepAliveState.idle.afterSend(.keepAlive(cookie: 0))
        #expect(next == .busy)
    }

    @Test func cookieMax() throws {
        let next = try KeepAliveState.idle.afterSend(.keepAlive(cookie: UInt16.max))
        #expect(next == .busy)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendKeepAliveFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.busy.afterSend(.keepAlive(cookie: 1))
        }
    }

    @Test func invalidSendDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.busy.afterSend(.done)
        }
    }

    @Test func invalidSendKeepAliveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.done.afterSend(.keepAlive(cookie: 0))
        }
    }

    @Test func invalidSendResponseFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.idle.afterSend(.keepAliveResponse(cookie: 0))
        }
    }

    // MARK: Receive transitions

    @Test func busyResponseToIdle() throws {
        let next = try KeepAliveState.busy.afterReceive(.keepAliveResponse(cookie: 7))
        #expect(next == .idle)
    }

    @Test func busyResponseCookieZeroToIdle() throws {
        let next = try KeepAliveState.busy.afterReceive(.keepAliveResponse(cookie: 0))
        #expect(next == .idle)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.idle.afterReceive(.keepAliveResponse(cookie: 0))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.done.afterReceive(.keepAliveResponse(cookie: 0))
        }
    }

    @Test func invalidReceiveKeepAliveFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.busy.afterReceive(.keepAlive(cookie: 0))
        }
    }

    @Test func invalidReceiveDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try KeepAliveState.busy.afterReceive(.done)
        }
    }

    // MARK: Full round-trip state sequence

    @Test func fullProbeSequence() throws {
        var state = KeepAliveState.idle
        // Send probe
        state = try state.afterSend(.keepAlive(cookie: 100))
        #expect(state == .busy)
        // Receive response
        state = try state.afterReceive(.keepAliveResponse(cookie: 100))
        #expect(state == .idle)
        // Send another probe
        state = try state.afterSend(.keepAlive(cookie: 101))
        #expect(state == .busy)
        // Receive response
        state = try state.afterReceive(.keepAliveResponse(cookie: 101))
        #expect(state == .idle)
        // Done
        state = try state.afterSend(.done)
        #expect(state == .done)
    }
}

// MARK: - KeepAliveCodec

@Suite("KeepAliveCodec") struct KeepAliveCodecTests {

    // MARK: Round-trips

    @Test func keepAliveRoundTrip() throws {
        let decoded = try roundTrip(.keepAlive(cookie: 1234))
        guard case .keepAlive(let cookie) = decoded else {
            Issue.record("Expected .keepAlive, got \(decoded)"); return
        }
        #expect(cookie == 1234)
    }

    @Test func keepAliveResponseRoundTrip() throws {
        let decoded = try roundTrip(.keepAliveResponse(cookie: 5678))
        guard case .keepAliveResponse(let cookie) = decoded else {
            Issue.record("Expected .keepAliveResponse, got \(decoded)"); return
        }
        #expect(cookie == 5678)
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done, got \(decoded)"); return
        }
    }

    @Test func cookieZeroRoundTrip() throws {
        let decoded = try roundTrip(.keepAlive(cookie: 0))
        guard case .keepAlive(let cookie) = decoded else {
            Issue.record("Expected .keepAlive, got \(decoded)"); return
        }
        #expect(cookie == 0)
    }

    @Test func cookieMaxRoundTrip() throws {
        let decoded = try roundTrip(.keepAlive(cookie: UInt16.max))
        guard case .keepAlive(let cookie) = decoded else {
            Issue.record("Expected .keepAlive, got \(decoded)"); return
        }
        #expect(cookie == UInt16.max)
    }

    @Test func responseMaxCookieRoundTrip() throws {
        let decoded = try roundTrip(.keepAliveResponse(cookie: UInt16.max))
        guard case .keepAliveResponse(let cookie) = decoded else {
            Issue.record("Expected .keepAliveResponse, got \(decoded)"); return
        }
        #expect(cookie == UInt16.max)
    }

    // MARK: Byte-level encoding checks

    @Test func keepAliveEncodesCorrectly() throws {
        let buf   = try codec.encode(.keepAlive(cookie: 7), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [0, 7] = 0x82 (array 2), 0x00 (uint 0 = tag), 0x07 (uint 7 = cookie)
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x00)  // tag
        #expect(bytes[2] == 0x07)  // cookie
    }

    @Test func keepAliveResponseEncodesCorrectly() throws {
        let buf   = try codec.encode(.keepAliveResponse(cookie: 7), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [1, 7] = 0x82, 0x01, 0x07
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x01)  // tag
        #expect(bytes[2] == 0x07)  // cookie
    }

    @Test func doneEncodesTwoBytes() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        // [2] = 0x81, 0x02
        #expect(buf.readableBytes == 2)
        #expect(buf.getBytes(at: buf.readerIndex, length: 2) == [0x81, 0x02])
    }

    @Test func keepAliveEncodesMultiByteCoookie() throws {
        let buf   = try codec.encode(.keepAlive(cookie: 256), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // cookie 256 requires 2-byte encoding: 0x19, 0x01, 0x00
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x00)   // tag keepAlive
        #expect(bytes[2] == 0x19)   // uint, 2-byte length follows
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x00)
    }

    @Test func responseEncodesMultiByteCookie() throws {
        let buf   = try codec.encode(.keepAliveResponse(cookie: 1000), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes[0] == 0x82)
        #expect(bytes[1] == 0x01)   // tag keepAliveResponse
        // cookie 1000 = 0x19 0x03 0xE8
        #expect(bytes[2] == 0x19)
        #expect(bytes[3] == 0x03)
        #expect(bytes[4] == 0xE8)
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

    @Test func wrongArrayLengthForDoneThrows() {
        // [2, 0] — done should be [2], not [2, 0]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x02, 0x00])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthForKeepAliveThrows() {
        // [0] — keepAlive needs a cookie
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x00])
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

// MARK: - KeepAliveError

@Suite("KeepAliveError") struct KeepAliveErrorTests {

    @Test func errorCases() {
        let errs: [KeepAliveError] = [
            .timeout(cookie: 1, elapsedNanoseconds: 1_000_000_000),
            .cookieMismatch(sent: 1, received: 2),
            .unknownMessageTag(99),
            .unexpectedArrayLength(3),
        ]
        #expect(errs.count == 4)
    }

    @Test func timeoutCarriesCookieAndElapsed() {
        let err = KeepAliveError.timeout(cookie: 42, elapsedNanoseconds: 5_000_000_000)
        guard case .timeout(let cookie, let elapsed) = err else {
            Issue.record("Expected .timeout"); return
        }
        #expect(cookie == 42)
        #expect(elapsed == 5_000_000_000)
    }

    @Test func cookieMismatchCarriesBothValues() {
        let err = KeepAliveError.cookieMismatch(sent: 10, received: 99)
        guard case .cookieMismatch(let sent, let received) = err else {
            Issue.record("Expected .cookieMismatch"); return
        }
        #expect(sent == 10)
        #expect(received == 99)
    }
}
