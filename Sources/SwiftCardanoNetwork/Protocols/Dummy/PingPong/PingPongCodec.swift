import NIOCore

/// CBOR codec for the Ping-Pong mini-protocol (dummy protocol, §3.5.1).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgDone = [0]
/// msgPing = [1]
/// msgPong = [2]
/// ```
///
/// The spec does not publish an official CDDL for the dummy protocols;
/// this encoding matches the reference Haskell `typed-protocols`
/// implementation and is consistent with the other mini-protocols in
/// this package.
public struct PingPongCodec: ProtocolCodec, Sendable {
    public typealias Message = PingPongMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: PingPongMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 1, into: &buf)

        switch message {
        case .done: CBORLite.writeUInt(0, into: &buf)
        case .ping: CBORLite.writeUInt(1, into: &buf)
        case .pong: CBORLite.writeUInt(2, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> PingPongMessage {
        let arrayLen = try CBORLite.readArrayHeader(from: &buffer)
        guard arrayLen == 1 else {
            throw PingPongError.unexpectedArrayLength(arrayLen)
        }
        let tag = try CBORLite.readUInt(from: &buffer)

        switch tag {
        case 0: return .done
        case 1: return .ping
        case 2: return .pong
        default: throw PingPongError.unknownMessageTag(tag)
        }
    }
}
