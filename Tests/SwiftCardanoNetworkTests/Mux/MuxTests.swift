import Logging
import NIOCore
import NIOEmbedded
import NIOExtras
import Testing

@testable import SwiftCardanoNetwork

// MARK: - MuxSDU

@Suite("MuxSDU") struct MuxSDUTests {
    private let alloc = ByteBufferAllocator()

    @Test func isResponderWhenTopBitSet() {
        let sdu = MuxSDU(timestamp: 0, protocolID: 0x8002, payload: alloc.buffer(capacity: 0))
        #expect(sdu.isResponder == true)
    }

    @Test func isInitiatorWhenTopBitClear() {
        let sdu = MuxSDU(timestamp: 0, protocolID: 0x0002, payload: alloc.buffer(capacity: 0))
        #expect(sdu.isResponder == false)
    }

    @Test func miniProtocolIDStripsModebit() {
        let responder = MuxSDU(timestamp: 0, protocolID: 0x8002, payload: alloc.buffer(capacity: 0))
        let initiator = MuxSDU(timestamp: 0, protocolID: 0x0002, payload: alloc.buffer(capacity: 0))
        #expect(responder.miniProtocolID == 2)
        #expect(initiator.miniProtocolID == 2)
    }

    @Test func payloadLengthMatchesActualPayload() {
        var payload = alloc.buffer(capacity: 6)
        payload.writeBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let sdu = MuxSDU(timestamp: 0, protocolID: 0, payload: payload)
        #expect(sdu.payloadLength == 6)
    }

    @Test func protocolIDConstants() {
        #expect(MuxSDU.ProtocolID.handshake == 0)
        #expect(MuxSDU.ProtocolID.chainSync == 2)
        #expect(MuxSDU.ProtocolID.blockFetch == 3)
        #expect(MuxSDU.ProtocolID.txSubmission2 == 4)
        #expect(MuxSDU.ProtocolID.localTxSubmission == 6)
        #expect(MuxSDU.ProtocolID.localStateQuery == 7)
        #expect(MuxSDU.ProtocolID.keepAlive == 8)
        #expect(MuxSDU.ProtocolID.localTxMonitor == 9)
        #expect(MuxSDU.ProtocolID.peerSharing == 10)
    }
}

// MARK: - MuxError

@Suite("MuxError") struct MuxErrorTests {
    @Test func payloadTooLargeError() {
        let err = MuxError.payloadTooLarge(protocolID: 2, length: 99999, max: 12288)
        if case .payloadTooLarge(let pid, let len, let max) = err {
            #expect(pid == 2)
            #expect(len == 99999)
            #expect(max == 12288)
        } else {
            Issue.record("Wrong error case")
        }
    }

    @Test func incompleteFrameError() {
        let err = MuxError.incompleteFrame
        if case .incompleteFrame = err { /* pass */  } else { Issue.record("Wrong error case") }
    }

    @Test func unknownProtocolError() {
        let err = MuxError.unknownProtocol(42)
        if case .unknownProtocol(let id) = err {
            #expect(id == 42)
        } else {
            Issue.record("Wrong error case")
        }
    }
}

// MARK: - MuxFrameDecoder (via EmbeddedChannel)

@Suite("MuxFrameDecoder") struct MuxFrameDecoderTests {
    private let alloc = ByteBufferAllocator()
    private let logger = Logger(label: "test.mux")

