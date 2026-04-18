import NIOCore
import NIOExtras
import Metrics

/// Encodes `MuxSDU` values into the 8-byte-header wire format.
public struct MuxFrameEncoder: MessageToByteEncoder, Sendable {
    public typealias OutboundIn = MuxSDU

    public init() {}

    public func encode(data sdu: MuxSDU, out: inout ByteBuffer) throws {
        out.writeInteger(sdu.timestamp,     endianness: .big)
        out.writeInteger(sdu.protocolID,    endianness: .big)
        out.writeInteger(sdu.payloadLength, endianness: .big)
        var payload = sdu.payload
        out.writeBuffer(&payload)

        CardanoMetrics
            .counter(CardanoMetrics.bytesSentTotal)
            .increment(by: Int(8 + sdu.payloadLength))
    }
}
