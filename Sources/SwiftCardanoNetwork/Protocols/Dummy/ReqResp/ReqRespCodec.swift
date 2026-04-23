import NIOCore

/// Generic CBOR codec for the Request-Response mini-protocol
/// (dummy protocol, §3.5.2).
///
/// The protocol is polymorphic in its request and response payload types.
/// Callers supply encode/decode closures that serialise the payloads into
/// CBOR. The codec handles the `[tag, payload]` framing.
///
/// ## Wire format
///
/// ```
/// msgDone     = [0]
/// msgRequest  = [1, request]
/// msgResponse = [2, response]
/// ```
///
/// ## Usage
///
/// ```swift
/// // Raw bytes in both directions (payload is a CBOR byte string):
/// let codec = ReqRespCodec<ByteBuffer, ByteBuffer>.raw()
///
/// // Or custom payloads:
/// let codec = ReqRespCodec<String, Int>(
///     encodeRequest:  { val, buf in CBORLite.writeText(val, into: &buf) },
///     decodeRequest:  { buf in try CBORLite.readText(from: &buf) },
///     encodeResponse: { val, buf in CBORLite.writeUInt(UInt64(val), into: &buf) },
///     decodeResponse: { buf in Int(try CBORLite.readUInt(from: &buf)) }
/// )
/// ```
public struct ReqRespCodec<Request: Sendable, Response: Sendable>: ProtocolCodec, Sendable {
    public typealias Message = ReqRespMessage<Request, Response>

    /// Serialise a request payload into the provided buffer.
    public let encodeRequest: @Sendable (Request, inout ByteBuffer) throws -> Void
    /// Deserialise a request payload from the provided buffer.
    public let decodeRequest: @Sendable (inout ByteBuffer) throws -> Request
    /// Serialise a response payload into the provided buffer.
    public let encodeResponse: @Sendable (Response, inout ByteBuffer) throws -> Void
    /// Deserialise a response payload from the provided buffer.
    public let decodeResponse: @Sendable (inout ByteBuffer) throws -> Response

    public init(
        encodeRequest: @escaping @Sendable (Request, inout ByteBuffer) throws -> Void,
        decodeRequest: @escaping @Sendable (inout ByteBuffer) throws -> Request,
        encodeResponse: @escaping @Sendable (Response, inout ByteBuffer) throws -> Void,
        decodeResponse: @escaping @Sendable (inout ByteBuffer) throws -> Response
    ) {
        self.encodeRequest = encodeRequest
        self.decodeRequest = decodeRequest
        self.encodeResponse = encodeResponse
        self.decodeResponse = decodeResponse
    }

    // MARK: - Encode

    public func encode(
        _ message: ReqRespMessage<Request, Response>,
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 16)

        switch message {
        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(0, into: &buf)

        case .request(let req):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(1, into: &buf)
            try encodeRequest(req, &buf)

        case .response(let resp):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            try encodeResponse(resp, &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> ReqRespMessage<Request, Response> {
        var buf = buffer
        defer { buffer = buf }
        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        let tag = try CBORLite.readUInt(from: &buf)

        switch tag {
        case 0:
            guard arrayLen == 1 else { throw ReqRespError.unexpectedArrayLength(arrayLen) }
            return .done

        case 1:
            guard arrayLen == 2 else { throw ReqRespError.unexpectedArrayLength(arrayLen) }
            let req = try decodeRequest(&buf)
            return .request(req)

        case 2:
            guard arrayLen == 2 else { throw ReqRespError.unexpectedArrayLength(arrayLen) }
            let resp = try decodeResponse(&buf)
            return .response(resp)

        default:
            throw ReqRespError.unknownMessageTag(tag)
        }
    }
}

// MARK: - Raw ByteBuffer convenience

extension ReqRespCodec where Request == ByteBuffer, Response == ByteBuffer {

    /// A codec pre-configured to ship raw request/response payloads as CBOR
    /// byte strings. Suitable for demos and tests that do not care about the
    /// payload schema.
    public static func raw() -> ReqRespCodec<ByteBuffer, ByteBuffer> {
        ReqRespCodec<ByteBuffer, ByteBuffer>(
            encodeRequest:  { value, buf in CBORLite.writeByteBuffer(value, into: &buf) },
            decodeRequest:  { buf in try CBORLite.readByteStringBuffer(from: &buf) },
            encodeResponse: { value, buf in CBORLite.writeByteBuffer(value, into: &buf) },
            decodeResponse: { buf in try CBORLite.readByteStringBuffer(from: &buf) }
        )
    }
}
