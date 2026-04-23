import NIOCore

/// CBOR codec for the KeepAlive mini-protocol (NtN, protocol ID 8).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgKeepAlive         = [0, cookie]   ; cookie: uint16
/// msgKeepAliveResponse = [1, cookie]
/// msgDone              = [2]
/// ```
public struct KeepAliveCodec: ProtocolCodec, Sendable {
    public typealias Message = KeepAliveMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: KeepAliveMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 8)

        switch message {
        case .keepAlive(let cookie):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            CBORLite.writeUInt(UInt64(cookie), into: &buf)

        case .keepAliveResponse(let cookie):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(1, into: &buf)
            CBORLite.writeUInt(UInt64(cookie), into: &buf)

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> KeepAliveMessage {
        let arrayLen = try CBORLite.readArrayHeader(from: &buffer)
        let tag = try CBORLite.readUInt(from: &buffer)

        switch tag {
        case 0:
            guard arrayLen == 2 else { throw KeepAliveError.unexpectedArrayLength(arrayLen) }
            let cookie = UInt16(try CBORLite.readUInt(from: &buffer))
            return .keepAlive(cookie: cookie)

        case 1:
            guard arrayLen == 2 else { throw KeepAliveError.unexpectedArrayLength(arrayLen) }
            let cookie = UInt16(try CBORLite.readUInt(from: &buffer))
            return .keepAliveResponse(cookie: cookie)

        case 2:
            guard arrayLen == 1 else { throw KeepAliveError.unexpectedArrayLength(arrayLen) }
            return .done

        default:
            throw KeepAliveError.unknownMessageTag(tag)
        }
    }
}
