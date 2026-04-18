import NIOCore

/// A `ProtocolCodec` knows how to CBOR-encode and decode the messages for one
/// mini-protocol. The `Message` type fully describes one side of the wire.
///
/// Implementors produce and consume raw `ByteBuffer` payloads that are carried
/// inside `MuxSDU.payload`. The framing (SDU header) is handled by the mux layer.
public protocol ProtocolCodec: Sendable {
    associatedtype Message: Sendable

    /// Encode `message` into a `ByteBuffer` suitable for use as a SDU payload.
    func encode(_ message: Message, allocator: ByteBufferAllocator) throws -> ByteBuffer

    /// Decode a `Message` from the SDU payload `buffer`.
    func decode(_ buffer: ByteBuffer) throws -> Message
}