    private func makeChannel() throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MuxFrameDecoder(maxPayloadSize: 65_535, logger: logger))
        )
        return ch
    }

    @Test func decodesValidFrame() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var buf = alloc.buffer(capacity: 12)
        buf.writeInteger(UInt32(99), endianness: .big)  // timestamp
        buf.writeInteger(UInt16(0x0003), endianness: .big)  // protocolID=3
        buf.writeInteger(UInt16(4), endianness: .big)  // payloadLength=4
        buf.writeBytes([0xCA, 0xFE, 0xBA, 0xBE])

        try ch.writeInbound(buf)

        let sdu = try ch.readInbound(as: MuxSDU.self)
        #expect(sdu != nil)
        #expect(sdu?.timestamp == 99)
        #expect(sdu?.miniProtocolID == 3)
        #expect(sdu?.isResponder == false)
        #expect(sdu?.payloadLength == 4)
    }

    @Test func needsMoreDataForIncompleteHeader() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var buf = alloc.buffer(capacity: 4)
        buf.writeBytes([0x00, 0x00, 0x00, 0x00])  // only 4 bytes, header needs 8
        try ch.writeInbound(buf)

        let sdu = try ch.readInbound(as: MuxSDU.self)
        #expect(sdu == nil)
    }

    @Test func needsMoreDataForIncompletePayload() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var buf = alloc.buffer(capacity: 10)
        buf.writeInteger(UInt32(0), endianness: .big)
        buf.writeInteger(UInt16(0), endianness: .big)
        buf.writeInteger(UInt16(8), endianness: .big)  // claims 8-byte payload
        buf.writeBytes([0x01, 0x02])  // only 2 bytes provided

        try ch.writeInbound(buf)
        let sdu = try ch.readInbound(as: MuxSDU.self)
        #expect(sdu == nil)
    }

    @Test func throwsForOversizedPayload() throws {
        let ch = EmbeddedChannel()
        defer { _ = try? ch.finish() }
        try ch.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MuxFrameDecoder(maxPayloadSize: 4, logger: logger))
        )

        var buf = alloc.buffer(capacity: 10)
        buf.writeInteger(UInt32(0), endianness: .big)
        buf.writeInteger(UInt16(0), endianness: .big)
        buf.writeInteger(UInt16(8), endianness: .big)  // 8 > maxPayloadSize of 4
        buf.writeBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        #expect(throws: (any Error).self) { try ch.writeInbound(buf) }
    }

    @Test func decodesResponderFrame() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var buf = alloc.buffer(capacity: 9)
        buf.writeInteger(UInt32(0), endianness: .big)
        buf.writeInteger(UInt16(0x8002), endianness: .big)  // mode bit set
        buf.writeInteger(UInt16(1), endianness: .big)
        buf.writeBytes([0xFF])

        try ch.writeInbound(buf)
        let sdu = try ch.readInbound(as: MuxSDU.self)
        #expect(sdu?.isResponder == true)
        #expect(sdu?.miniProtocolID == 2)
    }

    @Test func decodesMultipleFramesFromOneWrite() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var buf = alloc.buffer(capacity: 20)
        // Frame 1: protocol 2, 1-byte payload
        buf.writeInteger(UInt32(1), endianness: .big)
        buf.writeInteger(UInt16(2), endianness: .big)
        buf.writeInteger(UInt16(1), endianness: .big)
        buf.writeBytes([0xAA])
        // Frame 2: protocol 7, 1-byte payload
        buf.writeInteger(UInt32(2), endianness: .big)
        buf.writeInteger(UInt16(7), endianness: .big)
        buf.writeInteger(UInt16(1), endianness: .big)
        buf.writeBytes([0xBB])

        try ch.writeInbound(buf)

        let first = try ch.readInbound(as: MuxSDU.self)
        let second = try ch.readInbound(as: MuxSDU.self)
        #expect(first?.miniProtocolID == 2)
        #expect(second?.miniProtocolID == 7)
    }
}

// MARK: - MuxFrameEncoder (via EmbeddedChannel)

@Suite("MuxFrameEncoder") struct MuxFrameEncoderTests {
    private let alloc = ByteBufferAllocator()

    private func makeChannel() throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandler(MessageToByteHandler(MuxFrameEncoder()))
        return ch
    }

    @Test func encodesBigEndianHeader() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var payload = alloc.buffer(capacity: 2)
        payload.writeBytes([0xAB, 0xCD])
        let sdu = MuxSDU(timestamp: 0x1234_5678, protocolID: 0x0003, payload: payload)

        try ch.writeOutbound(sdu)
        var encoded = try ch.readOutbound(as: ByteBuffer.self)

        #expect(encoded?.readableBytes == 10)  // 8-byte header + 2-byte payload

        let ts = encoded?.readInteger(endianness: .big, as: UInt32.self)
        let pid = encoded?.readInteger(endianness: .big, as: UInt16.self)
        let plen = encoded?.readInteger(endianness: .big, as: UInt16.self)

        #expect(ts == 0x1234_5678)
        #expect(pid == 0x0003)
        #expect(plen == 2)
    }

    @Test func encodesPayloadBytes() throws {
        let ch = try makeChannel()
        defer { _ = try? ch.finish() }

        var payload = alloc.buffer(capacity: 3)
        payload.writeBytes([0x01, 0x02, 0x03])
        let sdu = MuxSDU(timestamp: 0, protocolID: 0, payload: payload)

        try ch.writeOutbound(sdu)
        var encoded = try ch.readOutbound(as: ByteBuffer.self)
        encoded?.moveReaderIndex(forwardBy: 8)  // skip header
        let payloadBytes = encoded?.readBytes(length: 3)
        #expect(payloadBytes == [0x01, 0x02, 0x03])
    }
}

// MARK: - MuxFrameDecoder + MuxFrameEncoder round-trip

@Suite("MuxCodecRoundTrip") struct MuxCodecRoundTripTests {
    private let alloc = ByteBufferAllocator()
    private let logger = Logger(label: "test.mux")

    @Test func encodeDecodedRoundTrip() throws {
        // Outbound pipeline: MessageToByteHandler encodes MuxSDU → bytes.
        let encoderChannel = EmbeddedChannel()
        defer { _ = try? encoderChannel.finish() }
        try encoderChannel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(MuxFrameEncoder()))

