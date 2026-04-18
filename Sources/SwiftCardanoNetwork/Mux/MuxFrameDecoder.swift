import NIOCore
import NIOExtras
import Logging
import Metrics

/// Decodes a raw byte stream into `MuxSDU` values.
///
/// Each SDU has an 8-byte header followed by a variable-length payload.
/// Incomplete headers or payloads cause the decoder to request more data.
public struct MuxFrameDecoder: ByteToMessageDecoder, @unchecked Sendable {
    public typealias InboundOut = MuxSDU

    private let logger: Logger
    private let maxPayloadSize: Int

    public init(maxPayloadSize: Int, logger: Logger) {
        self.maxPayloadSize = maxPayloadSize
        self.logger = logger
    }

    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 8 else { return .needMoreData }

        // Peek header without consuming so we can check payload availability first.
        guard
            let timestamp     = buffer.getInteger(at: buffer.readerIndex,     as: UInt32.self),
            let protocolField = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt16.self),
            let payloadLength = buffer.getInteger(at: buffer.readerIndex + 6, as: UInt16.self)
        else { return .needMoreData }

        let length = Int(payloadLength)
        if length > maxPayloadSize {
            let protoID = protocolField & 0x7FFF
            logger.error(
                "SDU payload exceeds maximum allowed size",
                metadata: [
                    "protocolID": "\(protoID)",
                    "length": "\(length)",
                    "maxAllowed": "\(maxPayloadSize)"
                ]
            )
            CardanoMetrics.counter(CardanoMetrics.sduDecodeErrorsTotal).increment()
            throw MuxError.payloadTooLarge(protocolID: protoID, length: length, max: maxPayloadSize)
        }

        guard buffer.readableBytes >= 8 + length else { return .needMoreData }

        // Consume the header.
        buffer.moveReaderIndex(forwardBy: 8)

        let payload = buffer.readSlice(length: length) ?? ByteBuffer()

        logger.debug("Decoded SDU frame", metadata: [
            "protocolID": "\(protocolField & 0x7FFF)",
            "payloadLength": "\(length)",
            "responder": "\((protocolField & 0x8000) != 0 ? "true" : "false")"
        ])

        let sdu = MuxSDU(timestamp: timestamp, protocolID: protocolField, payload: payload)
        context.fireChannelRead(wrapInboundOut(sdu))
        return .continue
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}
