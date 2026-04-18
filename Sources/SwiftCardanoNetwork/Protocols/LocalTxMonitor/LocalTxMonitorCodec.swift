import NIOCore

/// CBOR codec for the LocalTxMonitor mini-protocol (NtC, protocol ID 9).
///
/// ## Wire format (spec §3.14.5)
///
/// ```
/// msgDone             = [0]
/// msgAcquire          = [1]          ; also encodes awaitAcquire
/// msgAcquired         = [2, slotNo]
/// msgRelease          = [3]
///                                    ; tag 4 is unused
/// msgNextTx           = [5]
/// msgReplyNextTx      = [6]          ; no tx (snapshot exhausted)
///                     / [6, bstr]    ; raw tx CBOR bytes
/// msgHasTx            = [7, bstr]   ; 32-byte txId
/// msgReplyHasTx       = [8, bool]
/// msgGetSizes         = [9]
/// msgReplyGetSizes    = [10, [uint, uint, uint]]   ; nested array
/// msgGetMeasures      = [11]
/// msgReplyGetMeasures = [12, uint, {* text => [integer, integer]}]
/// ```
public struct LocalTxMonitorCodec: ProtocolCodec, Sendable {
    public typealias Message = LocalTxMonitorMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: LocalTxMonitorMessage, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 32)

        switch message {
        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(0, into: &buf)

        case .acquire, .awaitAcquire:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(1, into: &buf)

        case .acquired(let slotNo):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            CBORLite.writeUInt(slotNo, into: &buf)

        case .release:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(3, into: &buf)

        case .nextTx:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(5, into: &buf)

        case .replyNextTx(let tx):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(6, into: &buf)
            if let tx = tx {
                CBORLite.writeByteBuffer(tx.rawCBOR, into: &buf)
            } else {
                CBORLite.writeNull(into: &buf)
            }

        case .hasTx(let txId):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(7, into: &buf)
            CBORLite.writeByteString(txId, into: &buf)

        case .replyHasTx(let present):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(8, into: &buf)
            CBORLite.writeBool(present, into: &buf)

        case .getSizes:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(9, into: &buf)

        case .replyGetSizes(let sizes):
            // [10, [capacityInBytes, sizeInBytes, numberOfTxs]]
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(10, into: &buf)
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(sizes.capacityInBytes, into: &buf)
            CBORLite.writeUInt(sizes.sizeInBytes, into: &buf)
            CBORLite.writeUInt(sizes.numberOfTxs, into: &buf)

        case .getMeasures:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(11, into: &buf)

        case .replyGetMeasures(let totalTxs, let measures):
            // [12, totalTxs, {* text => [integer, integer]}]
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(12, into: &buf)
            CBORLite.writeUInt(UInt64(totalTxs), into: &buf)
            CBORLite.writeMapHeader(count: measures.count, into: &buf)
            for m in measures {
                CBORLite.writeText(m.key, into: &buf)
                CBORLite.writeArrayHeader(count: 2, into: &buf)
                CBORLite.writeUInt(UInt64(bitPattern: m.current), into: &buf)
                CBORLite.writeUInt(UInt64(bitPattern: m.capacity), into: &buf)
            }
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: ByteBuffer) throws -> LocalTxMonitorMessage {
        var buf = buffer
        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        let tag      = try CBORLite.readUInt(from: &buf)

        switch tag {
        case 0:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .done

        case 1:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .acquire

        case 2:
            guard arrayLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            let slotNo = try CBORLite.readUInt(from: &buf)
            return .acquired(slotNo: slotNo)

        case 3:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .release

        case 5:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .nextTx

        case 6:
            guard arrayLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            if CBORLite.peekIsNull(buf) {
                try CBORLite.readNull(from: &buf)
                return .replyNextTx(nil)
            } else {
                let txBuf = try CBORLite.readByteStringBuffer(from: &buf)
                return .replyNextTx(MempoolTx(rawCBOR: txBuf))
            }

        case 7:
            guard arrayLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            let txId = try CBORLite.readByteString(from: &buf)
            return .hasTx(txId)

        case 8:
            guard arrayLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            let present = try CBORLite.readBool(from: &buf)
            return .replyHasTx(present)

        case 9:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .getSizes

        case 10:
            // [10, [capacityInBytes, sizeInBytes, numberOfTxs]]
            guard arrayLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            let innerLen = try CBORLite.readArrayHeader(from: &buf)
            guard innerLen == 3 else { throw LocalTxMonitorError.unexpectedArrayLength(innerLen) }
            let capacity = try CBORLite.readUInt(from: &buf)
            let size     = try CBORLite.readUInt(from: &buf)
            let count    = try CBORLite.readUInt(from: &buf)
            return .replyGetSizes(MempoolCapacity(
                capacityInBytes: capacity,
                sizeInBytes: size,
                numberOfTxs: count
            ))

        case 11:
            guard arrayLen == 1 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            return .getMeasures

        case 12:
            // [12, totalTxs, {* text => [integer, integer]}]
            guard arrayLen == 3 else { throw LocalTxMonitorError.unexpectedArrayLength(arrayLen) }
            let totalTxs = UInt32(try CBORLite.readUInt(from: &buf))
            let mapLen   = try CBORLite.readMapHeader(from: &buf)
            var measures: [(key: String, current: Int64, capacity: Int64)] = []
            for _ in 0..<mapLen {
                let key     = try CBORLite.readText(from: &buf)
                let pairLen = try CBORLite.readArrayHeader(from: &buf)
                guard pairLen == 2 else { throw LocalTxMonitorError.unexpectedArrayLength(pairLen) }
                let current  = try CBORLite.readInt64(from: &buf)
                let capacity = try CBORLite.readInt64(from: &buf)
                measures.append((key: key, current: current, capacity: capacity))
            }
            return .replyGetMeasures(totalTxs: totalTxs, measures: measures)

        default:
            throw LocalTxMonitorError.unknownMessageTag(tag)
        }
    }
}
