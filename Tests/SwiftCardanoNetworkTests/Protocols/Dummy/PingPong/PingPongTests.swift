import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = PingPongCodec()

private func roundTrip(_ msg: PingPongMessage) throws -> PingPongMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

// MARK: - PingPongState

@Suite("PingPongState") struct PingPongStateTests {

    // MARK: Agency

    @Test func agencyRules() {
        #expect(PingPongState.idle.agency == .client)
        #expect(PingPongState.busy.agency == .server)
        #expect(PingPongState.done.agency == .nobody)
    }

    // MARK: Descriptions

    @Test func descriptions() {
        #expect(PingPongState.idle.description == "idle")
        #expect(PingPongState.busy.description == "busy")
        #expect(PingPongState.done.description == "done")
    }

    // MARK: Valid send transitions

    @Test func idlePingToBusy() throws {
        let next = try PingPongState.idle.afterSend(.ping)
        #expect(next == .busy)
    }

    @Test func idleDoneToDone() throws {
        let next = try PingPongState.idle.afterSend(.done)
        #expect(next == .done)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendPongFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.idle.afterSend(.pong)
        }
    }

    @Test func invalidSendPingFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.busy.afterSend(.ping)
        }
    }

    @Test func invalidSendDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.busy.afterSend(.done)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.done.afterSend(.ping)
        }
        #expect(throws: (any Error).self) {
            _ = try PingPongState.done.afterSend(.done)
        }
    }

    // MARK: Valid receive transitions

    @Test func busyPongToIdle() throws {
        let next = try PingPongState.busy.afterReceive(.pong)
        #expect(next == .idle)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceivePingFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.busy.afterReceive(.ping)
        }
    }

    @Test func invalidReceiveDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.busy.afterReceive(.done)
        }
    }

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.idle.afterReceive(.pong)
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try PingPongState.done.afterReceive(.pong)
        }
    }

    // MARK: Full protocol walk

    @Test func fullSequenceReachesDone() throws {
        var state = PingPongState.idle
        for _ in 0..<3 {
            state = try state.afterSend(.ping)
            #expect(state == .busy)
            state = try state.afterReceive(.pong)
            #expect(state == .idle)
        }
        state = try state.afterSend(.done)
        #expect(state == .done)
    }
}

// MARK: - PingPongCodec

@Suite("PingPongCodec") struct PingPongCodecTests {

    // MARK: Round-trips

    @Test func pingRoundTrip() throws {
        #expect(try roundTrip(.ping) == .ping)
    }

    @Test func pongRoundTrip() throws {
        #expect(try roundTrip(.pong) == .pong)
    }

    @Test func doneRoundTrip() throws {
        #expect(try roundTrip(.done) == .done)
    }

    // MARK: Byte-level encoding

    @Test func doneEncodesAsArrayZero() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes == [0x81, 0x00])
    }

    @Test func pingEncodesAsArrayOne() throws {
        let buf = try codec.encode(.ping, allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes == [0x81, 0x01])
    }

    @Test func pongEncodesAsArrayTwo() throws {
        let buf = try codec.encode(.pong, allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        #expect(bytes == [0x81, 0x02])
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        // [99] — 0x81, 0x18, 0x63
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x81, 0x18, 0x63])
        #expect(throws: PingPongError.self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func wrongArrayLengthThrows() {
        // [1, 0] — ping should be [1], not [1, 0]
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x01, 0x00])
        #expect(throws: PingPongError.self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func emptyBufferThrows() {
        var buf = alloc.buffer(capacity: 0)
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }

    @Test func nonArrayPrefixThrows() {
        // First byte isn't a CBOR array header.
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x00, 0x01])
        #expect(throws: (any Error).self) {
            _ = try codec.decode(&buf)
        }
    }
}

// MARK: - PingPongError

@Suite("PingPongError") struct PingPongErrorTests {

    @Test func unknownMessageTagCarriesTag() {
        let err = PingPongError.unknownMessageTag(99)
        guard case .unknownMessageTag(let tag) = err else {
            Issue.record("Expected .unknownMessageTag"); return
        }
        #expect(tag == 99)
    }

    @Test func unexpectedArrayLengthCarriesCount() {
        let err = PingPongError.unexpectedArrayLength(7)
        guard case .unexpectedArrayLength(let n) = err else {
            Issue.record("Expected .unexpectedArrayLength"); return
        }
        #expect(n == 7)
    }

    @Test func distinctErrorsAreNotEqual() {
        #expect(PingPongError.unknownMessageTag(1) != PingPongError.unknownMessageTag(2))
        #expect(PingPongError.unexpectedArrayLength(1) != PingPongError.unexpectedArrayLength(2))
        #expect(
            PingPongError.unknownMessageTag(1) != PingPongError.unexpectedArrayLength(1)
        )
    }
}

// MARK: - MuxSDU.ProtocolID.pingPong

@Suite("PingPong protocol ID") struct PingPongProtocolIDTests {

    @Test func pingPongIDIsReserved() {
        #expect(MuxSDU.ProtocolID.pingPong == 0x7FFE)
    }

    @Test func pingPongDoesNotCollideWithProductionIDs() {
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
        #expect(!production.contains(MuxSDU.ProtocolID.pingPong))
    }

    @Test func pingPongFitsInFifteenBits() {
        // Must not set the responder-mode bit (0x8000).
        #expect(MuxSDU.ProtocolID.pingPong & 0x8000 == 0)
    }
}