        // Inbound pipeline: ByteToMessageHandler decodes bytes → MuxSDU.
        let decoderChannel = EmbeddedChannel()
        defer { _ = try? decoderChannel.finish() }
        try decoderChannel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MuxFrameDecoder(maxPayloadSize: 65_535, logger: logger))
        )

        var payload = alloc.buffer(capacity: 4)
        payload.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let original = MuxSDU(timestamp: 777, protocolID: 0x8005, payload: payload)

        try encoderChannel.writeOutbound(original)
        if let encoded = try encoderChannel.readOutbound(as: ByteBuffer.self) {
            try decoderChannel.writeInbound(encoded)
        }

        let decoded = try decoderChannel.readInbound(as: MuxSDU.self)
        #expect(decoded?.timestamp == original.timestamp)
        #expect(decoded?.protocolID == original.protocolID)
        #expect(decoded?.payloadLength == original.payloadLength)
        #expect(decoded?.isResponder == original.isResponder)
        #expect(decoded?.miniProtocolID == original.miniProtocolID)
    }
}

// MARK: - DemuxHandler

@Suite("DemuxHandler") @MainActor struct DemuxHandlerTests {
    private let alloc = ByteBufferAllocator()
    private let logger = Logger(label: "test.demux")

    private func makeSDU(protocolID: UInt16, byte: UInt8) -> MuxSDU {
        var payload = alloc.buffer(capacity: 1)
        payload.writeBytes([byte])
        return MuxSDU(timestamp: 0, protocolID: protocolID, payload: payload)
    }

    /// Sets up EmbeddedChannel with full decode + demux pipeline and returns the
    /// (channel, demux) pair. Callers must register streams *before* calling this.
    private func makeFullPipeline(demux: DemuxHandler) throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(MuxFrameDecoder(maxPayloadSize: 65_535, logger: logger)),
            demux,
        ])
        return ch
    }

    /// Write a raw SDU frame into the channel's inbound side.
    private func writeRawFrame(protocolID: UInt16, payload: [UInt8], into ch: EmbeddedChannel)
        throws
    {
        var buf = alloc.buffer(capacity: 8 + payload.count)
        buf.writeInteger(UInt32(0), endianness: .big)
        buf.writeInteger(protocolID, endianness: .big)
        buf.writeInteger(UInt16(payload.count), endianness: .big)
        buf.writeBytes(payload)
        try ch.writeInbound(buf)
    }

    @Test func routesSDUToRegisteredStream() async throws {
        let demux = DemuxHandler(logger: logger)
        let stream2 = demux.register(protocolID: 2)
        let ch = try makeFullPipeline(demux: demux)
        defer { _ = try? ch.finish() }

        try writeRawFrame(protocolID: 2, payload: [0xAA], into: ch)

        var iter = stream2.makeAsyncIterator()
        let sdu = await iter.next()
        #expect(sdu?.miniProtocolID == 2)
    }

    @Test func routesDifferentProtocolsIndependently() async throws {
        let demux = DemuxHandler(logger: logger)
        let stream2 = demux.register(protocolID: 2)
        let stream7 = demux.register(protocolID: 7)
        let ch = try makeFullPipeline(demux: demux)
        defer { _ = try? ch.finish() }

        try writeRawFrame(protocolID: 7, payload: [0xBB], into: ch)
        try writeRawFrame(protocolID: 2, payload: [0xAA], into: ch)

        var iter2 = stream2.makeAsyncIterator()
        var iter7 = stream7.makeAsyncIterator()

        let fromStream7 = await iter7.next()
        let fromStream2 = await iter2.next()

        #expect(fromStream7?.miniProtocolID == 7)
        #expect(fromStream2?.miniProtocolID == 2)
    }

    @Test func channelInactiveFinishesAllStreams() async throws {
        let demux = DemuxHandler(logger: logger)
        let stream = demux.register(protocolID: 3)
        let ch = try makeFullPipeline(demux: demux)

        ch.pipeline.fireChannelInactive()

        // Stream should be finished; next() returns nil.
        var iter = stream.makeAsyncIterator()
        let result = await iter.next()
        #expect(result == nil)

        _ = try? ch.finish()
    }

    @Test func unknownProtocolDoesNotCrash() throws {
        let demux = DemuxHandler(logger: logger)
        // Register only protocol 2; write an SDU for protocol 9.
        _ = demux.register(protocolID: 2)
        let ch = try makeFullPipeline(demux: demux)
        defer { _ = try? ch.finish() }

        // Should not throw or crash; just logs a warning.
        try writeRawFrame(protocolID: 9, payload: [0xFF], into: ch)
    }

    @Test func multipleSDUsForSameProtocol() async throws {
        let demux = DemuxHandler(logger: logger)
        let stream = demux.register(protocolID: 4)
        let ch = try makeFullPipeline(demux: demux)
        defer { _ = try? ch.finish() }

        try writeRawFrame(protocolID: 4, payload: [0x01], into: ch)
        try writeRawFrame(protocolID: 4, payload: [0x02], into: ch)
        try writeRawFrame(protocolID: 4, payload: [0x03], into: ch)

        var iter = stream.makeAsyncIterator()
        let a = await iter.next()
        let b = await iter.next()
        let c = await iter.next()
        #expect(a?.miniProtocolID == 4)
        #expect(b?.miniProtocolID == 4)
        #expect(c?.miniProtocolID == 4)
    }
}
