import NIOCore

/// CBOR codec for the ChainSync mini-protocol.
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgRequestNext       = [0]
/// msgAwaitReply        = [1]
/// msgRollForward       = [2, wrappedBlock, tip]
/// msgRollBackward      = [3, point, tip]
/// msgFindIntersect     = [4, [*point]]
/// msgIntersectFound    = [5, point, tip]
/// msgIntersectNotFound = [6, tip]
/// msgDone              = [7]
///
/// ; NtC (node-to-client): full blocks wrapped in an outer tag-24
/// wrappedBlock = #6.24(bstr)             ; bstr = CBOR of [era, #6.24(block_bytes)]
///
/// ; NtN (node-to-node): headers as a plain era-prefixed array
/// wrappedBlock = [era, encodedHeader]    ; era: 0=Byron … 6=Conway
/// encodedHeader = #6.24(bytes)           ; CBOR tag 24 — embedded CBOR (Shelley+)
///               / bytes                  ; raw CBOR (Byron, fallback)
///
/// tip   = [point, blockNo]
/// point = []                             ; origin
///       / [slotNo, headerHash]
/// ```
public struct ChainSyncCodec: ProtocolCodec, Sendable {
    public typealias Message = ChainSyncMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: ChainSyncMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .requestNext:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(0, into: &buf)

        case .findIntersect(let points):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(4, into: &buf)
            CBORLite.writeArrayHeader(count: points.count, into: &buf)
            for p in points { writePoint(p, into: &buf) }

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(7, into: &buf)

        case .awaitReply, .rollForward, .rollBackward, .intersectFound, .intersectNotFound:
            // Server-to-client messages; encoding them is unusual but supported for testing.
            try encodeServerMessage(message, into: &buf, allocator: allocator)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> ChainSyncMessage {
        let arrayLen = try CBORLite.readArrayHeader(from: &buffer)
        let tag = try CBORLite.readUInt(from: &buffer)

        switch tag {
        case 0:
            guard arrayLen == 1 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            return .requestNext

        case 1:
            guard arrayLen == 1 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            return .awaitReply

        case 2:
            guard arrayLen == 3 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            let block = try readWrappedBlock(from: &buffer)
            let tip = try readTip(from: &buffer)
            return .rollForward(block, tip)

        case 3:
            guard arrayLen == 3 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            let point = try readPoint(from: &buffer)
            let tip = try readTip(from: &buffer)
            return .rollBackward(point, tip)

        case 4:
            let count = try CBORLite.readArrayHeader(from: &buffer)
            var points = [Point]()
            if count >= 0 {
                points.reserveCapacity(count)
                for _ in 0..<count { try points.append(readPoint(from: &buffer)) }
            } else {
                while !CBORLite.peekIsBreak(buffer) && buffer.readableBytes > 0 {
                    try points.append(readPoint(from: &buffer))
                }
                CBORLite.skipBreakIfPresent(from: &buffer)
            }
            return .findIntersect(points)

        case 5:
            guard arrayLen == 3 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            let point = try readPoint(from: &buffer)
            let tip = try readTip(from: &buffer)
            return .intersectFound(point, tip)

        case 6:
            guard arrayLen == 2 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            let tip = try readTip(from: &buffer)
            return .intersectNotFound(tip)

        case 7:
            guard arrayLen == 1 || arrayLen == -1 else {
                throw ChainSyncError.unexpectedArrayLength(Int(arrayLen))
            }
            return .done

        default:
            throw ChainSyncError.unknownMessageTag(tag)
        }
    }

    // MARK: - Private: encode helpers

    private func encodeServerMessage(
        _ message: ChainSyncMessage,
        into buf: inout ByteBuffer,
        allocator: ByteBufferAllocator
    ) throws {
        switch message {
        case .awaitReply:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(1, into: &buf)

        case .rollForward(let block, let tip):
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            writeWrappedBlock(block, into: &buf)
            writeTip(tip, into: &buf)

        case .rollBackward(let point, let tip):
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(3, into: &buf)
            writePoint(point, into: &buf)
            writeTip(tip, into: &buf)

        case .intersectFound(let point, let tip):
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(5, into: &buf)
            writePoint(point, into: &buf)
            writeTip(tip, into: &buf)

        case .intersectNotFound(let tip):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(6, into: &buf)
            writeTip(tip, into: &buf)

        default:
            break
        }
    }

    // MARK: - Private: primitive encode

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

    private func writeTip(_ tip: Tip, into buf: inout ByteBuffer) {
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        writePoint(tip.point, into: &buf)
        CBORLite.writeUInt(tip.blockNo, into: &buf)
    }

    private func writeWrappedBlock(_ block: RawBlock, into buf: inout ByteBuffer) {
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(block.era, into: &buf)
        // Encode body as CBOR tag 24 (embedded CBOR) for Shelley+; raw bytes for Byron.
        // Tag 24 semantics: tag(24) bstr(<raw-cbor-bytes>) — the byte string content
        // IS the raw CBOR; no additional CBOR encoding is applied to it.
        if block.era == 0 {
            CBORLite.writeByteBuffer(block.rawCBOR, into: &buf)
        } else {
            CBORLite.writeTag(24, into: &buf)
            CBORLite.writeByteBuffer(block.rawCBOR, into: &buf)
        }
    }

    // MARK: - Private: primitive decode

