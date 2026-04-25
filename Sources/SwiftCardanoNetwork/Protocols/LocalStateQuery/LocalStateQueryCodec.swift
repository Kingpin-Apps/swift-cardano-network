import NIOCore

/// CBOR codec for the LocalStateQuery mini-protocol (NtC, protocol ID 7).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgAcquire            = [0, point]         ; acquire at specific chain point
/// msgAcquired           = [1]
/// msgFailure            = [2, acquireFailure] ; 0=PointTooOld  1=PointNotOnChain
/// msgQuery              = [3, [era, bstr]]    ; era-tagged query payload
/// msgResult             = [4, [era, bstr]]    ; era-tagged result payload
/// msgRelease            = [5]
/// msgReAcquire          = [6, point]          ; re-acquire at a different point
/// msgDone               = [7]
/// msgAcquireVolatileTip = [8]                 ; acquire at current volatile tip
///
/// point = []                                  ; origin
///       / [slotNo, headerHash]                ; specific block
/// ```
///
/// The query payload uses the Ouroboros BlockQuery/ShelleyQuery nesting:
/// `[3, [0, [0, [era, <inline inner-query CBOR>]]]]` where the outer 0 is
/// QueryTypeBlock and the inner 0 is QueryTypeShelley.
/// The result payload is wrapped in a QueryIfCurrent success array:
/// `[4, [[<raw result CBOR>]]]`.
public struct LocalStateQueryCodec: ProtocolCodec, Sendable {
    public typealias Message = LocalStateQueryMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: LocalStateQueryMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .acquire(let point):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            writePoint(point, into: &buf)

        case .acquired:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(1, into: &buf)

        case .failure(let f):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            CBORLite.writeUInt(f.rawValue, into: &buf)

        case .query(let q):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(3, into: &buf)
            writeBlockShelleyQuery(era: UInt64(q.era), payload: q.rawCBOR, into: &buf)

        case .result(let r):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(4, into: &buf)
            writeQueryIfCurrentResult(payload: r.rawCBOR, into: &buf)

        case .release:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(5, into: &buf)

        case .reAcquire(let point):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(6, into: &buf)
            writePoint(point, into: &buf)

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(7, into: &buf)

        case .acquireVolatileTip:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(8, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> LocalStateQueryMessage {
        var buf = buffer
        defer { buffer = buf }
        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        let tag = try CBORLite.readUInt(from: &buf)

        switch tag {
        case 0:
            guard arrayLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            let point = try readPoint(from: &buf)
            return .acquire(point)

        case 1:
            guard arrayLen == 1 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            return .acquired

        case 2:
            guard arrayLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            let code = try CBORLite.readUInt(from: &buf)
            guard let f = AcquireFailure(rawValue: code) else {
                throw LocalStateQueryError.unknownAcquireFailure(code)
            }
            return .failure(f)

        case 3:
            guard arrayLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            let (era, bytes) = try readBlockShelleyQuery(from: &buf)
            return .query(RawQuery(era: era, rawCBOR: bytes))

        case 4:
            guard arrayLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            let bytes = try readQueryIfCurrentResult(from: &buf)
            return .result(RawResult(era: 0, rawCBOR: bytes))

        case 5:
            guard arrayLen == 1 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            return .release

        case 6:
            guard arrayLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            let point = try readPoint(from: &buf)
            return .reAcquire(point)

        case 7:
            guard arrayLen == 1 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            return .done

        case 8:
            guard arrayLen == 1 else { throw LocalStateQueryError.unexpectedArrayLength(arrayLen) }
            return .acquireVolatileTip

        default:
            throw LocalStateQueryError.unknownMessageTag(tag)
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
            throw LocalStateQueryError.malformedPoint(arrayLength: count)
        }
    }

    /// Write `[0, [0, [era, <inline payload bytes>]]]` — the NtC Ouroboros
    /// BlockQuery (0) → ShelleyQuery (0) → era nesting for ledger queries.
    /// The payload bytes are written inline (not wrapped as a CBOR byte string).
    private func writeBlockShelleyQuery(
        era: UInt64, payload: ByteBuffer, into buf: inout ByteBuffer
    ) {
        CBORLite.writeArrayHeader(count: 2, into: &buf)  // BlockQuery
        CBORLite.writeUInt(0, into: &buf)
        CBORLite.writeArrayHeader(count: 2, into: &buf)  // ShelleyQuery
        CBORLite.writeUInt(0, into: &buf)
        CBORLite.writeArrayHeader(count: 2, into: &buf)  // [era, inner]
        CBORLite.writeUInt(era, into: &buf)
        var src = payload
        buf.writeBuffer(&src)
    }

    /// Write the QueryIfCurrent success envelope `[[payload_inline]]`.
    /// Symmetric with `readQueryIfCurrentResult`.
    private func writeQueryIfCurrentResult(payload: ByteBuffer, into buf: inout ByteBuffer) {
        CBORLite.writeArrayHeader(count: 1, into: &buf)
        var src = payload
        buf.writeBuffer(&src)
    }

    /// Unwrap the QueryIfCurrent success envelope `[[<inner value>]]` returned
    /// by the node for era-tagged queries, and return the inner value bytes.
    private func readQueryIfCurrentResult(from buf: inout ByteBuffer) throws -> ByteBuffer {
        let outerLen = try CBORLite.readArrayHeader(from: &buf)
        guard outerLen == 1 else { throw LocalStateQueryError.unexpectedArrayLength(outerLen) }
        return try CBORLite.readValueBuffer(from: &buf)
    }

    /// Decode an inbound `[0, [0, [era, <inner bytes>]]]` BlockQuery/ShelleyQuery
    /// wrapper (symmetric counterpart of `writeBlockShelleyQuery`).
    private func readBlockShelleyQuery(from buf: inout ByteBuffer) throws -> (UInt16, ByteBuffer) {
        let blockLen = try CBORLite.readArrayHeader(from: &buf)
        guard blockLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(blockLen) }
        _ = try CBORLite.readUInt(from: &buf)  // BlockQuery type (0)
        let shelleyLen = try CBORLite.readArrayHeader(from: &buf)
        guard shelleyLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(shelleyLen) }
        _ = try CBORLite.readUInt(from: &buf)  // ShelleyQuery type (0)
        let innerLen = try CBORLite.readArrayHeader(from: &buf)
        guard innerLen == 2 else { throw LocalStateQueryError.unexpectedArrayLength(innerLen) }
        let era = UInt16(try CBORLite.readUInt(from: &buf))
        let bytes = try CBORLite.readValueBuffer(from: &buf)
        return (era, bytes)
    }
}
