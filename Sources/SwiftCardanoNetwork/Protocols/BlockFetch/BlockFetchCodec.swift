import NIOCore

/// CBOR codec for the BlockFetch mini-protocol (NtN, protocol ID 3).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgRequestRange = [0, point, point]
/// msgClientDone   = [1]
/// msgStartBatch   = [2]
/// msgNoBlocks     = [3]
/// msgBlock        = [4, #6.24(bstr)]   ; Shelley+: tag 24 wrapping raw block CBOR
///                 / [4, bstr]          ; Byron / fallback: raw bytes
/// msgBatchDone    = [5]
///
/// point = []                  ; origin
///       / [slotNo, headerHash]
/// ```
public struct BlockFetchCodec: ProtocolCodec, Sendable {
    public typealias Message = BlockFetchMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: BlockFetchMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .requestRange(let from, let to):
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            writePoint(from, into: &buf)
            writePoint(to, into: &buf)

        case .clientDone:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(1, into: &buf)

        case .startBatch:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(2, into: &buf)

        case .noBlocks:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(3, into: &buf)

        case .block(let body):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(4, into: &buf)
            // Encode as tag 24 (embedded CBOR)
            CBORLite.writeTag(24, into: &buf)
            CBORLite.writeByteBuffer(body, into: &buf)

        case .batchDone:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(5, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> BlockFetchMessage {
        let arrayLen = try CBORLite.readArrayHeader(from: &buffer)
        let tag = try CBORLite.readUInt(from: &buffer)

        switch tag {
        case 0:
            guard arrayLen == 3 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            let from = try readPoint(from: &buffer)
            let to = try readPoint(from: &buffer)
            return .requestRange(from: from, to: to)

        case 1:
            guard arrayLen == 1 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            return .clientDone

        case 2:
            guard arrayLen == 1 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            return .startBatch

        case 3:
            guard arrayLen == 1 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            return .noBlocks

        case 4:
            guard arrayLen == 2 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            let body = try readBlockBody(from: &buffer)
            return .block(body)

        case 5:
            guard arrayLen == 1 else { throw BlockFetchError.unexpectedArrayLength(arrayLen) }
            return .batchDone

        default:
            throw BlockFetchError.unknownMessageTag(tag)
        }
    }

    // MARK: - Private helpers

    private func writePoint(_ point: Point, into buf: inout ByteBuffer) {
        switch point {
        case .origin:
            CBORLite.writeArrayHeader(count: 0, into: &buf)
        case .blockPoint(let slot, let hash):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(slot, into: &buf)
            CBORLite.writeByteString(hash, into: &buf)
        }
    }

    private func readPoint(from buf: inout ByteBuffer) throws -> Point {
        let count = try CBORLite.readArrayHeader(from: &buf)
        switch count {
        case 0:
            return .origin
        case 2:
            let slot = try CBORLite.readUInt(from: &buf)
            let hash = try CBORLite.readByteString(from: &buf)
            return .blockPoint(slot: slot, hash: hash)
        default:
            throw BlockFetchError.malformedPoint(arrayLength: count)
        }
    }

    /// Decode the block body from a `msgBlock` payload: either `#6.24(bstr)` (tag 24)
    /// or a plain byte string (Byron / fallback).
    private func readBlockBody(from buf: inout ByteBuffer) throws -> ByteBuffer {
        if let major = CBORLite.peekMajorType(from: buf), major == CBORLite.majorTag {
            let tagNum = try CBORLite.readTag(from: &buf)
            if tagNum == 24 {
                return try CBORLite.readByteStringBuffer(from: &buf)
            }
            // Unknown tag: skip it and treat remaining bytes as the body.
            try CBORLite.skipValue(in: &buf)
            let rest = buf
            buf.moveReaderIndex(forwardBy: buf.readableBytes)
            return rest
        }
        // Plain byte string (Byron / no tag).
        return try CBORLite.readByteStringBuffer(from: &buf)
    }
}
