import NIOCore
import SwiftCardanoCore

/// CBOR codec for the LocalTxSubmission mini-protocol (NtC, protocol ID 6).
///
/// ## Wire format (CDDL subset)
///
/// ```
/// msgSubmitTx = [0, [era, #6.24(bstr)]]   ; era-tagged tx, wrapped in CBOR tag 24
/// msgAcceptTx = [1]
/// msgRejectTx = [2, [era, #6.24(bstr)]]   ; era-tagged rejection reason, wrapped in tag 24
/// msgDone     = [3]
/// ```
///
/// The inner `[era, #6.24(bstr)]` pair mirrors the era-tagged block encoding
/// used in ChainSync: `era` is the Cardano era number (Byron=0 … Conway=6) and
/// the bstr holds the CBOR-encoded transaction body / rejection reason wrapped
/// in CBOR tag 24 ("encoded CBOR data item"). The decoder also accepts the
/// older untagged `[era, bstr]` form for backwards compatibility with
/// pre-Conway-hard-fork-combinator nodes.
public struct LocalTxSubmissionCodec: ProtocolCodec, Sendable {
    public typealias Message = LocalTxSubmissionMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: LocalTxSubmissionMessage, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .submitTx(let tx):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            writeEraTagged(era: UInt64(try tx.era.toWireTag()), payload: tx.rawCBOR, into: &buf)

        case .acceptTx:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(1, into: &buf)

        case .rejectTx(let rejection):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
            writeEraTagged(era: UInt64(try rejection.era.toWireTag()), payload: rejection.reasonCBOR, into: &buf)

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(3, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> LocalTxSubmissionMessage {
        var buf = buffer
        defer { buffer = buf }
        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        let tag      = try CBORLite.readUInt(from: &buf)

        switch tag {
        case 0:
            guard arrayLen == 2 else { throw LocalTxSubmissionError.unexpectedArrayLength(arrayLen) }
            let (eraTag, bytes) = try readEraTagged(from: &buf)
            guard let era = Era(from: eraTag) else { throw LocalTxSubmissionError.unknownEraTag(eraTag) }
            return .submitTx(RawTransaction(era: era, rawCBOR: bytes))

        case 1:
            guard arrayLen == 1 else { throw LocalTxSubmissionError.unexpectedArrayLength(arrayLen) }
            return .acceptTx

        case 2:
            guard arrayLen == 2 else { throw LocalTxSubmissionError.unexpectedArrayLength(arrayLen) }
            let (eraTag, bytes) = try readEraTagged(from: &buf)
            guard let era = Era(from: eraTag) else { throw LocalTxSubmissionError.unknownEraTag(eraTag) }
            return .rejectTx(TxRejection(era: era, reasonCBOR: bytes))

        case 3:
            guard arrayLen == 1 else { throw LocalTxSubmissionError.unexpectedArrayLength(arrayLen) }
            return .done

        default:
            throw LocalTxSubmissionError.unknownMessageTag(tag)
        }
    }

    // MARK: - Private helpers

    private func writeEraTagged(era: UInt64, payload: ByteBuffer, into buf: inout ByteBuffer) {
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(era, into: &buf)
        // Wrap the payload in CBOR tag 24 ("encoded CBOR data item"). This is
        // required by recent cardano-node releases (which include the Dijkstra
        // era in the HardForkBlock); older nodes accepted the untagged form.
        CBORLite.writeTag(24, into: &buf)
        CBORLite.writeByteBuffer(payload, into: &buf)
    }

    private func readEraTagged(from buf: inout ByteBuffer) throws -> (UInt16, ByteBuffer) {
        // Three wire layouts seen in practice:
        //   [era, bstr]                     - legacy nodes
        //   [era, #6.24(bstr)]              - tag-24 wrapped payload
        //   [[era, error_cbor]]             - HardForkApplyTxErrFromEra Z-wrapper
        //                                     (post-Conway-hard-fork-combinator nodes)
        // The third layout encodes the error term directly as CBOR (no bstr).
        let len = try CBORLite.readArrayHeader(from: &buf)

        if len == 1 {
            // HardFork "FromEra" Z-injection wrapper: [[era, error_cbor]]
            let innerLen = try CBORLite.readArrayHeader(from: &buf)
            guard innerLen == 2 else {
                throw LocalTxSubmissionError.unexpectedArrayLength(innerLen)
            }
            let era = UInt16(try CBORLite.readUInt(from: &buf))
            let bytes = try CBORLite.readValueBuffer(from: &buf)
            return (era, bytes)
        }

        guard len == 2 else { throw LocalTxSubmissionError.unexpectedArrayLength(len) }

        let era = UInt16(try CBORLite.readUInt(from: &buf))
        // Skip optional CBOR tag 24 wrapping ("encoded CBOR data item").
        if CBORLite.peekMajorType(from: buf) == CBORLite.majorTag {
            _ = try CBORLite.readTag(from: &buf)
        }
        // Payload may be a byte string or inline CBOR; capture either as opaque bytes.
        let bytes: ByteBuffer
        if CBORLite.peekMajorType(from: buf) == CBORLite.majorByteString {
            bytes = try CBORLite.readByteStringBuffer(from: &buf)
        } else {
            bytes = try CBORLite.readValueBuffer(from: &buf)
        }
        return (era, bytes)
    }
}
