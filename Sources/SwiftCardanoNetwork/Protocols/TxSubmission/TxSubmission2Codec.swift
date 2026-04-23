import NIOCore

/// CBOR codec for the TxSubmission2 mini-protocol (NtN, protocol ID 4).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgRequestTxIds = [0, bool, uint16, uint16]   ; blocking, ackCount, reqCount
/// msgReplyTxIds   = [1, [[bstr, uint]]]          ; [(txId, byteSize)]
/// msgRequestTxs   = [2, [bstr]]                  ; [txId]
/// msgReplyTxs     = [3, [bstr]]                  ; [rawTx CBOR]
/// msgDone         = [4]
/// ```
public struct TxSubmission2Codec: ProtocolCodec, Sendable {
    public typealias Message = TxSubmission2Message

    public init() {}

    // MARK: - Encode

    public func encode(_ message: TxSubmission2Message, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .requestTxIds(let blocking, let ackCount, let reqCount):
            CBORLite.writeArrayHeader(count: 4, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            CBORLite.writeBool(blocking, into: &buf)
            CBORLite.writeUInt(UInt64(ackCount), into: &buf)
            CBORLite.writeUInt(UInt64(reqCount), into: &buf)

        case .replyTxIds(let entries):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(1, into: &buf)
            CBORLite.writeArrayHeader(count: entries.count, into: &buf)
            for entry in entries {
                CBORLite.writeArrayHeader(count: 2, into: &buf)
                CBORLite.writeByteString(entry.id, into: &buf)
                CBORLite.writeUInt(UInt64(entry.size), into: &buf)
            }

        case .requestTxs(let ids):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            CBORLite.writeArrayHeader(count: ids.count, into: &buf)
            for id in ids {
                CBORLite.writeByteString(id, into: &buf)
            }

        case .replyTxs(let txs):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(3, into: &buf)
            CBORLite.writeArrayHeader(count: txs.count, into: &buf)
            for tx in txs {
                CBORLite.writeByteBuffer(tx, into: &buf)
            }

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(4, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> TxSubmission2Message {
        var buf = buffer
        defer { buffer = buf }
        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        let tag      = try CBORLite.readUInt(from: &buf)

        switch tag {
        case 0:
            guard arrayLen == 4 else { throw TxSubmission2Error.unexpectedArrayLength(arrayLen) }
            let blocking  = try CBORLite.readBool(from: &buf)
            let ackCount  = UInt16(try CBORLite.readUInt(from: &buf))
            let reqCount  = UInt16(try CBORLite.readUInt(from: &buf))
            return .requestTxIds(blocking: blocking, ackCount: ackCount, reqCount: reqCount)

        case 1:
            guard arrayLen == 2 else { throw TxSubmission2Error.unexpectedArrayLength(arrayLen) }
            let count = try CBORLite.readArrayHeader(from: &buf)
            var entries = [TxIdWithSize]()
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let entryLen = try CBORLite.readArrayHeader(from: &buf)
                guard entryLen == 2 else {
                    throw TxSubmission2Error.malformedTxIdEntry(arrayLength: entryLen)
                }
                let id   = try CBORLite.readByteString(from: &buf)
                let size = UInt32(try CBORLite.readUInt(from: &buf))
                entries.append(TxIdWithSize(id: id, size: size))
            }
            return .replyTxIds(entries)

        case 2:
            guard arrayLen == 2 else { throw TxSubmission2Error.unexpectedArrayLength(arrayLen) }
            let count = try CBORLite.readArrayHeader(from: &buf)
            var ids = [TxId]()
            ids.reserveCapacity(count)
            for _ in 0..<count {
                ids.append(try CBORLite.readByteString(from: &buf))
            }
            return .requestTxs(ids)

        case 3:
            guard arrayLen == 2 else { throw TxSubmission2Error.unexpectedArrayLength(arrayLen) }
            let count = try CBORLite.readArrayHeader(from: &buf)
            var txs = [ByteBuffer]()
            txs.reserveCapacity(count)
            for _ in 0..<count {
                txs.append(try CBORLite.readByteStringBuffer(from: &buf))
            }
            return .replyTxs(txs)

        case 4:
            guard arrayLen == 1 else { throw TxSubmission2Error.unexpectedArrayLength(arrayLen) }
            return .done

        default:
            throw TxSubmission2Error.unknownMessageTag(tag)
        }
    }
}