    private func readPoint(from buf: inout ByteBuffer) throws -> Point {
        let count = try CBORLite.readArrayHeader(from: &buf)
        switch count {
        case 0:
            return .origin
        case 2:
            let slot = try CBORLite.readUInt(from: &buf)
            let hash = try CBORLite.readByteString(from: &buf)
            return .blockPoint(slot: slot, hash: hash)
        case -1:
            // Indefinite-length: if next byte is break (0xFF) it's origin; otherwise blockPoint.
            if CBORLite.peekIsBreak(buf) {
                CBORLite.skipBreakIfPresent(from: &buf)
                return .origin
            }
            let slot = try CBORLite.readUInt(from: &buf)
            let hash = try CBORLite.readByteString(from: &buf)
            CBORLite.skipBreakIfPresent(from: &buf)
            return .blockPoint(slot: slot, hash: hash)
        default:
            throw ChainSyncError.malformedPoint(arrayLength: count)
        }
    }

    private func readTip(from buf: inout ByteBuffer) throws -> Tip {
        let count = try CBORLite.readArrayHeader(from: &buf)
        guard count == 2 || count == -1 else {
            throw ChainSyncError.malformedTip(arrayLength: count)
        }
        let point = try readPoint(from: &buf)
        let blockNo = try CBORLite.readUInt(from: &buf)
        CBORLite.skipBreakIfPresent(from: &buf)
        return Tip(point: point, blockNo: blockNo)
    }

    /// Decode the wrapped block from a `RollForward` message.
    ///
    /// Two outer formats are supported:
    ///
    /// - **NtC (node-to-client)** — the whole wrapped block is an outer tag-24:
    ///   `#6.24(bstr)` where `bstr` = CBOR of `[era, #6.24(block_bytes)]`.
    ///   The outer tag-24 is stripped first, then the inner array is parsed.
    ///
    /// - **NtN (node-to-node)** — the wrapped block is a plain 2-element array:
    ///   `[era, encodedHeader]` where `encodedHeader` may be a tag-24 byte
    ///   string, a raw byte string, or a directly-embedded CBOR value.
    private func readWrappedBlock(from buf: inout ByteBuffer) throws -> RawBlock {
        guard let outerMajor = CBORLite.peekMajorType(from: buf) else {
            throw CBORError.truncated
        }

        // NtC: outer tag-24 wraps the entire [era, encodedBlock] structure.
        if outerMajor == CBORLite.majorTag {
            let tagNum = try CBORLite.readTag(from: &buf)
            guard tagNum == 24 else {
                throw ChainSyncError.malformedBlock(arrayLength: Int(tagNum))
            }
            var innerBuf = try CBORLite.readByteStringBuffer(from: &buf)
            return try parseWrappedBlockArray(from: &innerBuf)
        }

        // NtN: plain [era, encodedHeader] array.
        return try parseWrappedBlockArray(from: &buf)
    }

    /// Parse `[era, encodedBlock]` and return a `RawBlock`.
    ///
    /// `encodedBlock` may be:
    /// - CBOR tag 24 wrapping a byte string (Shelley+ full blocks or headers)
    /// - a raw byte string (Byron / fallback)
    /// - a directly-embedded CBOR value (NtN headers without tag-24)
    private func parseWrappedBlockArray(from buf: inout ByteBuffer) throws -> RawBlock {
        let wrapCount = try CBORLite.readArrayHeader(from: &buf)
        guard wrapCount == 2 || wrapCount == -1 else {
            throw ChainSyncError.malformedBlock(arrayLength: wrapCount)
        }
        let era = try CBORLite.readUInt(from: &buf)

        let rawCBOR: ByteBuffer
        guard let majorType = CBORLite.peekMajorType(from: buf) else {
            throw CBORError.truncated
        }

        switch majorType {
        case CBORLite.majorTag:
            let tagNum = try CBORLite.readTag(from: &buf)
            if tagNum == 24 {
                // Tag 24 = embedded CBOR: the byte string content IS the raw CBOR bytes.
                rawCBOR = try CBORLite.readByteStringBuffer(from: &buf)
            } else {
                // Unknown tag — skip the tagged value and take remaining bytes.
                try CBORLite.skipValue(in: &buf)
                rawCBOR = buf
                buf.moveReaderIndex(forwardBy: buf.readableBytes)
            }
        case CBORLite.majorByteString:
            // Plain byte string (Byron or pre-tag-24 fallback).
            rawCBOR = try CBORLite.readByteStringBuffer(from: &buf)
        default:
            // Directly-embedded CBOR value — most commonly an NtN block header
            // sent as a plain array [header_body, kes_signature] without tag-24.
            // Capture the entire value as raw CBOR bytes.
            rawCBOR = try CBORLite.readValueBuffer(from: &buf)
        }

        // Consume break byte if the [era, block] array was indefinite-length.
        CBORLite.skipBreakIfPresent(from: &buf)
        return RawBlock(era: era, rawCBOR: rawCBOR)
    }
}

// MARK: - Errors

public enum ChainSyncError: Error, Sendable {
    case unknownMessageTag(UInt64)
    case unexpectedArrayLength(Int)
    case malformedPoint(arrayLength: Int)
    case malformedTip(arrayLength: Int)
    case malformedBlock(arrayLength: Int)
    case intersectionNotFound(Tip)
}
